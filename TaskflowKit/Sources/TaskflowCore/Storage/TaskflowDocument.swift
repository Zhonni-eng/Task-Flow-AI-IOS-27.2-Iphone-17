// The versioned Taskflow document (schema v4) - a port of the validation, migrations and
// normalization in electron/storage.cjs. Every file read from disk or imported goes through
// `DocumentCodec.toCurrentDocument`, which upgrades older versions, keeps only known fields and
// reports whether anything had to be repaired (so a copy of the original can be kept).
import Foundation

public enum Language: String, CaseIterable, Sendable, Codable, Hashable {
    case ru, en

    public static let `default` = Language.ru

    public var locale: Locale { Locale(identifier: self == .ru ? "ru_RU" : "en_US") }
    /// 1 = Monday (Russian), 0 = Sunday (English), as in the Windows app.
    public var weekStart: Int { self == .ru ? 1 : 0 }
    public var displayName: String { self == .ru ? "Русский" : "English" }
}

public enum BoardLayout: String, CaseIterable, Sendable, Codable, Hashable {
    case board, list
}

public struct LastView: Equatable, Sendable, Hashable {
    public var destination: String
    public var layout: BoardLayout
    public init(destination: String = Destination.allKey, layout: BoardLayout = .board) {
        self.destination = destination
        self.layout = layout
    }
    public var json: JSONValue { ["destination": .string(destination), "layout": .string(layout.rawValue)] }
}

public struct ReminderSettings: Equatable, Sendable, Hashable {
    public var enabled: Bool
    public var allDayTime: String
    public init(enabled: Bool = true, allDayTime: String = Schedule.defaultAllDayReminderTime) {
        self.enabled = enabled
        self.allDayTime = allDayTime
    }
    public var json: JSONValue { ["enabled": .bool(enabled), "allDayTime": .string(allDayTime)] }
}

/// Planning availability for day plans: "HH:MM" start before end.
public struct Availability: Equatable, Sendable, Hashable {
    public var start: String
    public var end: String
    public init(start: String, end: String) {
        self.start = start
        self.end = end
    }
    public var json: JSONValue { ["start": .string(start), "end": .string(end)] }
}

public struct AppSettings: Equatable, Sendable, Hashable {
    public var language: Language
    public var lastView: LastView
    public var reminders: ReminderSettings
    public var availability: Availability?

    public init(language: Language = .default, lastView: LastView = LastView(), reminders: ReminderSettings = ReminderSettings(), availability: Availability? = nil) {
        self.language = language
        self.lastView = lastView
        self.reminders = reminders
        self.availability = availability
    }

    public var json: JSONValue {
        [
            "language": .string(language.rawValue),
            "lastView": lastView.json,
            "reminders": reminders.json,
            "availability": availability?.json ?? .null,
        ]
    }
}

public struct TaskflowDocument: Equatable, Sendable {
    public var settings: AppSettings
    public var categories: [TaskCategory]
    public var tasks: [TaskItem]

    public init(settings: AppSettings = AppSettings(), categories: [TaskCategory] = [], tasks: [TaskItem] = []) {
        self.settings = settings
        self.categories = categories
        self.tasks = tasks
    }

    public static func empty(language: Language = .default) -> TaskflowDocument {
        TaskflowDocument(settings: AppSettings(language: language))
    }

    /// The file form, identical to the Windows app's `taskflow-data.json`.
    public func json(savedAt: Date = Date()) -> JSONValue {
        [
            "schemaVersion": .number(Double(DocumentCodec.schemaVersion)),
            "savedAt": .string(ISOTime.string(savedAt)),
            "settings": settings.json,
            "categories": .array(categories.map(\.json)),
            "tasks": .array(tasks.map(\.json)),
        ]
    }

    public func fileData(savedAt: Date = Date()) -> Data {
        json(savedAt: savedAt).serialized(pretty: true)
    }
}

public enum DocumentCodec {
    public static let schemaVersion = 4
    public static let fileName = "taskflow-data.json"
    public static let maxFileBytes = 20 * 1024 * 1024
    public static let maxTasks = 5000
    public static let maxCategories = 200
    static let maxCategoryName = 60
    static let maxSubtasks = 100
    static let maxSubtaskTitle = 200
    static let taskLimits = (id: 100, title: 120, description: 2000, label: 30, labels: 10)

