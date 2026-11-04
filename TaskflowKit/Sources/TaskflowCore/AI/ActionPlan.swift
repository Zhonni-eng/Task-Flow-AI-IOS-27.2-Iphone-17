// Validation of AI-proposed action plans - a port of src/ai/actionPlan.js. Everything a provider
// returns is untrusted input: this module only checks and normalizes it into entries a review UI
// can show. It never changes tasks - applying a validated plan is a separate step (ApplyPlan).
//
// Plan    = { actions: Action[], reply?, question? }
// Action  = { type: 'create', title, description?, dueDate?, dueTime?, priority?, status?,
//             categoryId?, newCategory?, subtasks?: string[], labels?, reminders?, recurrence?, estimateMinutes? }
//         | { type: 'update', taskId, changes: { <same fields; null / [] / '' clears>, addLabels?, removeLabels? } }
//         | { type: 'delete', taskId }
//         | { type: 'addSubtask', taskId, title } | { type: 'updateSubtask', taskId, subtaskId, title?, done? }
//         | { type: 'deleteSubtask', taskId, subtaskId } | { type: 'moveSubtask', taskId, subtaskId, toTaskId }
//         | { type: 'bulk', operation: 'update' | 'delete', filter, changes? }
//         | { type: 'renameLabel', label, newLabel } | { type: 'deleteLabel', label }   (every task with it)
//         | { type: 'schedule', date, items: [{ taskId, start }] }
//         | { type: 'none' }
//         (earlier versions' 'setStatus' / 'setDueDate' are accepted as updates)
//
// Tasks may only be changed when the provider was actually shown them (`allowedTaskIds`); bulk
// filters are resolved here, against the real data, so the user sees exactly which tasks a bulk
// change touches.
import Foundation

public struct BulkFilter: Equatable, Sendable {
    public var status: TaskStatus?
    public var priority: Priority?
    public var categoryId: String?
    public var due: String?
    public var completedOlderThanDays: Int?
    public var titleContains: String?
    public var scope: String?

    public var isEmpty: Bool {
        status == nil && priority == nil && categoryId == nil && due == nil && completedOlderThanDays == nil && titleContains == nil && scope == nil
    }
}

public struct ScheduleItem: Equatable, Sendable {
    public var taskId: String
    public var title: String
    public var start: String
    public var startMin: Int
    public var endMin: Int?
}

/// The validated, normalized form of one action (only for valid entries).
public enum NormalizedAction: Equatable, Sendable {
    case create(fields: [String: JSONValue], subtasks: [String], newCategory: String?)
    case update(taskId: String, changes: [String: JSONValue], newCategory: String?)
    case delete(taskId: String)
    case addSubtask(taskId: String, title: String)
    case updateSubtask(taskId: String, subtaskId: String, title: String?, done: Bool?)
    case deleteSubtask(taskId: String, subtaskId: String)
    case moveSubtask(taskId: String, subtaskId: String, toTaskId: String)
    case bulk(operation: String, filter: BulkFilter, changes: [String: JSONValue], newCategory: String?, matches: [String])
    case schedule(date: String, items: [ScheduleItem])
    case renameLabel(label: String, newLabel: String, matches: [String])
    case deleteLabel(label: String, matches: [String])
    case none
}

public struct PlanEntry: Equatable, Sendable {
    public var index: Int
    public var type: String?
    public var valid = false
    public var errors: [String] = []
    public var warnings: [String] = []
    public var normalized: NormalizedAction?
    public var target: TaskItem?
    public var destination: TaskItem?
    public var subtask: Subtask?
    public var category: TaskCategory?
    public var newCategory: String?
    /// Ids of the tasks a bulk / label action resolved to.
    public var matches: [String]?
    public var matchedTasks: [TaskItem]?
    public var duplicateOf: [String]?
    public var duplicateOfAction: Int?
    /// The fields of a create/update for the review text (also present when invalid).
    public var reviewChanges: [String: JSONValue]?

    mutating func error(_ code: String) { errors.append(code) }
    mutating func warn(_ code: String) { warnings.append(code) }
}

public struct PlanValidation: Equatable, Sendable {
    public var ok = false
    public var errors: [String] = []
    public var reply: String?
    public var question: String?
    public var actions: [PlanEntry] = []
}

public struct ValidationContext: Sendable {
    public var tasks: [TaskItem]?
    public var categories: [TaskCategory]?
    public var allowedTaskIds: [String]?
    public var availability: Availability?
    public var now: Date
    public var timeZone: TimeZone

