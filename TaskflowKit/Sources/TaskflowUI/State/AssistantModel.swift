// Assistant session state on iPhone - the counterpart of src/ai/useAssistant.js: messages,
// proposals, applying and undo. Proposals from the provider are untrusted: they are validated
// against the current tasks when they arrive and again, for the selected items only, immediately
// before anything changes. Changes are applied as one batch through the normal reducers and save;
// success is reported only after that save succeeded.
import Foundation
import Observation
import TaskflowCore

public struct AssistantMessage: Identifiable, Equatable {
    public enum Role: Equatable { case user, assistant, error }
    public let id = UUID()
    public var role: Role
    public var text: String = ""
    public var reply: String?
    public var question: String?
    public var code: String?
    public var proposal: Proposal?
}

@MainActor
@Observable
public final class AssistantModel {
    public private(set) var messages: [AssistantMessage] = []
    public private(set) var sending = false
    public private(set) var applying = false
    public private(set) var usage = UsageTotal()
    /// The last confirmed batch: (message, undo record).
    public private(set) var undoBatch: (messageId: UUID, undo: UndoRecord)?
    public private(set) var connectionStatus: ConnectionStatus = .none
    public private(set) var publicState: AIPublicState

    public let settings: AISettings
    public let connection: AIConnection
    let chat: ChatService
    private weak var store: AppStore?
    private var recentIds: [String] = [] // tasks this session created or changed
    private var sharedIds: [String] = [] // tasks the provider has been shown in this conversation

    public init(settings: AISettings, transport: HTTPTransport, store: AppStore) {
        self.settings = settings
        self.connection = AIConnection(settings: settings, transport: transport)
        self.chat = ChatService(settings: settings, transport: transport, connection: connection)
        self.store = store
        self.publicState = settings.publicState()
        Task { await refreshStatus() }
    }

    public func refreshStatus() async {
        publicState = settings.publicState()
        connectionStatus = await connection.status()
    }

    public var isReady: Bool { publicState.enabled && publicState.key == .stored }

    private func validationContext() -> ValidationContext {
        ValidationContext(tasks: store?.tasks ?? [], categories: store?.categories ?? [], allowedTaskIds: sharedIds, availability: store?.settings.availability, now: Date())
    }

    private func remember(_ ids: [String]) {
        var next: [String] = []
        for id in ids + recentIds where !next.contains(id) { next.append(id) }
        recentIds = Array(next.prefix(AssistantEngine.maxRecentIds))
    }

    private func update(_ id: UUID, _ change: (inout AssistantMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }

    // MARK: Conversation

    @discardableResult
    public func send(_ text: String) async -> Bool {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty, !sending, let store else { return false }
        sending = true
        messages.append(AssistantMessage(role: .user, text: message))
        let recent = recentIds.filter { id in store.tasks.contains { $0.id == id } }
        let snapshot = ChatSnapshot(tasks: store.tasks, categories: store.categories, availability: store.settings.availability)
        let result = await chat.send(message, language: store.settings.language, recentTaskIds: recent, snapshot: snapshot)
        sending = false
        await refreshStatus()
        switch result {
        case .failure(let code):
            if code != .cancelled { messages.append(AssistantMessage(role: .error, code: code.rawValue)) }
        case .success(let reply):
            usage = usage.adding(reply.usage, cost: reply.costUsd)
            sharedIds = reply.sharedTaskIds
            let validation = ActionPlan.validate(reply.plan, context: validationContext())
            if !validation.errors.isEmpty {
                messages.append(AssistantMessage(role: .error, code: AICode.malformed.rawValue))
                return true
            }
            messages.append(AssistantMessage(role: .assistant, reply: validation.reply, question: validation.question, proposal: AssistantEngine.buildProposal(plan: reply.plan, validation: validation)))
        }
        return true
    }

    public func toggle(_ messageId: UUID, index: Int) {
        update(messageId) { message in
            if let proposal = message.proposal, proposal.status == .pending { message.proposal = AssistantEngine.toggle(proposal, index: index) }
        }
    }

    public func dismiss(_ messageId: UUID) {
        update(messageId) { $0.proposal?.status = .dismissed }
    }

    /// Applies the selected items of one proposal after re-checking them against current data.
    public func apply(_ messageId: UUID) {
        guard !applying, !sending, let store, let proposal = messages.first(where: { $0.id == messageId })?.proposal else { return }
        switch AssistantEngine.prepareApply(proposal, context: validationContext()) {
        case .nothingSelected:
            return
        case .changed:
            update(messageId) { $0.proposal?.result = .changed }
        case .conflict:
            update(messageId) { $0.proposal?.result = .conflict }
        case .apply(let outcome):
            applying = true
            let saved = store.applyAssistantChanges(tasks: outcome.tasks, removeIds: outcome.removeIds, newCategories: outcome.categories)
            applying = false
            remember(outcome.tasks.map(\.id))
            update(messageId) {
                $0.proposal?.status = .applied
                $0.proposal?.result = .applied(created: outcome.created, updated: outcome.updated, deleted: outcome.deleted, categories: outcome.categories.count, saved: saved)
            }
            undoBatch = (messageId, outcome.undo)
            if saved { Haptics.success() }
        }
    }

    /// Reverts the last confirmed batch - but only what is still exactly as the assistant left it.
    /// Deleted tasks come back; tasks edited since are kept; categories it created are removed when
    /// no task uses them any more.
    public func undo() {
        guard let batch = undoBatch, !applying, let store else { return }
        let result = ApplyPlan.undo(batch.undo, currentTasks: store.tasks)
        var remaining = Dictionary(store.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in result.removeIds { remaining[id] = nil }
        for task in result.tasks { remaining[task.id] = task }
        let unused = batch.undo.categoryIds.filter { categoryId in !remaining.values.contains { $0.categoryId == categoryId } }
        applying = true
        var saved = true
        if !result.tasks.isEmpty || !result.removeIds.isEmpty || !unused.isEmpty {
            saved = store.applyAssistantChanges(tasks: result.tasks, removeIds: result.removeIds, newCategories: [], removeCategoryIds: unused)
        }
        applying = false
        update(batch.messageId) {
            $0.proposal?.status = .undone
            $0.proposal?.result = .undone(removed: result.removed, restored: result.restored, kept: result.kept, saved: saved)
        }
        undoBatch = nil
    }

    public func reset() async {
        guard !applying else { return }
        messages = []
        undoBatch = nil
        recentIds = []
        sharedIds = []
        await chat.reset()
    }

    // MARK: Connection

    public func connect(_ request: ConnectRequest) async -> AICode? {
        let result = await connection.connect(request)
        await refreshStatus()
        if case .failure(let code) = result { return code }
        return nil
    }

    public func disconnect() async -> Bool {
        let result = await connection.disconnect()
        await chat.reset()
        await refreshStatus()
        if case .success = result { return true }
        return false
    }

    public func setEnabled(_ enabled: Bool) async -> Bool {
        let result = settings.setEnabled(enabled)
        await refreshStatus()
        if case .success = result { return true }
        return false
    }
}
