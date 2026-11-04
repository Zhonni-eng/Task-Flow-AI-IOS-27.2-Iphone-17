// Task data model: shape, defaults, normalization and validation - a port of src/data/taskModel.js
// and src/data/subtasks.js. The JSON form is exactly the Windows app's schema v4 task.
//
// Task = {
//   id, title, description, priority: low|medium|high,
//   dueDate: "YYYY-MM-DD" | null, dueTime: "HH:MM" | null (only with a due date),
//   reminders: minutes before the deadline, recurrence: rule | null (dueDate = next occurrence),
//   estimateMinutes | null, planned: { date, time } | null (accepted day-plan slot, not a deadline),
//   completedAt: ISO | null, labels: string[], status: todo|inProgress|done,
//   order (position within its column, 0 = top), categoryId | null (null = uncategorized),
//   subtasks: { id, title, done }[] (one level), createdAt, updatedAt: ISO strings
// }
import Foundation

public enum TaskStatus: String, CaseIterable, Sendable, Codable, Hashable {
    case todo, inProgress, done
}

public enum Priority: String, CaseIterable, Sendable, Codable, Hashable {
    case low, medium, high
}

public struct Planned: Equatable, Hashable, Sendable, Codable {
    public var date: String
    public var time: String
    public init(date: String, time: String) {
        self.date = date
        self.time = time
    }
    public var json: JSONValue { ["date": .string(date), "time": .string(time)] }
}

public struct Subtask: Equatable, Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var title: String
    public var done: Bool
    public init(id: String, title: String, done: Bool) {
        self.id = id
        self.title = title
        self.done = done
    }
    public var json: JSONValue { ["id": .string(id), "title": .string(title), "done": .bool(done)] }
}

public struct TaskItem: Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var description: String
    public var priority: Priority
    public var dueDate: String?
    public var dueTime: String?
    public var reminders: [Int]
    public var recurrence: Recurrence?
    public var estimateMinutes: Int?
    public var planned: Planned?
    public var labels: [String]
    public var status: TaskStatus
    public var order: Double
    public var categoryId: String?
    public var subtasks: [Subtask]
    public var completedAt: String?
    public var createdAt: String
    public var updatedAt: String

    public var json: JSONValue {
        .object([
            "id": .string(id),
            "title": .string(title),
            "description": .string(description),
            "priority": .string(priority.rawValue),
            "dueDate": .from(dueDate),
            "dueTime": .from(dueTime),
            "reminders": .from(reminders),
            "recurrence": recurrence?.json ?? .null,
            "estimateMinutes": .from(estimateMinutes),
            "planned": planned?.json ?? .null,
            "labels": .from(labels),
            "status": .string(status.rawValue),
            "order": .number(order),
            "categoryId": .from(categoryId),
            "subtasks": .array(subtasks.map(\.json)),
            "completedAt": .from(completedAt),
            "createdAt": .string(createdAt),
            "updatedAt": .string(updatedAt),
        ])
    }
}

public enum TaskModel {
    public static let statuses = TaskStatus.allCases
    public static let priorities = Priority.allCases
    public static let defaultStatus = TaskStatus.todo
    public static let defaultPriority = Priority.medium

    public enum Limits {
        public static let title = 120
        public static let description = 2000
        public static let label = 30
        public static let labels = 10
    }

    /// Fields the user can edit through the task form.
    public static let editableFields = [
        "title", "description", "priority", "dueDate", "dueTime", "reminders", "recurrence", "estimateMinutes", "planned",
        "labels", "status", "categoryId", "subtasks",
    ]

    public static func generateId() -> String { UUID().uuidString.lowercased() }

    /// A day-plan slot { date, time } or nil.
    public static func normalizePlanned(_ value: JSONValue?) -> Planned? {
        guard let value, value.isPlainObject, let date = value["date"]?.stringValue, let time = value["time"]?.stringValue,
              Schedule.isDateKey(date), Schedule.isTimeKey(time) else { return nil }
        return Planned(date: date, time: time)
    }

    /// Splits free text ("design, ui") into label candidates.
    public static func splitLabels(_ text: String) -> [String] {
        text.components(separatedBy: ",")
    }

    /// Trims, collapses whitespace, drops empties and case-insensitive duplicates, applies limits.
    public static func normalizeLabels(_ labels: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for raw in labels {
            let label = JSText.trimEnd(JSText.slice(JSText.trim(JSText.collapseWhitespace(raw)), Limits.label))
            let key = JSText.lower(label)
            if label.isEmpty || seen.contains(key) { continue }
            seen.insert(key)
            result.append(label)
            if result.count == Limits.labels { break }
        }
        return result
    }

    static func normalizeLabels(_ raw: JSONValue?) -> [String] {
        guard let list = raw?.arrayValue else { return [] }
        return normalizeLabels(list.map { JSText.string($0) })
    }

    struct Fields {
        var title: String
        var description: String
        var priority: Priority
        var dueDate: String?
        var dueTime: String?
        var reminders: [Int]
        var recurrence: Recurrence?
        var estimateMinutes: Int?
        var planned: Planned?
        var labels: [String]
        var status: TaskStatus
        var categoryId: String?
        var subtasks: [Subtask]
    }