    public init(tasks: [TaskItem]? = nil, categories: [TaskCategory]? = nil, allowedTaskIds: [String]? = nil, availability: Availability? = nil, now: Date = Date(), timeZone: TimeZone = .current) {
        self.tasks = tasks
        self.categories = categories
        self.allowedTaskIds = allowedTaskIds
        self.availability = availability
        self.now = now
        self.timeZone = timeZone
    }
}

public enum ActionPlan {
    public static let actionTypes = ["create", "update", "delete", "addSubtask", "updateSubtask", "deleteSubtask", "moveSubtask", "bulk", "schedule", "renameLabel", "deleteLabel", "none"]
    public static let maxActions = 50
    public static let maxBulkTasks = 500
    static let maxText = 2000
    static let maxId = 100
    static let fieldNames = ["title", "description", "priority", "status", "dueDate", "dueTime", "categoryId", "newCategory", "subtasks", "labels", "reminders", "recurrence", "estimateMinutes", "planned"]
    static let updateFields = fieldNames.filter { $0 != "subtasks" && $0 != "labels" } + ["addLabels", "removeLabels"]
    static let bulkFields = ["status", "priority", "categoryId", "newCategory", "dueDate", "dueTime", "addLabels", "removeLabels"]
    static let labelEdits = ["addLabels", "removeLabels"]
    static let filterFields = ["status", "categoryId", "priority", "due", "completedOlderThanDays", "titleContains", "scope"]
    static let dueFilters = ["overdue", "today", "upcoming", "noDate"]
    static let actionFields: [String: [String]] = [
        "create": ["type"] + fieldNames,
        "update": ["type", "taskId", "changes"],
        "delete": ["type", "taskId"],
        "addSubtask": ["type", "taskId", "title"],
        "updateSubtask": ["type", "taskId", "subtaskId", "title", "done"],
        "deleteSubtask": ["type", "taskId", "subtaskId"],
        "moveSubtask": ["type", "taskId", "subtaskId", "toTaskId"],
        "bulk": ["type", "operation", "filter", "changes"],
        "schedule": ["type", "date", "items"],
        "renameLabel": ["type", "label", "newLabel"],
        "deleteLabel": ["type", "label"],
        "none": ["type"],
    ]
    static let planFields = ["actions", "reply", "question"]
    /// Fields whose change is compared to tell "no change".
    static let compared = ["title", "description", "priority", "status", "dueDate", "dueTime", "categoryId", "reminders", "recurrence", "estimateMinutes", "planned"]

    static func checkId(_ value: JSONValue?) -> String? {
        guard let text = value?.stringValue, !text.isEmpty, JSText.length(text) <= maxId else { return nil }
        return text
    }

    static func titleKey(_ title: String) -> String { TaskViews.normalizeQuery(title) }
    static func labelKey(_ label: String) -> String { JSText.lower(label) }

    // MARK: Labels

    /// Labels a task has after adding `added` (trimmed, no case duplicates, limits).
    public static func withLabels(_ labels: [String], _ added: [String]) -> [String] {
        TaskModel.normalizeLabels(labels + added)
    }

    /// Labels after taking `removed` off and adding `added` (case-insensitive, existing ones kept).
    public static func editLabels(_ labels: [String], added: [String] = [], removed: [String] = []) -> [String] {
        let gone = Set(removed.map(labelKey))
        return withLabels(labels.filter { !gone.contains(labelKey($0)) }, added)
    }

    /// Labels with `from` renamed to `to` (merged when the task already has `to`).
    public static func renameLabel(in labels: [String], from: String, to: String) -> [String] {
        TaskModel.normalizeLabels(labels.map { labelKey($0) == labelKey(from) ? to : $0 })
    }

    static func strings(_ value: JSONValue?) -> [String] { value?.arrayValue?.compactMap(\.stringValue) ?? [] }

    static func changesLabels(_ task: TaskItem, _ values: [String: JSONValue]) -> Bool {
        editLabels(task.labels, added: strings(values["addLabels"]), removed: strings(values["removeLabels"])) != task.labels
    }

    static func hasLabel(_ task: TaskItem, _ label: String) -> Bool {
        task.labels.map(labelKey).contains(labelKey(label))
    }

    /// One label given by the provider, normalized, or nil.
    static func checkLabel(_ value: JSONValue?) -> String? {
        guard let text = value?.stringValue else { return nil }
        let trimmed = JSText.trim(text)
        guard !trimmed.isEmpty, JSText.length(trimmed) <= TaskModel.Limits.label else { return nil }
        return TaskModel.normalizeLabels([text]).first
    }

    static func exceedsLabels(_ task: TaskItem, _ added: [String]) -> Bool {
        let keys = task.labels.map(labelKey)
        return task.labels.count + added.filter { !keys.contains(labelKey($0)) }.count > TaskModel.Limits.labels
    }