    static let docKeys = ["schemaVersion", "savedAt", "settings", "categories", "tasks"]
    static let settingsKeys = ["language", "lastView", "reminders", "availability"]
    static let reminderSettingsKeys = ["enabled", "allDayTime"]
    static let availabilityKeys = ["start", "end"]
    static let lastViewKeys = ["destination", "layout"]
    static let taskKeys = [
        "id", "title", "description", "priority", "dueDate", "dueTime", "reminders", "recurrence", "estimateMinutes", "planned",
        "labels", "status", "order", "categoryId", "subtasks", "completedAt", "createdAt", "updatedAt",
    ]
    static let categoryKeys = ["id", "name", "order", "createdAt"]

    public enum Failure: Error, Equatable {
        /// Written by a newer Taskflow: never overwrite it.
        case newerVersion(Int)
        /// Not JSON, or not a Taskflow document.
        case invalid
    }

    public struct Result: Sendable {
        public var document: TaskflowDocument
        /// Records that could not be used at all (no id or title, duplicates, over the limits).
        public var dropped: Int
        /// Anything had to be fixed: keep a copy of the original.
        public var repaired: Bool
        /// Upgraded from an older schema version: keep a copy of the original.
        public var migrated: Bool
        public var sourceVersion: Int
    }

    static func hasUnknownKeys(_ value: JSONValue?, _ known: [String]) -> Bool {
        guard let dict = value?.objectValue else { return false }
        return dict.keys.contains { !known.contains($0) }
    }

    static func limited(_ value: JSONValue?, _ max: Int) -> String? {
        value?.stringValue.map { JSText.slice($0, max) }
    }

    // MARK: Migrations (each converts version N to N + 1)

    static func migrate(_ doc: JSONValue, from version: Int) -> JSONValue {
        func mapTasks(_ doc: JSONValue, _ transform: ([String: JSONValue]) -> [String: JSONValue]) -> JSONValue? {
            guard let list = doc["tasks"]?.arrayValue else { return doc["tasks"] }
            return .array(list.map { item in item.objectValue.map { .object(transform($0)) } ?? item })
        }
        var dict = doc.objectValue ?? [:]
        switch version {
        case 0:
            // v0: unversioned data - either a bare task array or an object without schemaVersion.
            let tasks: JSONValue? = doc.arrayValue != nil ? doc : doc["tasks"]
            var settings: JSONValue = ["language": .string(Language.default.rawValue)]
            if doc.arrayValue == nil, let raw = doc["settings"], raw != .null, raw != .bool(false) { settings = raw }
            var next: [String: JSONValue] = ["settings": settings]
            if let tasks { next["tasks"] = tasks }
            return .object(next)
        case 1:
            // v1 -> v2: categories were introduced. Existing tasks become uncategorized.
            dict["categories"] = .array([])
            dict["tasks"] = mapTasks(doc) { task in
                var copy = task
                copy["categoryId"] = .null
                return copy
            }
            return .object(dict)
        case 2:
            // v2 -> v3: optional subtasks. Existing tasks get an empty list (kept when present).
            dict["tasks"] = mapTasks(doc) { task in
                var copy = task
                if task["subtasks"]?.arrayValue == nil { copy["subtasks"] = .array([]) }
                return copy
            }
            return .object(dict)
        case 3:
            // v3 -> v4: due times, reminders, recurrence, estimates, day-plan slots and the completion
            // time. Completed tasks take their last update as the best known completion time.
            dict["tasks"] = mapTasks(doc) { task in
                var copy = task
                copy["dueTime"] = task["dueTime"].flatMap { $0 == .null ? nil : $0 } ?? .null
                copy["reminders"] = task["reminders"]?.arrayValue != nil ? task["reminders"]! : .array([])
                copy["recurrence"] = task["recurrence"].flatMap { $0 == .null ? nil : $0 } ?? .null
                copy["estimateMinutes"] = task["estimateMinutes"].flatMap { $0 == .null ? nil : $0 } ?? .null
                copy["planned"] = task["planned"].flatMap { $0 == .null ? nil : $0 } ?? .null
                if let completed = task["completedAt"] {
                    copy["completedAt"] = completed
                } else if task["status"] == "done", let updated = task["updatedAt"]?.stringValue {
                    copy["completedAt"] = .string(updated)
                } else {
                    copy["completedAt"] = .null
                }
                return copy
            }
            return .object(dict)
        default:
            return doc
        }
    }

    // MARK: Sanitizing

