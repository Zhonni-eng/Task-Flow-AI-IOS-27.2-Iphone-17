// In-memory task state - a port of src/state/tasksReducer.js. Display order within a column is
// defined by each task's `order` field (kept as contiguous 0..n-1 per column), never by array
// position.
import Foundation

public enum TaskAction: Sendable {
    case create(TaskItem)
    case update(id: String, changes: [String: JSONValue])
    case remove(id: String)
    /// Moves a task to `status` at `index` within that column (also used for reordering).
    case move(id: String, status: TaskStatus, index: Int)
    /// Moves every task of category `from` to category `to` (nil = uncategorized).
    case reassignCategory(from: String?, to: String?)
    /// Bulk: moves the given tasks to `status` (appended to the end of that column).
    case bulkMove(ids: [String], status: TaskStatus)
    /// Bulk: applies the same field changes (priority, categoryId, dueDate) to the given tasks.
    case bulkUpdate(ids: [String], changes: [String: JSONValue])
    /// Bulk: deletes the given tasks and renumbers the affected columns.
    case bulkRemove(ids: [String])
    /// Replaces whole tasks by id (inserting missing ones) and removes `removeIds`, then renumbers
    /// every column. Used to apply a confirmed assistant plan and to undo one exactly.
    case replace(tasks: [TaskItem], removeIds: [String])
}

public enum Tasks {
    /// Fields a bulk update may change; everything else on a task is left untouched.
    public static let bulkFields = ["priority", "categoryId", "dueDate"]

    /// A task after a status change at `now`. Completing records completedAt; reopening clears it.
    /// Completing a recurring task completes this occurrence: the task moves on to its next
    /// occurrence (missed ones skipped), back to To Do with its checklist unticked.
    public static func withStatus(_ task: TaskItem, _ status: TaskStatus, now: Date = Date(), timeZone: TimeZone = .current) -> TaskItem {
        if task.status == status { return task }
        let stamp = ISOTime.string(now)
        var next = task
        if status == .done, let rule = task.recurrence, let dueDate = task.dueDate {
            next.status = .todo
            next.dueDate = Schedule.nextDueDateAfterCompletion(rule, dueDate: dueDate, todayKey: Schedule.localDateKey(now, timeZone: timeZone))
            next.subtasks = task.subtasks.map { subtask in
                var copy = subtask
                copy.done = false
                return copy
            }
            next.planned = nil
            next.completedAt = stamp
            next.updatedAt = stamp
            return next
        }
        next.status = status
        next.completedAt = status == .done ? stamp : nil
        next.updatedAt = stamp
        return next
    }

    /// Deterministic column order: `order`, then creation time, then id.
    public static func compare(_ a: TaskItem, _ b: TaskItem) -> Bool {
        if a.order != b.order { return a.order < b.order }
        if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
        return a.id < b.id
    }

    public static func column(_ tasks: [TaskItem], _ status: TaskStatus) -> [TaskItem] {
        tasks.filter { $0.status == status }.sorted(by: compare)
    }

    static func withOrder(_ task: TaskItem, _ order: Int) -> TaskItem {
        if task.order == Double(order) { return task }
        var copy = task
        copy.order = Double(order)
        return copy
    }

    static func applyUpdates(_ tasks: [TaskItem], _ updates: [String: TaskItem]) -> [TaskItem] {
        tasks.map { updates[$0.id] ?? $0 }
    }

    /// Renumbers a column so its orders are 0..n-1, preserving relative order.
    static func renumberColumn(_ tasks: [TaskItem], _ status: TaskStatus) -> [TaskItem] {
        var updates: [String: TaskItem] = [:]
        for (index, task) in column(tasks, status).enumerated() { updates[task.id] = withOrder(task, index) }
        return applyUpdates(tasks, updates)
    }

    static func placeTask(_ tasks: [TaskItem], id: String, status: TaskStatus, index: Int?, now: Date, timeZone: TimeZone) -> [TaskItem] {
        guard let task = tasks.first(where: { $0.id == id }) else { return tasks }
        let sourceStatus = task.status
        let moved = withStatus(task, status, now: now, timeZone: timeZone)
        // A completed recurring task has moved on to its next occurrence: top of To Do instead.
        let target = moved.status
        var destination = column(tasks, target).filter { $0.id != id }
        let wanted = target == status ? index : 0
        let position = max(0, min(wanted ?? destination.count, destination.count))
        destination.insert(moved, at: position)

        var updates: [String: TaskItem] = [:]
        for (order, item) in destination.enumerated() { updates[item.id] = withOrder(item, order) }
        if sourceStatus != target {
            for (order, item) in column(tasks, sourceStatus).filter({ $0.id != id }).enumerated() {
                updates[item.id] = withOrder(item, order)
            }
        }
        return applyUpdates(tasks, updates)
    }