    /// Earlier action types, accepted as updates.
    static func upgradeLegacy(_ raw: JSONValue) -> JSONValue {
        guard raw.isPlainObject else { return raw }
        if raw["type"] == "setStatus" {
            var changes: [String: JSONValue] = [:]
            changes["status"] = raw["status"]
            var action: [String: JSONValue] = ["type": "update", "changes": .object(changes)]
            action["taskId"] = raw["taskId"]
            return .object(action)
        }
        if raw["type"] == "setDueDate" {
            var changes: [String: JSONValue] = [:]
            changes["dueDate"] = raw["dueDate"]
            var action: [String: JSONValue] = ["type": "update", "changes": .object(changes)]
            action["taskId"] = raw["taskId"]
            return .object(action)
        }
        return raw
    }

    // MARK: Fields

    struct CheckedFields {
        var values: [String: JSONValue] = [:]
        var newCategory: String?
        var category: TaskCategory?
    }

    /// Checks task fields given by the provider. `base` is the task they apply to (nil for a new
    /// task). `values` holds only given fields, normalized.
    static func checkFields(_ raw: JSONValue, base: TaskItem?, categories: [TaskCategory]?, errors: inout [String]) -> CheckedFields {
        var result = CheckedFields()
        var values: [String: JSONValue] = [:]
        // `given`: present and not undefined (JSON has no undefined, so present).
        let given = { (field: String) in raw[field] != nil }

        if given("title") {
            if let title = raw["title"]?.stringValue, !JSText.trim(title).isEmpty {
                if JSText.length(JSText.trim(title)) > TaskModel.Limits.title { errors.append("titleTooLong") } else { values["title"] = .string(JSText.trim(title)) }
            } else {
                errors.append("titleRequired")
            }
        }
        if given("description") {
            let description = raw["description"]!
            if description != .null && (description.stringValue == nil || JSText.length(description.stringValue!) > TaskModel.Limits.description) {
                errors.append("invalidDescription")
            } else {
                values["description"] = .string(JSText.trim(description.stringValue ?? ""))
            }
        }
        if given("priority") {
            if let text = raw["priority"]?.stringValue, Priority(rawValue: text) != nil { values["priority"] = .string(text) } else { errors.append("invalidPriority") }
        }
        if given("status") {
            if let text = raw["status"]?.stringValue, TaskStatus(rawValue: text) != nil { values["status"] = .string(text) } else { errors.append("invalidStatus") }
        }
        if given("dueDate") {
            let rawDue = raw["dueDate"]!
            let key: JSONValue = rawDue.stringValue.map { .string(JSText.trim($0)) } ?? rawDue
            if key == .null { values["dueDate"] = .null } else if Schedule.isDateKey(key) { values["dueDate"] = key } else { errors.append("invalidDate") }
        }
        // Time, reminders and repeat depend on the due date the task will have.
        let dueDate: String?
        if let value = values["dueDate"] {
            dueDate = value.stringValue
        } else {
            dueDate = base?.dueDate
        }
        if given("dueTime") {
            let rawTime = raw["dueTime"]!
            let time: JSONValue = rawTime.stringValue.map { .string(JSText.trim($0)) } ?? rawTime
            if time == .null { values["dueTime"] = .null } else if !Schedule.isTimeKey(time) { errors.append("invalidTime") } else if dueDate == nil { errors.append("timeWithoutDate") } else { values["dueTime"] = time }
        }
        let dueTime: String?
        if let value = values["dueTime"] {
            dueTime = value.stringValue
        } else if values["dueDate"] == .null {
            dueTime = nil
        } else {
            dueTime = base?.dueTime
        }
        if given("reminders") {
            if let list = raw["reminders"]?.arrayValue {
                if list.isEmpty {
                    values["reminders"] = .array([])
                } else if dueDate == nil {
                    errors.append("remindersWithoutDate")
                } else {
                    let normalized = Schedule.normalizeReminders(raw["reminders"], dueDate: dueDate, dueTime: dueTime)
                    if normalized.count != Set(list).count { errors.append("invalidReminders") } else { values["reminders"] = .from(normalized) }
                }
            } else {
                errors.append("invalidReminders")
            }
        }
        if given("recurrence") {
            let rule = raw["recurrence"]!
            if rule == .null {
                values["recurrence"] = .null
            } else if !rule.isPlainObject || rule["freq"]?.stringValue.flatMap(Recurrence.Frequency.init(rawValue:)) == nil {
                errors.append("invalidRecurrence")
            } else if dueDate == nil {
                errors.append("recurrenceWithoutDate")
            } else {
                values["recurrence"] = Schedule.normalizeRecurrence(rule, dueDate: dueDate)?.json ?? .null
            }
        }
        if given("estimateMinutes") {
            let estimate = raw["estimateMinutes"]!
            if estimate == .null {
                values["estimateMinutes"] = .null
            } else if let minutes = Schedule.normalizeEstimate(estimate) {
                values["estimateMinutes"] = .number(Double(minutes))
            } else {
                errors.append("invalidEstimate")
            }
        }
        for field in ["labels", "addLabels", "removeLabels"] where given(field) {
            guard let list = raw[field]?.arrayValue,
                  list.allSatisfy({ item in item.stringValue.map { !JSText.trim($0).isEmpty && JSText.length(JSText.trim($0)) <= TaskModel.Limits.label } ?? false }) else {
                errors.append("invalidLabels")
                continue
            }
            let texts = list.compactMap(\.stringValue)
            let normalized = TaskModel.normalizeLabels(texts)
            if normalized.count < Set(texts.map { JSText.lower(JSText.trim($0)) }).count { errors.append("invalidLabels") } else { values[field] = .from(normalized) }
        }
        if let added = values["addLabels"], let removed = values["removeLabels"] {
            let addedKeys = strings(added).map(labelKey)
            if strings(removed).contains(where: { addedKeys.contains(labelKey($0)) }) { errors.append("labelConflict") }
        }
        if given("planned") {
            if raw["planned"] == .null { values["planned"] = .null } else { errors.append("unknownField") }
        }
        if given("categoryId"), raw["categoryId"] != .null, raw["categoryId"] != "" {
            if checkId(raw["categoryId"]) == nil {
                errors.append("invalidCategory")
            } else if let categories {
                if let category = categories.first(where: { .string($0.id) == raw["categoryId"] }) {
                    result.category = category
                    values["categoryId"] = .string(category.id)
                } else {
                    errors.append("unknownCategory")
                }
            } else {
                errors.append("notVerified")
            }
        } else if given("categoryId") {
            values["categoryId"] = .null
        }
        let hasCategoryValue = values["categoryId"].map { $0 != .null && $0 != "" } ?? false
        if given("newCategory"), raw["newCategory"] != "", raw["newCategory"] != .null, !hasCategoryValue {
            let text = raw["newCategory"]?.stringValue
            let name = text.map(CategoryModel.normalizeName) ?? ""
            if name.isEmpty || JSText.length(JSText.trim(text ?? "")) > CategoryModel.nameLimit {
                errors.append("invalidCategory")
            } else if let category = CategoryMatch.findMatching(name, in: categories ?? []) {
                // Reuse an existing category (other case, word form, synonym) before proposing a new one.
                result.category = category
                values["categoryId"] = .string(category.id)
            } else {
                result.newCategory = name
            }
        }
        result.values = values
        return result
    }