    /// Same rules as normalizeLabels: collapsed whitespace, no empty or duplicate labels.
    static func sanitizeLabels(_ raw: JSONValue?) -> [String] {
        guard let list = raw?.arrayValue else { return [] }
        var seen = Set<String>()
        var labels: [String] = []
        for item in list {
            guard let text = item.stringValue else { continue }
            let label = JSText.trimEnd(JSText.slice(JSText.trim(JSText.collapseWhitespace(text)), taskLimits.label))
            let key = JSText.lower(label)
            if label.isEmpty || seen.contains(key) { continue }
            seen.insert(key)
            labels.append(label)
            if labels.count == taskLimits.labels { break }
        }
        return labels
    }

    static func sanitizeSubtasks(_ raw: JSONValue?) -> (subtasks: [Subtask], changed: Bool) {
        guard let raw else { return ([], false) }
        guard let list = raw.arrayValue else { return ([], true) }
        var seen = Set<String>()
        var subtasks: [Subtask] = []
        for item in list.prefix(maxSubtasks) {
            let id = item.isPlainObject ? limited(item["id"], 100) : nil
            let title = item.isPlainObject && item["title"]?.stringValue != nil
                ? JSText.trimEnd(JSText.slice(JSText.trim(JSText.collapseWhitespace(item["title"]!.stringValue!)), maxSubtaskTitle)) : ""
            guard let id, !id.isEmpty, !title.isEmpty, !seen.contains(id) else { continue }
            seen.insert(id)
            subtasks.append(Subtask(id: id, title: title, done: item["done"] == .bool(true)))
        }
        let changed = subtasks.count != list.count || subtasks.enumerated().contains { index, subtask in
            let original = list[index]
            return .string(subtask.id) != original["id"] || .string(subtask.title) != original["title"]
                || .bool(subtask.done) != original["done"] || (original.objectValue?.count ?? 0) != 3
        }
        return (subtasks, changed)
    }

    /// A clean task containing only known fields, or nil when the record cannot be used (no id or
    /// no title). `changed` reports whether any field had to be fixed.
    static func sanitizeTask(_ raw: JSONValue) -> (task: TaskItem?, changed: Bool) {
        guard raw.isPlainObject else { return (nil, true) }
        let id = limited(raw["id"], taskLimits.id)
        let title = raw["title"]?.stringValue.map { JSText.trimEnd(JSText.slice(JSText.trim($0), taskLimits.title)) } ?? ""
        guard let id, !id.isEmpty, !title.isEmpty else { return (nil, true) }

        let subtaskResult = sanitizeSubtasks(raw["subtasks"])
        let labels = sanitizeLabels(raw["labels"])
        let rawDue = raw["dueDate"]?.stringValue
        let dueDate = Schedule.isDateKey(rawDue) ? rawDue : nil
        let dueTime = Schedule.normalizeDueTime(raw["dueTime"]?.stringValue, dueDate: dueDate)
        let reminders = Schedule.normalizeReminders(raw["reminders"], dueDate: dueDate, dueTime: dueTime)
        let recurrence = Schedule.normalizeRecurrence(raw["recurrence"], dueDate: dueDate)
        let planned = TaskModel.normalizePlanned(raw["planned"])
        let categoryText = raw["categoryId"]?.stringValue
        let task = TaskItem(
            id: id,
            title: title,
            description: raw["description"]?.stringValue.map { JSText.trimEnd(JSText.slice(JSText.trim($0), taskLimits.description)) } ?? "",
            priority: raw["priority"]?.stringValue.flatMap(Priority.init(rawValue:)) ?? .medium,
            dueDate: dueDate,
            dueTime: dueTime,
            reminders: reminders,
            recurrence: recurrence,
            estimateMinutes: Schedule.normalizeEstimate(raw["estimateMinutes"]),
            planned: planned,
            labels: labels,
            status: raw["status"]?.stringValue.flatMap(TaskStatus.init(rawValue:)) ?? .todo,
            order: raw["order"]?.finiteNumber ?? 0,
            categoryId: (categoryText?.isEmpty == false) ? JSText.slice(categoryText!, 100) : nil,
            subtasks: subtaskResult.subtasks,
            completedAt: limited(raw["completedAt"], 40),
            createdAt: limited(raw["createdAt"], 40) ?? ISOTime.epoch,
            updatedAt: limited(raw["updatedAt"], 40) ?? ISOTime.epoch
        )
        let orNull = { (value: JSONValue?) in value ?? .null }
        let rawLabels = raw["labels"]?.arrayValue ?? []
        let changed =
            hasUnknownKeys(raw, taskKeys)
            || .string(task.id) != raw["id"]
            || .string(task.description) != (raw["description"].flatMap { $0 == .null ? nil : $0 } ?? .string(""))
            || .string(task.priority.rawValue) != raw["priority"]
            || JSONValue.from(task.dueDate) != orNull(raw["dueDate"])
            || JSONValue.from(task.dueTime) != orNull(raw["dueTime"])
            || JSONValue.from(task.reminders) != (raw["reminders"].flatMap { $0 == .null ? nil : $0 } ?? .array([]))
            || (task.recurrence?.json ?? .null) != orNull(raw["recurrence"])
            || JSONValue.from(task.estimateMinutes) != orNull(raw["estimateMinutes"])
            || (task.planned?.json ?? .null) != orNull(raw["planned"])
            || JSONValue.from(task.completedAt) != orNull(raw["completedAt"])
            || .string(task.status.rawValue) != raw["status"]
            || .number(task.order) != raw["order"]
            || JSONValue.from(task.categoryId) != orNull(raw["categoryId"])
            || subtaskResult.changed
            || labels.count != rawLabels.count
            || labels.enumerated().contains { .string($0.element) != rawLabels[$0.offset] }
            || .string(task.createdAt) != raw["createdAt"]
            || .string(task.updatedAt) != raw["updatedAt"]
            || .string(task.title) != raw["title"]
        return (task, changed)
    }

