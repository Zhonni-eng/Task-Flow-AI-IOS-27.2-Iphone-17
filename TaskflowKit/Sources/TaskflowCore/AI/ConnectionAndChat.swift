// The AI connection and the assistant conversation - ports of electron/ai/connection.cjs and
// electron/ai/chatService.cjs.
//
// Connection: a new key goes to exactly one provider (suggested by its shape, or chosen in the
// advanced settings), is tested with one minimal request (no task data) and stored only if the test
// succeeded. A failed test never replaces the previously working configuration. A stored key is
// not assumed to work: after a restart the status is "saved" until a test or a request succeeds.
//
// Chat: builds the per-turn context, calls the stored key's provider adapter and keeps that
// provider's history in memory only (never written to disk). History is append-only.
import Foundation

public enum ConnectionStatus: String, Sendable { case none, connected, saved, unverified, failed, unreadable }

public struct ConnectRequest: Sendable {
    /// nil re-tests the stored key.
    public var key: String?
    /// nil = recognize from the key.
    public var provider: ProviderID?
    public var baseUrl: String?
    public var model: String?

    public init(key: String? = nil, provider: ProviderID? = nil, baseUrl: String? = nil, model: String? = nil) {
        self.key = key
        self.provider = provider
        self.baseUrl = baseUrl
        self.model = model
    }
}

public actor AIConnection {
    // Connection test failures that mean the stored key itself is not usable right now.
    static let keyFailures: Set<AICode> = [.auth, .permission, .modelUnavailable]

    let settings: AISettings
    let transport: HTTPTransport
    let now: @Sendable () -> Date
    private var session: ConnectionStatus?
    private var busy = false

    public init(settings: AISettings, transport: HTTPTransport, now: @escaping @Sendable () -> Date = Date.init) {
        self.settings = settings
        self.transport = transport
        self.now = now
    }

    public func status() -> ConnectionStatus {
        let state = settings.publicState()
        switch state.key {
        case .none: return .none
        case .unreadable: return .unreadable
        case .stored: return session ?? (state.verifiedAt != nil ? .saved : .unverified)
        }
    }

    public func connect(_ request: ConnectRequest) async -> Swift.Result<Void, AICode> {
        if busy { return .failure(.busy) }
        busy = true
        defer { busy = false }

        guard let rawKey = request.key else {
            let target = settings.target()
            guard let apiKey = settings.apiKey(), let model = target.model else { return .failure(.noKey) }
            let result = await Providers.get(target.providerId).makeAdapter(transport: transport).testConnection(apiKey: apiKey, model: model, baseUrl: target.baseUrl)
            if case .failure(let code) = result {
                if Self.keyFailures.contains(code) { session = .failed }
                return .failure(code)
            }
            session = .connected
            // The key works either way; a failed timestamp write is reported but changes nothing else.
            return settings.markVerified(ISOTime.string(now()))
        }

        let key = JSText.trim(rawKey)
        let provider: ProviderDescriptor
        if let chosen = request.provider {
            provider = Providers.get(chosen)
            if !provider.isApiKeyFormat(key) { return .failure(.invalidKey) }
        } else {
            switch Providers.detect(key) {
            case .failure(let code): return .failure(code)
            case .success(let detected): provider = detected
            }
        }
        var target = ConnectionTarget(providerId: provider.id, model: provider.model, baseUrl: nil)
        if provider.id != .openaiCompatible, let rawModel = request.model, !JSText.trim(rawModel).isEmpty {
            // A model chosen in the advanced settings: tested with exactly this id, never replaced.
            guard let model = Providers.normalizeModelId(rawModel) else { return .failure(.invalidModel) }
            target.model = model
        }
        if provider.id == .openaiCompatible {
            guard let baseUrl = request.baseUrl.flatMap(Providers.normalizeBaseUrl) else { return .failure(.invalidBaseUrl) }
            guard let model = request.model.flatMap(Providers.normalizeModelId) else { return .failure(.invalidModel) }
            target = ConnectionTarget(providerId: provider.id, model: model, baseUrl: baseUrl)
        }
        // Do not test a key that could not be stored afterwards.
        if case .failure(let code) = settings.canStoreKey() { return .failure(code) }
        let result = await provider.makeAdapter(transport: transport).testConnection(apiKey: key, model: target.model ?? "", baseUrl: target.baseUrl)
        // The previous configuration (if any) and its status stay exactly as they were.
        if case .failure(let code) = result { return .failure(code) }
        let stored = settings.storeVerifiedKey(provider.id, key: key, verifiedAt: ISOTime.string(now()), target: target)
        if case .success = stored { session = .connected }
        return stored
    }

    public func disconnect() -> Swift.Result<Void, AICode> {
        let result = settings.clearApiKeys()
        if case .success = result { session = nil }
        return result
    }

    /// Chat requests report their outcome here, so the status reflects what actually happened.
    public func noteRequest(_ code: AICode?) {
        if code == nil { session = .connected } else if code == .auth || code == .permission { session = .failed }
    }
}