    // MARK: Bulk filters

    /// Tasks matching a bulk filter (the app decides, not the provider).
    public static func resolveBulkFilter(_ filter: BulkFilter, tasks: [TaskItem], now: Date = Date(), timeZone: TimeZone = .current) -> [TaskItem] {
        let todayKey = Schedule.localDateKey(now, timeZone: timeZone)
        let time = Schedule.localTimeKey(now, timeZone: timeZone)
        let titlePart = filter.titleContains.map(titleKey)
        let cutoff = filter.completedOlderThanDays.map { now.addingTimeInterval(-Double($0) * 86_400) }
        return tasks.filter { task in
            if let status = filter.status, task.status != status { return false }
            if let priority = filter.priority, task.priority != priority { return false }
            if let categoryId = filter.categoryId, task.categoryId != categoryId { return false }
            if let titlePart, !titleKey(task.title).contains(titlePart) { return false }
            if filter.due == "noDate" && task.dueDate != nil { return false }
            if filter.due == "overdue" {
                guard task.status != .done, let due = task.dueDate else { return false }
                let overdue = due < todayKey || (due == todayKey && task.dueTime != nil && task.dueTime! <= time)
                if !overdue { return false }
            }
            if filter.due == "today" && task.dueDate != todayKey { return false }
            if filter.due == "upcoming" && !(task.status != .done && task.dueDate != nil && task.dueDate! > todayKey) { return false }
            if let cutoff {
                // "Completed more than N days ago": done tasks with a known completion time only.
                guard task.status == .done, let completed = ISOTime.date(task.completedAt), completed < cutoff else { return false }
            }
            return true
        }
    }

    // MARK: Validation

