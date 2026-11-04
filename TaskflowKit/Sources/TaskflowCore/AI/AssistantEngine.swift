// The review / apply / undo rules of the assistant - a port of the pure parts of
// src/ai/useAssistant.js. Proposals from the provider are untrusted: they are validated against the
// current tasks when they arrive and again, for the selected items only, immediately before
// anything changes (a bulk change must still match exactly the tasks the user reviewed).
import Foundation

public struct ProposalItem: Equatable, Sendable, Identifiable {
    public var index: Int
    public var raw: JSONValue
    public var entry: PlanEntry
    public var conflict: Bool
    public var supported: Bool
    public var selectable: Bool
    public var selected: Bool
    public var id: Int { index }
}

public enum ProposalStatus: String, Sendable { case pending, applied, dismissed, undone }

public enum ProposalResult: Equatable, Sendable {
    case changed
    case conflict
    case applied(created: Int, updated: Int, deleted: Int, categories: Int, saved: Bool)
    case undone(removed: Int, restored: Int, kept: Int, saved: Bool)
}

public struct Proposal: Equatable, Sendable {
    public var items: [ProposalItem]
    public var status: ProposalStatus = .pending
    public var result: ProposalResult?
}

public struct UsageTotal: Equatable, Sendable {
    public var requests = 0
    public var inputTokens = 0
    public var outputTokens = 0
    /// A cost is shown only while every request had a known price.
    public var costUsd: Double? = 0

    public init() {}

    public func adding(_ usage: TokenUsage?, cost: Double?) -> UsageTotal {
        guard let usage else { return self }
        var next = self
        next.requests += 1
        next.inputTokens += usage.inputTokens
        next.outputTokens += usage.outputTokens
        if let total = costUsd, let cost { next.costUsd = total + cost } else { next.costUsd = nil }
        return next
    }
}

public enum ApplyDecision: Sendable {
    /// Tasks changed while the user was reviewing.
    case changed
    /// Several selected actions change the same task.
    case conflict
    case apply(ApplyOutcome)
    case nothingSelected
}

public enum AssistantEngine {
    static let applicable: Set<String> = ["create", "update", "delete", "addSubtask", "updateSubtask", "deleteSubtask", "moveSubtask", "bulk", "schedule", "renameLabel", "deleteLabel"]
    // Actions whose tasks the app resolves itself; they must still match the same tasks when applied.
    static let resolved: Set<String> = ["bulk", "renameLabel", "deleteLabel"]
    static let blockingWarnings: Set<String> = ["possibleDuplicate", "duplicateInPlan", "noChange", "conflictsWithEarlier"]
    public static let maxRecentIds = 50

    /// Every task an entry would change (for spotting several actions on one task).
    static func touchedIds(_ entry: PlanEntry) -> [String] {
        if let type = entry.type, resolved.contains(type) { return entry.matches ?? [] }
        switch entry.normalized {
        case .schedule(_, let items)?:
            return items.map(\.taskId)
        case .moveSubtask(let taskId, _, let toTaskId)?:
            return [taskId, toTaskId].filter { !$0.isEmpty }
        default:
            break
        }
        if let id = entry.normalizedTaskId ?? entry.target?.id { return [id] }
        return []
    }

    /// Review items. Unticked by default: invalid or unsupported items, likely duplicates, changes
    /// that change nothing, and every action touching a task another action also changes. Bulk
    /// changes that match no task cannot be selected.
    public static func buildProposal(plan: JSONValue, validation: PlanValidation) -> Proposal? {
        let entries = validation.actions.filter { $0.type != "none" }
        var counts: [String: Int] = [:]
        for entry in entries { for id in Set(touchedIds(entry)) { counts[id, default: 0] += 1 } }
        let rawActions = plan["actions"]?.arrayValue ?? []
        let items = entries.map { entry -> ProposalItem in
            let supported = entry.type.map(applicable.contains) ?? false
            let selectable = supported && entry.valid && !entry.warnings.contains("noMatches")
            let conflict = touchedIds(entry).contains { (counts[$0] ?? 0) > 1 }
            let blocked = conflict || entry.warnings.contains(where: blockingWarnings.contains)
            return ProposalItem(
                index: entry.index,
                raw: entry.index < rawActions.count ? rawActions[entry.index] : .null,
                entry: entry,
                conflict: conflict,
                supported: supported,
                selectable: selectable,
                selected: selectable && !blocked
            )
        }
        return items.isEmpty ? nil : Proposal(items: items)
    }

    public static func toggle(_ proposal: Proposal, index: Int) -> Proposal {
        var next = proposal
        next.result = nil
        next.items = proposal.items.map { item in
            guard item.index == index, item.selectable else { return item }
            var copy = item
            copy.selected.toggle()
            return copy
        }
        return next
    }

    /// Re-checks the selected items of a pending proposal against the current data and, when they
    /// still hold, computes the changes to apply (nothing is changed here).
    public static func prepareApply(_ proposal: Proposal, context: ValidationContext) -> ApplyDecision {
        let chosen = proposal.items.filter { $0.selected && $0.selectable }
        guard proposal.status == .pending, !chosen.isEmpty else { return .nothingSelected }
        let recheck = ActionPlan.validate(["actions": .array(chosen.map(\.raw))], context: context)
        let stillSame = recheck.actions.enumerated().allSatisfy { index, entry in
            guard let type = entry.type, resolved.contains(type) else { return true }
            return Set(entry.matches ?? []) == Set(chosen[index].entry.matches ?? []) && (entry.matches ?? []).count == (chosen[index].entry.matches ?? []).count
        }
        if !recheck.ok || !stillSame || recheck.actions.contains(where: { !($0.type.map(applicable.contains) ?? false) || $0.warnings.contains("noMatches") }) {
            return .changed
        }
        if recheck.actions.contains(where: { $0.warnings.contains("conflictsWithEarlier") }) { return .conflict }
        return .apply(ApplyPlan.apply(tasks: context.tasks ?? [], categories: context.categories ?? [], entries: recheck.actions, now: context.now, timeZone: context.timeZone))
    }
}

extension PlanEntry {
    /// The task id of a single-task action.
    var normalizedTaskId: String? {
        switch normalized {
        case .update(let taskId, _, _)?, .delete(let taskId)?, .addSubtask(let taskId, _)?, .updateSubtask(let taskId, _, _, _)?, .deleteSubtask(let taskId, _)?:
            return taskId.isEmpty ? nil : taskId
        default:
            return nil
        }
    }
}