    /// Validates/normalizes a task array. Duplicate ids keep the first occurrence.
    static func sanitizeTasks(_ rawTasks: [JSONValue]) -> (tasks: [TaskItem], dropped: Int, changed: Bool) {
        var seen = Set<String>()
        var tasks: [TaskItem] = []
        var dropped = 0
        var changed = false
        for raw in rawTasks.prefix(maxTasks) {
            let result = sanitizeTask(raw)
            guard let task = result.task, !seen.contains(task.id) else {
                dropped += 1
                continue
            }
            seen.insert(task.id)
            if result.changed { changed = true }
            tasks.append(task)
        }
        dropped += max(0, rawTasks.count - maxTasks)
        return (tasks, dropped, changed || dropped > 0)
    }

    /// Validates categories: unique ids, non-empty names (case-insensitive unique).
    static func sanitizeCategories(_ raw: JSONValue?) -> (categories: [TaskCategory], dropped: Int, changed: Bool) {
        guard let list = raw?.arrayValue else { return ([], 0, raw != nil) }
        var ids = Set<String>()
        var names = Set<String>()
        var categories: [TaskCategory] = []
        var dropped = 0
        var changed = false
        for item in list.prefix(maxCategories) {
            let id = item.isPlainObject ? limited(item["id"], 100) : nil
            let name = item.isPlainObject && item["name"]?.stringValue != nil
                ? JSText.trimEnd(JSText.slice(JSText.trim(JSText.collapseWhitespace(item["name"]!.stringValue!)), maxCategoryName)) : ""
            guard let id, !id.isEmpty, !name.isEmpty, !ids.contains(id), !names.contains(JSText.lower(name)) else {
                dropped += 1
                continue
            }
            ids.insert(id)
            names.insert(JSText.lower(name))
            let category = TaskCategory(
                id: id, name: name,
                order: item["order"]?.finiteNumber ?? Double(categories.count),
                createdAt: limited(item["createdAt"], 40) ?? ISOTime.epoch
            )
            if hasUnknownKeys(item, categoryKeys) || .string(category.id) != item["id"] || .string(category.name) != item["name"]
                || .number(category.order) != item["order"] || .string(category.createdAt) != item["createdAt"] {
                changed = true
            }
            categories.append(category)
        }
        dropped += max(0, list.count - maxCategories)
        return (categories, dropped, changed || dropped > 0)
    }

    /// Tasks pointing at a category that does not exist become uncategorized.
    public static func detachUnknownCategories(_ tasks: [TaskItem], _ categories: [TaskCategory]) -> (tasks: [TaskItem], changed: Bool) {
        let known = Set(categories.map(\.id))
        var changed = false
        let result = tasks.map { task -> TaskItem in
            guard let categoryId = task.categoryId, !known.contains(categoryId) else { return task }
            changed = true
            var copy = task
            copy.categoryId = nil
            return copy
        }
        return (result, changed)
    }

    /// Validates the remembered view; an unknown category falls back to All tasks.
    public static func sanitizeLastView(_ raw: JSONValue?, categories: [TaskCategory]) -> LastView {
        guard let raw, raw.isPlainObject else { return LastView() }
        let layout = raw["layout"]?.stringValue.flatMap(BoardLayout.init(rawValue:)) ?? .board
        let destination = raw["destination"]?.stringValue
        let known = destination.map { key in key == Destination.allKey || key == Destination.uncategorizedKey || categories.contains { $0.id == key } } ?? false
        return LastView(destination: known ? destination! : Destination.allKey, layout: layout)
    }