    /// Validates a plan against the current data. Without `tasks` / `categories`, references to
    /// them cannot be checked and are errors ("notVerified").
    public static func validate(_ plan: JSONValue, context: ValidationContext = ValidationContext()) -> PlanValidation {
        var result = PlanValidation()
        guard plan.isPlainObject else {
            result.errors.append("invalidPlan")
            return result
        }
        if plan.keys.contains(where: { !planFields.contains($0) }) { result.errors.append("unknownField") }
        for field in ["reply", "question"] {
            guard let value = plan[field], value != .null else { continue }
            if let text = value.stringValue, JSText.length(text) <= maxText {
                let trimmed = JSText.trim(text)
                if field == "reply" { result.reply = trimmed.isEmpty ? nil : trimmed } else { result.question = trimmed.isEmpty ? nil : trimmed }
            } else {
                result.errors.append("invalid_\(field)")
            }
        }
        guard let actions = plan["actions"]?.arrayValue else {
            result.errors.append("invalidActions")
            return result
        }
        if actions.count > maxActions {
            result.errors.append("tooManyActions")
            return result
        }

        let now = context.now
        let tz = context.timeZone
        let tasks = context.tasks
        let categories = context.categories
        let taskById = tasks.map { Dictionary($0.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
        let allowed = context.allowedTaskIds.map(Set.init)
        var existingTitles: [String: [String]] = [:]
        for task in tasks ?? [] { existingTitles[titleKey(task.title), default: []].append(task.id) }
        var plannedTitles: [String: Int] = [:]
        var touched: [String: Int] = [:] // task id -> index of the first action touching it

        for (index, original) in actions.enumerated() {
            let raw = upgradeLegacy(original)
            var entry = PlanEntry(index: index)
            defer {
                entry.errors = unique(entry.errors)
                entry.warnings = unique(entry.warnings)
                entry.valid = entry.errors.isEmpty && entry.type != nil
                if !entry.valid { entry.normalized = nil }
                result.actions.append(entry)
            }
            guard raw.isPlainObject else {
                entry.error("invalidAction")
                continue
            }
            guard let type = raw["type"]?.stringValue, actionTypes.contains(type) else {
                entry.error("unknownType")
                continue
            }
            entry.type = type
            if raw.keys.contains(where: { !(actionFields[type] ?? []).contains($0) }) { entry.error("unknownField") }

            func checkTask(_ value: JSONValue?) -> TaskItem? {
                guard let taskId = checkId(value) else {
                    entry.error("invalidTaskId")
                    return nil
                }
                guard let taskById else {
                    entry.error("notVerified")
                    return nil
                }
                if let allowed, !allowed.contains(taskId) {
                    entry.error("notOffered")
                    return nil
                }
                guard let task = taskById[taskId] else {
                    entry.error("unknownTask")
                    return nil
                }
                return task
            }
            func touch(_ taskId: String) {
                if touched[taskId] != nil { entry.warn("conflictsWithEarlier") } else { touched[taskId] = index }
            }
            func checkSubtask(_ task: TaskItem?, _ value: JSONValue?) -> Subtask? {
                guard let subtaskId = checkId(value) else {
                    entry.error("invalidSubtask")
                    return nil
                }
                let subtask = task?.subtasks.first { $0.id == subtaskId }
                if task != nil && subtask == nil { entry.error("unknownSubtask") }
                return subtask
            }
            func validSubtaskTitle(_ value: JSONValue?) -> String? {
                guard let title = value?.stringValue, Subtasks.validateTitle(title) == nil, JSText.length(JSText.trim(title)) <= Subtasks.titleLimit else { return nil }
                return Subtasks.normalizeTitle(title)
            }

            switch type {
            case "create":
                if raw["title"]?.stringValue.map({ JSText.trim($0).isEmpty }) ?? true { entry.error("titleRequired") }
                let checked = checkFields(raw, base: nil, categories: categories, errors: &entry.errors)
                var subtasks: [String] = []
                if let rawSubtasks = raw["subtasks"] {
                    if let list = rawSubtasks.arrayValue, list.count <= Subtasks.limit {
                        for item in list {
                            guard let title = validSubtaskTitle(item) else {
                                entry.error("invalidSubtasks")
                                break
                            }
                            subtasks.append(title)
                        }
                    } else {
                        entry.error("invalidSubtasks")
                    }
                }
                let values = checked.values
                let fields: [String: JSONValue] = [
                    "title": values["title"] ?? "",
                    "description": values["description"] ?? "",
                    "priority": values["priority"] ?? .string(TaskModel.defaultPriority.rawValue),
                    "status": values["status"] ?? .string(TaskModel.defaultStatus.rawValue),
                    "dueDate": values["dueDate"] ?? .null,
                    "dueTime": values["dueTime"] ?? .null,
                    "reminders": values["reminders"] ?? .array([]),
                    "recurrence": values["recurrence"] ?? .null,
                    "estimateMinutes": values["estimateMinutes"] ?? .null,
                    "categoryId": values["categoryId"] ?? .null,
                    "labels": values["labels"] ?? .array([]),
                ]
                entry.normalized = .create(fields: fields, subtasks: subtasks, newCategory: checked.newCategory)
                entry.reviewChanges = fields.merging(["subtasks": .from(subtasks)]) { a, _ in a }
                entry.category = checked.category
                entry.newCategory = checked.newCategory
                if let title = values["title"]?.stringValue {
                    let key = titleKey(title)
                    if let ids = existingTitles[key] {
                        entry.warn("possibleDuplicate")
                        entry.duplicateOf = ids
                    }
                    if let earlier = plannedTitles[key] {
                        entry.warn("duplicateInPlan")
                        entry.duplicateOfAction = earlier
                    } else {
                        plannedTitles[key] = index
                    }
                }
            case "update":
                let task = checkTask(raw["taskId"])
                entry.target = task
                guard let changes = raw["changes"], changes.isPlainObject, !changes.keys.isEmpty else {
                    entry.error("invalidChanges")
                    break
                }
                if changes.keys.contains(where: { !updateFields.contains($0) }) { entry.error("unknownField") }
                var checked = checkFields(changes, base: task, categories: categories, errors: &entry.errors)
                // Clearing the due date clears what depends on it.
                if checked.values["dueDate"] == .null, task?.dueDate != nil {
                    checked.values["dueTime"] = .null
                    checked.values["reminders"] = .array([])
                    checked.values["recurrence"] = .null
                }
                if checked.values["dueTime"] == .null, let task, !task.reminders.isEmpty {
                    let date = checked.values["dueDate"]?.stringValue ?? task.dueDate
                    checked.values["reminders"] = .from(Schedule.normalizeReminders(task.reminders, dueDate: date, dueTime: nil))
                }
                let values = checked.values
                entry.normalized = .update(taskId: raw["taskId"]?.stringValue ?? "", changes: values, newCategory: checked.newCategory)
                entry.reviewChanges = values
                entry.category = checked.category
                entry.newCategory = checked.newCategory
                if let task {
                    let labelsChange = labelEdits.contains(where: { values[$0] != nil }) && changesLabels(task, values)
                    let current = task.json
                    if checked.newCategory == nil && !labelsChange && compared.allSatisfy({ field in values[field] == nil || values[field] == current[field] }) {
                        entry.warn("noChange")
                    }
                    if let added = values["addLabels"], exceedsLabels(task, strings(added)) { entry.warn("labelLimit") }
                    if values["status"] == "done", task.recurrence != nil, task.status != .done { entry.warn("advancesRecurrence") }
                    touch(task.id)
                }
            case "delete":
                let task = checkTask(raw["taskId"])
                entry.target = task
                entry.normalized = .delete(taskId: raw["taskId"]?.stringValue ?? "")
                if let task {
                    if !task.subtasks.isEmpty { entry.warn("deletesSubtasks") }
                    if task.recurrence != nil { entry.warn("deletesSeries") }
                    touch(task.id)
                }
            case "addSubtask":
                let task = checkTask(raw["taskId"])
                entry.target = task
                let title = validSubtaskTitle(raw["title"])
                if title == nil { entry.error("invalidSubtasks") } else if let task, task.subtasks.count >= Subtasks.limit { entry.error("tooManySubtasks") }
                let normalizedTitle = raw["title"]?.stringValue.map(Subtasks.normalizeTitle) ?? ""
                entry.normalized = .addSubtask(taskId: raw["taskId"]?.stringValue ?? "", title: normalizedTitle)
                if let task, task.subtasks.contains(where: { titleKey($0.title) == titleKey(normalizedTitle) }) { entry.warn("possibleDuplicate") }
                if let task { touch(task.id) }
            case "updateSubtask":
                let task = checkTask(raw["taskId"])
                entry.target = task
                let subtask = checkSubtask(task, raw["subtaskId"])
                var title: String?
                var done: Bool?
                if let rawTitle = raw["title"] {
                    if let valid = validSubtaskTitle(rawTitle) { title = valid } else { entry.error("invalidSubtasks") }
                }
                if let rawDone = raw["done"] {
                    if let flag = rawDone.boolValue { done = flag } else { entry.error("invalidSubtasks") }
                }
                if title == nil && done == nil && !entry.errors.contains("invalidSubtasks") { entry.error("invalidChanges") }
                entry.normalized = .updateSubtask(taskId: raw["taskId"]?.stringValue ?? "", subtaskId: raw["subtaskId"]?.stringValue ?? "", title: title, done: done)
                entry.subtask = subtask
                if let subtask, (title == nil || title == subtask.title), (done == nil || done == subtask.done) { entry.warn("noChange") }
                if let task { touch(task.id) }
            case "deleteSubtask":
                let task = checkTask(raw["taskId"])
                entry.target = task
                entry.subtask = checkSubtask(task, raw["subtaskId"])
                entry.normalized = .deleteSubtask(taskId: raw["taskId"]?.stringValue ?? "", subtaskId: raw["subtaskId"]?.stringValue ?? "")
                if let task { touch(task.id) }
            case "moveSubtask":
                let task = checkTask(raw["taskId"])
                entry.target = task
                entry.subtask = checkSubtask(task, raw["subtaskId"])
                let destination = checkTask(raw["toTaskId"])
                entry.destination = destination
                // One level only: a subtask moves between two different existing tasks, never into itself.
                if raw["toTaskId"] == raw["taskId"] { entry.error("sameTask") } else if let destination, destination.subtasks.count >= Subtasks.limit { entry.error("tooManySubtasks") }
                entry.normalized = .moveSubtask(taskId: raw["taskId"]?.stringValue ?? "", subtaskId: raw["subtaskId"]?.stringValue ?? "", toTaskId: raw["toTaskId"]?.stringValue ?? "")
                if let task { touch(task.id) }
                if let destination { touch(destination.id) }
            case "bulk":
                let operation = raw["operation"]?.stringValue ?? ""
                if !["update", "delete"].contains(operation) { entry.error("invalidOperation") }
                var filter = BulkFilter()
                if let f = raw["filter"], f.isPlainObject {
                    if f.keys.contains(where: { !filterFields.contains($0) }) { entry.error("unknownField") }
                    if let value = f["status"] {
                        if let status = value.stringValue.flatMap(TaskStatus.init(rawValue:)) { filter.status = status } else { entry.error("invalidFilter") }
                    }
                    if let value = f["priority"] {
                        if let priority = value.stringValue.flatMap(Priority.init(rawValue:)) { filter.priority = priority } else { entry.error("invalidFilter") }
                    }
                    if let value = f["due"] {
                        if let due = value.stringValue, dueFilters.contains(due) { filter.due = due } else { entry.error("invalidFilter") }
                    }
                    if let value = f["completedOlderThanDays"] {
                        if let days = value.intValue, days > 0, days <= 3650 { filter.completedOlderThanDays = days } else { entry.error("invalidFilter") }
                    }
                    if let value = f["titleContains"] {
                        if let text = value.stringValue, !JSText.trim(text).isEmpty, JSText.length(text) <= TaskModel.Limits.title { filter.titleContains = JSText.trim(text) } else { entry.error("invalidFilter") }
                    }
                    // "All tasks" must be said explicitly (scope 'all'); it matches every task, done ones included.
                    if let value = f["scope"] {
                        if value == "all" { filter.scope = "all" } else { entry.error("invalidFilter") }
                    }
                    if let value = f["categoryId"] {
                        if let categories {
                            if let id = value.stringValue, categories.contains(where: { $0.id == id }) { filter.categoryId = id } else { entry.error("unknownCategory") }
                        } else {
                            entry.error("notVerified")
                        }
                    }
                } else {
                    entry.error("invalidFilter")
                }
                // Never "all tasks" by omission: a bulk change needs a criterion or the explicit scope 'all'.
                if filter.isEmpty && !entry.errors.contains("invalidFilter") { entry.error("emptyFilter") }
                var values: [String: JSONValue] = [:]
                var newCategory: String?
                if operation == "update" {
                    let changes = raw["changes"]?.isPlainObject == true ? raw["changes"]! : .object([:])
                    if changes.keys.isEmpty { entry.error("invalidChanges") }
                    if changes.keys.contains(where: { !bulkFields.contains($0) }) { entry.error("unknownField") }
                    let checked = checkFields(changes, base: nil, categories: categories, errors: &entry.errors)
                    values = checked.values
                    newCategory = checked.newCategory
                    if let time = values["dueTime"], time != .null, values["dueDate"] == nil {
                        // A time for many tasks needs a date: only tasks that have one keep it valid.
                        entry.warn("timeKeepsDates")
                    }
                } else if let changes = raw["changes"], changes.isPlainObject, !changes.keys.isEmpty {
                    entry.error("unknownField")
                }
                if tasks == nil { entry.error("notVerified") }
                var matches = (tasks != nil && entry.errors.isEmpty) ? resolveBulkFilter(filter, tasks: tasks!, now: now, timeZone: tz) : []
                if let added = values["addLabels"], matches.contains(where: { exceedsLabels($0, strings(added)) }) { entry.warn("labelLimit") }
                // A change of tags only affects the tasks whose tags actually change (shown as such).
                if operation == "update", newCategory == nil, !values.isEmpty, values.keys.allSatisfy(labelEdits.contains) {
                    matches = matches.filter { changesLabels($0, values) }
                }
                if matches.count > maxBulkTasks { entry.error("tooManyTasks") }
                entry.matches = matches.map(\.id)
                entry.matchedTasks = matches
                entry.newCategory = newCategory
                entry.reviewChanges = values
                entry.normalized = .bulk(operation: operation, filter: filter, changes: values, newCategory: newCategory, matches: matches.map(\.id))
                if entry.errors.isEmpty && matches.isEmpty { entry.warn("noMatches") }
                for task in matches where touched[task.id] != nil { entry.warn("conflictsWithEarlier") }
                for task in matches where touched[task.id] == nil { touched[task.id] = index }
            case "schedule":
                let date = raw["date"]?.stringValue
                if !Schedule.isDateKey(date) { entry.error("invalidDate") } else if date! < Schedule.localDateKey(now, timeZone: tz) { entry.error("dateInPast") }
                guard let rawItems = raw["items"]?.arrayValue, !rawItems.isEmpty, rawItems.count <= maxActions else {
                    entry.error("invalidSchedule")
                    break
                }
                let availability = context.availability
                if availability == nil { entry.error("noAvailability") }
                var items: [ScheduleItem] = []
                for item in rawItems {
                    guard item.isPlainObject, let start = item["start"]?.stringValue, Schedule.isTimeKey(start) else {
                        entry.error("invalidSchedule")
                        break
                    }
                    guard let task = checkTask(item["taskId"]) else { continue }
                    if task.status == .done { entry.error("taskDone") }
                    let (hours, minutes) = Schedule.timeParts(start)
                    let startMin = hours * 60 + minutes
                    let endMin = task.estimateMinutes.map { startMin + $0 }
                    if task.estimateMinutes == nil { entry.warn("noEstimate") }
                    if let availability {
                        let (ah, am) = Schedule.timeParts(availability.start)
                        let (bh, bm) = Schedule.timeParts(availability.end)
                        if startMin < ah * 60 + am || (endMin ?? startMin) > bh * 60 + bm { entry.error("outsideAvailability") }
                    }
                    if let due = task.dueDate, let date, date > due { entry.warn("afterDeadline") }
                    items.append(ScheduleItem(taskId: task.id, title: task.title, start: start, startMin: startMin, endMin: endMin))
                    touch(task.id)
                }
                let sorted = items.sorted { $0.startMin < $1.startMin }
                for i in sorted.indices.dropFirst() {
                    if let end = sorted[i - 1].endMin, sorted[i].startMin < end { entry.error("overlap") }
                }
                entry.normalized = .schedule(date: date ?? "", items: items)
            case "renameLabel", "deleteLabel":
                // Global: every task that has the label (any case), resolved by the app like a bulk change.
                let rename = type == "renameLabel"
                let label = checkLabel(raw["label"])
                let newLabel = rename ? checkLabel(raw["newLabel"]) : nil
                if label == nil || (rename && newLabel == nil) { entry.error("invalidLabels") }
                if tasks == nil { entry.error("notVerified") }
                let matches = (label != nil && tasks != nil) ? tasks!.filter { hasLabel($0, label!) } : []
                if label != nil && tasks != nil && matches.isEmpty { entry.error("unknownLabel") }
                if matches.count > maxBulkTasks { entry.error("tooManyTasks") }
                if rename, let label, newLabel == label { entry.warn("noChange") }
                entry.matches = matches.map(\.id)
                entry.matchedTasks = matches
                entry.normalized = rename
                    ? .renameLabel(label: label ?? "", newLabel: newLabel ?? "", matches: matches.map(\.id))
                    : .deleteLabel(label: label ?? "", matches: matches.map(\.id))
                for task in matches where touched[task.id] != nil { entry.warn("conflictsWithEarlier") }
                for task in matches where touched[task.id] == nil { touched[task.id] = index }
            case "none":
                entry.normalized = NormalizedAction.none
            default:
                break
            }
        }

        result.ok = result.errors.isEmpty && result.actions.allSatisfy(\.valid)
        return result
    }

    static func unique(_ list: [String]) -> [String] {
        var seen = Set<String>()
        return list.filter { seen.insert($0).inserted }
    }
}