public struct ChatResult: Sendable {
    public var plan: JSONValue
    public var sharedTaskIds: [String]
    public var usage: TokenUsage?
    public var model: String
    public var costUsd: Double?
}

public struct ChatSnapshot: Sendable {
    public var tasks: [TaskItem]
    public var categories: [TaskCategory]
    public var availability: Availability?
    public init(tasks: [TaskItem], categories: [TaskCategory], availability: Availability?) {
        self.tasks = tasks
        self.categories = categories
        self.availability = availability
    }
}

public actor ChatService {
    public static let maxMessageLength = 2000
    public static let maxTurns = 20 // then the user starts a new conversation (no history trimming)
    static let maxCategories = 200

    let settings: AISettings
    let transport: HTTPTransport
    let connection: AIConnection?
    let now: @Sendable () -> Date
    let timeZone: @Sendable () -> TimeZone
    private var history: [JSONValue] = []
    private var historyTarget: String?
    private var turns = 0
    // Task ids shown to the model in this conversation: the only ids its changes may target.
    private var sharedIds: [String] = []
    private var busy = false
    private var epoch = 0 // bumped by reset(); a reply to an older conversation is discarded

    public init(settings: AISettings, transport: HTTPTransport, connection: AIConnection? = nil, now: @escaping @Sendable () -> Date = Date.init, timeZone: @escaping @Sendable () -> TimeZone = { TimeZone.current }) {
        self.settings = settings
        self.transport = transport
        self.connection = connection
        self.now = now
        self.timeZone = timeZone
    }

    public func reset() {
        history = []
        historyTarget = nil
        turns = 0
        sharedIds = []
        epoch += 1
    }

    public func turnCount() -> Int { turns }

    /// `recentTaskIds`: tasks this assistant session created or changed (follow-up references).
    /// They only choose which saved tasks are described; their data always comes from `snapshot`.
    public func send(_ message: String, language: Language, recentTaskIds: [String] = [], snapshot: ChatSnapshot) async -> Swift.Result<ChatResult, AICode> {
        let text = JSText.trim(message)
        if text.isEmpty || JSText.length(text) > Self.maxMessageLength { return .failure(.invalidMessage) }
        if busy { return .failure(.busy) }

        let state = settings.publicState()
        if !state.enabled { return .failure(.aiDisabled) }
        let target = settings.target()
        guard let model = target.model else { return .failure(.providerUnsupported) }
        guard state.key == .stored, let apiKey = settings.apiKey() else { return .failure(.noKey) }

        // A conversation is never replayed to another service (or another endpoint/model).
        let targetId = [target.providerId.rawValue, target.baseUrl ?? "", model].joined(separator: "|")
        if let historyTarget, historyTarget != targetId { reset() }
        if turns >= Self.maxTurns { return .failure(.conversationLimit) }

        let date = Prompt.dateContext(now: now(), timeZone: timeZone())
        let categories = snapshot.categories.prefix(Self.maxCategories).map { (id: $0.id, name: $0.name) }
        // Tasks of this session first: changed by the assistant, then shown to it earlier.
        var pinned: [String] = []
        for id in recentTaskIds + sharedIds where !pinned.contains(id) { pinned.append(id) }
        let contextTasks = TaskContext.select(message: text, tasks: snapshot.tasks, pinnedIds: pinned, categories: Array(categories), todayKey: date.today, nowTime: date.time)
        let userContent = Prompt.buildUserTurn(
            message: text,
            language: language,
            categories: Array(categories),
            tasks: contextTasks,
            summary: TaskContext.summary(snapshot.tasks, todayKey: date.today, nowTime: date.time),
            tags: TaskContext.tagSummary(snapshot.tasks),
            availability: snapshot.availability,
            date: date
        )

        busy = true
        let startedIn = epoch
        let adapter = Providers.get(target.providerId).makeAdapter(transport: transport)
        let result = await adapter.proposePlan(apiKey: apiKey, model: model, baseUrl: target.baseUrl, history: history, userContent: userContent)
        busy = false
        switch result {
        case .failure(let code): await connection?.noteRequest(code)
        case .success: await connection?.noteRequest(nil)
        }
        if startedIn != epoch { return .failure(.cancelled) }
        switch result {
        case .failure(let code):
            return .failure(code)
        case .success(let reply):
            history += reply.turn
            historyTarget = targetId
            turns += 1
            for task in contextTasks where !sharedIds.contains(task.task.id) { sharedIds.append(task.task.id) }
            return .success(ChatResult(plan: reply.plan, sharedTaskIds: sharedIds, usage: reply.usage, model: model, costUsd: Providers.estimateCost(model: model, usage: reply.usage)))
        }
    }
}