    static func normalizeFields(_ fields: [String: JSONValue]) -> Fields {
        let rawDue = fields["dueDate"]?.stringValue
        let dueDate = Schedule.isDateKey(rawDue) ? rawDue : nil
        let dueTime = Schedule.normalizeDueTime(fields["dueTime"]?.stringValue, dueDate: dueDate)
        let categoryText = fields["categoryId"]?.stringValue
        return Fields(
            title: JSText.trimEnd(JSText.slice(JSText.trim(JSText.string(fields["title"])), Limits.title)),
            description: JSText.trimEnd(JSText.slice(JSText.trim(JSText.string(fields["description"])), Limits.description)),
            priority: fields["priority"]?.stringValue.flatMap(Priority.init(rawValue:)) ?? defaultPriority,
            dueDate: dueDate,
            dueTime: dueTime,
            reminders: Schedule.normalizeReminders(fields["reminders"], dueDate: dueDate, dueTime: dueTime),
            recurrence: Schedule.normalizeRecurrence(fields["recurrence"], dueDate: dueDate),
            estimateMinutes: Schedule.normalizeEstimate(fields["estimateMinutes"]),
            planned: normalizePlanned(fields["planned"]),
            labels: normalizeLabels(fields["labels"]),
            status: fields["status"]?.stringValue.flatMap(TaskStatus.init(rawValue:)) ?? defaultStatus,
            categoryId: (categoryText?.isEmpty == false) ? categoryText : nil,
            subtasks: Subtasks.normalize(fields["subtasks"])
        )
    }

    private static func task(id: String, fields f: Fields, order: Double, completedAt: String?, createdAt: String, updatedAt: String) -> TaskItem {
        TaskItem(
            id: id, title: f.title, description: f.description, priority: f.priority, dueDate: f.dueDate, dueTime: f.dueTime,
            reminders: f.reminders, recurrence: f.recurrence, estimateMinutes: f.estimateMinutes, planned: f.planned,
            labels: f.labels, status: f.status, order: order, categoryId: f.categoryId, subtasks: f.subtasks,
            completedAt: completedAt, createdAt: createdAt, updatedAt: updatedAt
        )
    }

    /// Returns a map of field -> error code. Empty means valid.
    public static func validateTaskFields(title: String) -> [String: String] {
        JSText.trim(title).isEmpty ? ["title": "titleRequired"] : [:]
    }

    /// createTask(fields): `fields` uses the JSON field names.
    public static func createTask(_ fields: [String: JSONValue] = [:], now: Date = Date()) -> TaskItem {
        let stamp = ISOTime.string(now)
        return task(
            id: fields["id"]?.stringValue ?? generateId(),
            fields: normalizeFields(fields),
            order: fields["order"]?.finiteNumber ?? 0,
            completedAt: nil,
            createdAt: stamp,
            updatedAt: stamp
        )
    }

    /// Rebuilds a task loaded from storage, keeping its id, order and timestamps.
    public static func restoreTask(_ raw: JSONValue) -> TaskItem {
        let dict = raw.objectValue ?? [:]
        return task(
            id: JSText.string(dict["id"]),
            fields: normalizeFields(dict),
            order: dict["order"]?.finiteNumber ?? 0,
            completedAt: dict["completedAt"]?.stringValue,
            createdAt: dict["createdAt"]?.stringValue ?? ISOTime.epoch,
            updatedAt: dict["updatedAt"]?.stringValue ?? ISOTime.epoch
        )
    }

    /// updateTask(task, changes): only editable fields are taken from `changes`; the result is
    /// normalized as a whole (so clearing the due date also clears what depends on it).
    public static func updateTask(_ task: TaskItem, _ changes: [String: JSONValue], now: Date = Date()) -> TaskItem {
        var merged = task.json.objectValue ?? [:]
        for (key, value) in changes where editableFields.contains(key) { merged[key] = value }
        var result = self.task(
            id: task.id, fields: normalizeFields(merged), order: task.order, completedAt: task.completedAt,
            createdAt: task.createdAt, updatedAt: ISOTime.string(now)
        )
        result.order = task.order
        return result
    }
}

// MARK: - Subtasks

/// An optional, single-level checklist stored on the parent task. Array position = display order.
public enum Subtasks {
    public static let titleLimit = 200
    public static let limit = 100

    public static func generateId() -> String { "sub-\(UUID().uuidString.lowercased())" }

    public static func normalizeTitle(_ title: String) -> String {
        JSText.trimEnd(JSText.slice(JSText.trim(JSText.collapseWhitespace(title)), titleLimit))
    }

    /// Error code ("subtaskRequired") or nil.
    public static func validateTitle(_ title: String) -> String? {
        normalizeTitle(title).isEmpty ? "subtaskRequired" : nil
    }

    public static func create(_ title: String) -> Subtask {
        Subtask(id: generateId(), title: normalizeTitle(title), done: false)
    }

    /// Keeps only { id, title, done }, drops entries without an id or a title, removes duplicate
    /// ids and enforces the limit. Never nests.
    public static func normalize(_ raw: JSONValue?) -> [Subtask] {
        guard let list = raw?.arrayValue else { return [] }
        var seen = Set<String>()
        var result: [Subtask] = []
        for item in list {
            guard item.isPlainObject else { continue }
            let id = item["id"]?.stringValue.map { JSText.slice($0, 100) } ?? ""
            let title = normalizeTitle(JSText.string(item["title"]))
            if id.isEmpty || title.isEmpty || seen.contains(id) { continue }
            seen.insert(id)
            result.append(Subtask(id: id, title: title, done: item["done"] == .bool(true)))
            if result.count == limit { break }
        }
        return result
    }

    public static func normalize(_ list: [Subtask]) -> [Subtask] {
        normalize(.array(list.map(\.json)))
    }

    /// (done, total) for a task, or nil when it has no subtasks.
    public static func progress(_ task: TaskItem) -> (done: Int, total: Int)? {
        guard !task.subtasks.isEmpty else { return nil }
        return (task.subtasks.filter(\.done).count, task.subtasks.count)
    }
}
