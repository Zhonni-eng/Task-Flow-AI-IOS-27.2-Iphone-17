// Applying a validated, confirmed assistant plan - a port of src/ai/applyPlan.js. A pure function,
// so the result can be checked before it is dispatched and undone exactly. Works on copies.
//
// applyPlan(tasks, categories, entries, now) -> {
//   tasks:      final versions of every created or changed task (whole objects),
//   removeIds:  ids of deleted tasks,
//   categories: categories created for this plan,
//   undo:       { before: { id: task | nil }, after: { id: task | nil }, categoryIds },
//   counts:     { created, updated, deleted },
// }
// Status changes go through the same rule as the board (withStatus: completedAt, recurring tasks
// move to their next occurrence).
import Foundation

public struct UndoRecord: Equatable, Sendable {
    public var before: [String: TaskItem?]
    public var after: [String: TaskItem?]
    /// Ids in the order they were first touched.
    public var order: [String]
    public var categoryIds: [String]
}

public struct ApplyOutcome: Equatable, Sendable {
    public var tasks: [TaskItem]
    public var removeIds: [String]
    public var categories: [TaskCategory]
    public var undo: UndoRecord
    public var created: Int
    public var updated: Int
    public var deleted: Int
}

public struct UndoOutcome: Equatable, Sendable {
    public var tasks: [TaskItem]
    public var removeIds: [String]
    public var restored: Int
    public var removed: Int
    public var kept: Int
}

public enum ApplyPlan {
    public static func apply(tasks: [TaskItem], categories: [TaskCategory], entries: [PlanEntry], now: Date = Date(), timeZone: TimeZone = .current) -> ApplyOutcome {
        var working: [String: TaskItem] = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var before: [String: TaskItem?] = [:]
        var order: [String] = []
        var created = Set<String>()
        var deleted: [String] = []
        var newCategories: [TaskCategory] = []
        var createdCount = 0

        func remember(_ id: String) {
            if before[id] == nil {
                before[id] = .some(working[id])
                order.append(id)
            }
        }
        func categoryFor(_ name: String?) -> String? {
            guard let name, !name.isEmpty else { return nil }
            if let existing = CategoryMatch.findMatching(name, in: categories + newCategories) { return existing.id }
            let category = CategoryModel.create(name, order: categories.count + newCategories.count, now: now)
            newCategories.append(category)
            return category.id
        }
        /// Field changes (and a status change) on one task. Changed tasks go to the top of their column.
        func change(_ id: String, _ changes: [String: JSONValue], _ newCategory: String?) {
            guard let current = working[id] else { return }
            remember(id)
            var fields = changes
            let status = fields.removeValue(forKey: "status")?.stringValue.flatMap(TaskStatus.init(rawValue:))
            let added = fields.removeValue(forKey: "addLabels")
            let removed = fields.removeValue(forKey: "removeLabels")
            if let newCategory { fields["categoryId"] = .from(categoryFor(newCategory)) }
            // Tag edits apply to the task's current tags: added ones merged, removed ones taken off.
            if added != nil || removed != nil {
                fields["labels"] = .from(ActionPlan.editLabels(current.labels, added: ActionPlan.strings(added), removed: ActionPlan.strings(removed)))
            }
            var next = fields.isEmpty ? current : TaskModel.updateTask(current, fields, now: now)
            if let status, status != current.status {
                next = Tasks.withStatus(next, status, now: now, timeZone: timeZone)
                next.order = -1
            }
            working[id] = next
        }
        func remove(_ id: String) {
            guard working[id] != nil else { return }
            remember(id)
            working[id] = nil
            if created.contains(id) { created.remove(id) } else { deleted.append(id) }
        }
        func relabel(_ id: String, _ edit: ([String]) -> [String]) {
            guard let current = working[id] else { return }
            remember(id)
            working[id] = TaskModel.updateTask(current, ["labels": .from(edit(current.labels))], now: now)
        }
        func editSubtasks(_ id: String, _ edit: ([Subtask]) -> [Subtask]) {
            guard var current = working[id] else { return }
            remember(id)
            current.subtasks = edit(current.subtasks)
            current.updatedAt = ISOTime.string(now)
            working[id] = current
        }

        for (position, entry) in entries.enumerated() {
            guard let normalized = entry.normalized else { continue }
            switch normalized {
            case .create(let fields, let subtasks, let newCategory):
                var taskFields = fields
                taskFields["subtasks"] = .array(subtasks.map { Subtasks.create($0).json })
                if let newCategory { taskFields["categoryId"] = .from(categoryFor(newCategory)) }
                let status = fields["status"]?.stringValue.flatMap(TaskStatus.init(rawValue:)) ?? .todo
                taskFields["status"] = "todo"
                var task = TaskModel.createTask(taskFields, now: now)
                if status != .todo { task = Tasks.withStatus(task, status, now: now, timeZone: timeZone) }
                // In the proposed order, above the existing tasks of its column.
                task.order = Double(-entries.count + position)
                before[task.id] = .some(nil)
                order.append(task.id)
                created.insert(task.id)
                working[task.id] = task
                createdCount += 1
            case .update(let taskId, let changes, let newCategory):
                change(taskId, changes, newCategory)
            case .delete(let taskId):
                remove(taskId)
            case .addSubtask(let taskId, let title):
                editSubtasks(taskId) { $0 + [Subtasks.create(title)] }
            case .updateSubtask(let taskId, let subtaskId, let title, let done):
                editSubtasks(taskId) { list in
                    list.map { subtask in
                        guard subtask.id == subtaskId else { return subtask }
                        var copy = subtask
                        if let title { copy.title = title }
                        if let done { copy.done = done }
                        return copy
                    }
                }
            case .deleteSubtask(let taskId, let subtaskId):
                editSubtasks(taskId) { $0.filter { $0.id != subtaskId } }
            case .moveSubtask(let taskId, let subtaskId, let toTaskId):
                guard let moving = working[taskId]?.subtasks.first(where: { $0.id == subtaskId }), working[toTaskId] != nil else { break }
                editSubtasks(taskId) { $0.filter { $0.id != subtaskId } }
                editSubtasks(toTaskId) { $0 + [moving] }
            case .bulk(let operation, _, let changes, let newCategory, let matches):
                for id in matches {
                    if operation == "delete" { remove(id) } else { change(id, changes, newCategory) }
                }
            case .renameLabel(let label, let newLabel, let matches):
                for id in matches { relabel(id) { ActionPlan.renameLabel(in: $0, from: label, to: newLabel) } }
            case .deleteLabel(let label, let matches):
                for id in matches { relabel(id) { ActionPlan.editLabels($0, removed: [label]) } }
            case .schedule(let date, let items):
                for item in items {
                    guard let current = working[item.taskId] else { continue }
                    remember(item.taskId)
                    working[item.taskId] = TaskModel.updateTask(current, ["planned": Planned(date: date, time: item.start).json], now: now)
                }
            case .none:
                break
            }
        }

        let changedTasks = order.compactMap { working[$0] }
        var after: [String: TaskItem?] = [:]
        for id in order { after[id] = .some(working[id]) }
        let updatedCount = changedTasks.count - createdCount
        return ApplyOutcome(
            tasks: changedTasks,
            removeIds: deleted,
            categories: newCategories,
            undo: UndoRecord(before: before, after: after, order: order, categoryIds: newCategories.map(\.id)),
            created: createdCount,
            updated: updatedCount,
            deleted: deleted.count
        )
    }