    /// Moves several tasks to one status. Tasks are appended to the end of the target column in
    /// their current display order (status, then position); tasks already in that status keep
    /// their place.
    static func moveTasksToStatus(_ tasks: [TaskItem], ids: [String], status: TaskStatus, now: Date, timeZone: TimeZone) -> [TaskItem] {
        let selected = Set(ids)
        let moving = TaskModel.statuses.flatMap { column(tasks, $0) }.filter { selected.contains($0.id) && $0.status != status }
        return moving.reduce(tasks) { next, task in placeTask(next, id: task.id, status: status, index: Int.max, now: now, timeZone: timeZone) }
    }

    /// Applies the same allowed field changes to several tasks; unchanged tasks stay as they are.
    static func updateTasks(_ tasks: [TaskItem], ids: [String], changes: [String: JSONValue], now: Date) -> [TaskItem] {
        let selected = Set(ids)
        let allowed = changes.filter { bulkFields.contains($0.key) }
        return tasks.map { task in
            guard selected.contains(task.id) else { return task }
            let updated = TaskModel.updateTask(task, allowed, now: now)
            let before = task.json
            let after = updated.json
            let differs = allowed.keys.contains { after[$0] != before[$0] }
            return differs ? updated : task
        }
    }

    static func removeTasks(_ tasks: [TaskItem], ids: [String]) -> [TaskItem] {
        let selected = Set(ids)
        let removed = tasks.filter { selected.contains($0.id) }
        if removed.isEmpty { return tasks }
        var statuses: [TaskStatus] = []
        for task in removed where !statuses.contains(task.status) { statuses.append(task.status) }
        return statuses.reduce(tasks.filter { !selected.contains($0.id) }) { renumberColumn($0, $1) }
    }

    /// Restores saved tasks and renumbers every column to contiguous 0..n-1 orders.
    public static func restore(_ rawTasks: [JSONValue]) -> [TaskItem] {
        renumberAll(rawTasks.map(TaskModel.restoreTask))
    }

    static func renumberAll(_ tasks: [TaskItem]) -> [TaskItem] {
        TaskModel.statuses.reduce(tasks) { renumberColumn($0, $1) }
    }

    /// All distinct labels in use, for quick reuse in the task form.
    public static func collectLabels(_ tasks: [TaskItem]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for task in tasks {
            for label in task.labels where !seen.contains(JSText.lower(label)) {
                seen.insert(JSText.lower(label))
                result.append(label)
            }
        }
        return result
    }
}

public func tasksReducer(_ state: [TaskItem], _ action: TaskAction, now: Date = Date(), timeZone: TimeZone = .current) -> [TaskItem] {
    switch action {
    case .create(let task):
        // Newest tasks appear at the top of their column.
        return Tasks.placeTask(state + [task], id: task.id, status: task.status, index: 0, now: now, timeZone: timeZone)
    case .update(let id, let changes):
        return state.map { $0.id == id ? TaskModel.updateTask($0, changes, now: now) : $0 }
    case .remove(let id):
        guard let task = state.first(where: { $0.id == id }) else { return state }
        return Tasks.renumberColumn(state.filter { $0.id != id }, task.status)
    case .move(let id, let status, let index):
        return Tasks.placeTask(state, id: id, status: status, index: index, now: now, timeZone: timeZone)
    case .bulkMove(let ids, let status):
        return Tasks.moveTasksToStatus(state, ids: ids, status: status, now: now, timeZone: timeZone)
    case .bulkUpdate(let ids, let changes):
        return Tasks.updateTasks(state, ids: ids, changes: changes, now: now)
    case .bulkRemove(let ids):
        return Tasks.removeTasks(state, ids: ids)
    case .replace(let tasks, let removeIds):
        let removing = Set(removeIds)
        var replacements: [String: TaskItem] = [:]
        var replacementOrder: [String] = []
        for task in tasks {
            if replacements[task.id] == nil { replacementOrder.append(task.id) }
            replacements[task.id] = TaskModel.restoreTask(task.json)
        }
        let kept = state.filter { !removing.contains($0.id) }.map { replacements[$0.id] ?? $0 }
        let existing = Set(state.map(\.id))
        let added = replacementOrder.filter { !existing.contains($0) }.compactMap { replacements[$0] }
        return Tasks.renumberAll(kept + added)
    case .reassignCategory(let from, let to):
        guard state.contains(where: { $0.categoryId == from }) else { return state }
        let stamp = ISOTime.string(now)
        return state.map { task in
            guard task.categoryId == from else { return task }
            var copy = task
            copy.categoryId = to
            copy.updatedAt = stamp
            return copy
        }
    }
}