    static func sanitizeReminderSettings(_ raw: JSONValue?) -> ReminderSettings {
        guard let raw, raw.isPlainObject else { return ReminderSettings() }
        return ReminderSettings(
            enabled: raw["enabled"]?.boolValue ?? true,
            allDayTime: Schedule.isTimeKey(raw["allDayTime"]) ? raw["allDayTime"]!.stringValue! : Schedule.defaultAllDayReminderTime
        )
    }

    /// Planning availability { start, end } ("HH:MM", start before end) or nil (not set).
    public static func sanitizeAvailability(_ raw: JSONValue?) -> Availability? {
        guard let raw, raw.isPlainObject, let start = raw["start"]?.stringValue, let end = raw["end"]?.stringValue,
              Schedule.isTimeKey(start), Schedule.isTimeKey(end), start < end else { return nil }
        return Availability(start: start, end: end)
    }

    static func sanitizeSettings(_ raw: JSONValue?, categories: [TaskCategory]) -> (settings: AppSettings, changed: Bool) {
        let object = raw?.isPlainObject == true ? raw : nil
        let language = object?["language"]?.stringValue.flatMap(Language.init(rawValue:)) ?? .default
        let reminders = sanitizeReminderSettings(object?["reminders"])
        let availability = sanitizeAvailability(object?["availability"])
        let settings = AppSettings(
            language: language,
            lastView: sanitizeLastView(object?["lastView"], categories: categories),
            reminders: reminders,
            availability: availability
        )
        let changed =
            object == nil
            || object?["language"] != .string(language.rawValue)
            || hasUnknownKeys(object, settingsKeys)
            || hasUnknownKeys(object?["lastView"], lastViewKeys)
            || hasUnknownKeys(object?["reminders"], reminderSettingsKeys)
            || hasUnknownKeys(object?["availability"], availabilityKeys)
            || (object?["reminders"] != nil && object?["reminders"] != reminders.json)
            || (object?["availability"] != nil && object?["availability"] != .null && object?["availability"] != availability?.json)
        return (settings, changed)
    }

    // MARK: Document

    /// Parses and upgrades raw JSON into a current-version document.
    public static func toCurrentDocument(_ raw: JSONValue) throws -> Result {
        var doc = raw
        let sourceVersion = raw.isPlainObject ? (raw["schemaVersion"]?.intValue ?? 0) : 0
        var version = sourceVersion
        if version > schemaVersion { throw Failure.newerVersion(version) }
        let migrated = version < schemaVersion
        while version < schemaVersion {
            doc = migrate(doc, from: max(0, version))
            version = max(0, version) + 1
        }
        guard doc.isPlainObject, let rawTasks = doc["tasks"]?.arrayValue else { throw Failure.invalid }

        let tasks = sanitizeTasks(rawTasks)
        let categories = sanitizeCategories(doc["categories"])
        let linked = detachUnknownCategories(tasks.tasks, categories.categories)
        let settings = sanitizeSettings(doc["settings"], categories: categories.categories)
        return Result(
            document: TaskflowDocument(settings: settings.settings, categories: categories.categories, tasks: linked.tasks),
            dropped: tasks.dropped + categories.dropped,
            repaired: tasks.changed || categories.changed || linked.changed || settings.changed || hasUnknownKeys(doc, docKeys),
            migrated: migrated,
            sourceVersion: sourceVersion
        )
    }

    /// Reads file data (a UTF-8 BOM is accepted), refusing files over the size limit.
    public static func decode(_ data: Data) throws -> Result {
        if data.count > maxFileBytes { throw Failure.invalid }
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = bytes.dropFirst(3) }
        let raw: JSONValue
        do {
            raw = try JSONValue.parse(Data(bytes))
        } catch {
            throw Failure.invalid
        }
        return try toCurrentDocument(raw)
    }

    /// Normalizes a board before it is saved (as saveBoard does): valid categories, tasks with known
    /// categories only, and a remembered view that still exists.
    public static func normalizedForSave(_ document: TaskflowDocument) -> TaskflowDocument {
        let categories = sanitizeCategories(.array(document.categories.map(\.json))).categories
        let tasks = detachUnknownCategories(sanitizeTasks(document.tasks.map(\.json)).tasks, categories).tasks
        var settings = document.settings
        settings.lastView = sanitizeLastView(settings.lastView.json, categories: categories)
        return TaskflowDocument(settings: settings, categories: categories, tasks: tasks)
    }
}