    /// Fields compared to tell whether the user edited a task after the assistant changed it.
    static let tracked = ["title", "description", "priority", "dueDate", "dueTime", "reminders", "recurrence", "estimateMinutes", "planned", "labels", "status", "categoryId", "subtasks"]

    static func sameTask(_ a: TaskItem?, _ b: TaskItem?) -> Bool {
        let left = a?.json
        let right = b?.json
        return tracked.allSatisfy { (left?[$0] ?? .null) == (right?[$0] ?? .null) }
    }

    /// Undo of an applied plan - only what is still exactly as the assistant left it.
    public static func undo(_ record: UndoRecord, currentTasks: [TaskItem]) -> UndoOutcome {
        let current = Dictionary(currentTasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var putBack: [TaskItem] = []
        var removeIds: [String] = []
        var kept = 0
        var restored = 0
        for id in record.order {
            let beforeTask = record.before[id] ?? nil
            let afterTask = record.after[id] ?? nil
            let now = current[id]
            guard let afterTask else {
                // Deleted by the plan: restore it unless something with that id exists again.
                if now != nil {
                    kept += 1
                } else if let beforeTask {
                    putBack.append(beforeTask)
                    restored += 1
                }
                continue
            }
            guard let now, sameTask(now, afterTask) else {
                kept += 1
                continue
            }
            if let beforeTask {
                putBack.append(beforeTask)
                restored += 1
            } else {
                removeIds.append(id)
            }
        }
        return UndoOutcome(tasks: putBack, removeIds: removeIds, restored: restored, removed: removeIds.count, kept: kept)
    }
}
