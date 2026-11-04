// The structured answer every provider is asked for and its conversion into the app's action-plan
// format - a port of electron/ai/providers/shared.cjs. Errors are mapped to app codes by HTTP
// status / failure kind only - never by (or with) response text, which could echo the key.
import Foundation

public enum WirePlan {
    public static let maxResponseChars = 64 * 1024
    public static let maxBodyChars = 2 * 1024 * 1024
    public static let maxActions = 50

    // A rename is always an explicit `newTitle`. `title` only names a NEW task or subtask: strict
    // output makes every action carry every field, and models fill `title` of other actions with
    // the existing task's title - which must never turn "mark it done" into a rename.
    public static let actionTypes = ["create", "update", "delete", "addSubtask", "updateSubtask", "deleteSubtask", "moveSubtask", "bulk", "schedule", "renameLabel", "deleteLabel"]
    public static let clearable = ["dueDate", "dueTime", "description", "categoryId", "reminders", "recurrence", "estimateMinutes", "planned"]

    private static let str: JSONValue = ["type": "string"]
    private static let int: JSONValue = ["type": "integer"]
    private static func choice(_ values: [String]) -> JSONValue { ["type": "string", "enum": .from(["unset"] + values)] }
    private static func object(_ properties: [(String, JSONValue)]) -> JSONValue {
        [
            "type": "object",
            "properties": .object(Dictionary(properties, uniquingKeysWith: { a, _ in a })),
            "required": .from(properties.map(\.0)),
            "additionalProperties": false,
        ]
    }

    /// JSON Schema, strict-mode compatible: every field required, no extra fields.
    public static let responseSchema: JSONValue = object([
        ("reply", str),
        ("question", str),
        ("actions", [
            "type": "array",
            "items": object([
                ("type", ["type": "string", "enum": .from(actionTypes)]),
                ("taskId", str),
                ("subtaskId", str),
                ("toTaskId", str),
                ("title", str),
                ("newTitle", str),
                ("description", str),
                ("status", choice(["todo", "inProgress", "done"])),
                ("priority", choice(["low", "medium", "high"])),
                ("dueDate", str),
                ("dueTime", str),
                ("categoryId", str),
                ("newCategory", str),
                ("subtasks", ["type": "array", "items": str]),
                ("labels", ["type": "array", "items": str]),
                ("removeLabels", ["type": "array", "items": str]),
                ("label", str),
                ("newLabel", str),
                ("reminders", ["type": "array", "items": int]),
                ("recurrence", object([("freq", choice(["daily", "weekly", "monthly"])), ("interval", int), ("weekdays", ["type": "array", "items": int]), ("monthDay", int)])),
                ("estimateMinutes", int),
                ("done", choice(["true", "false"])),
                ("clear", ["type": "array", "items": ["type": "string", "enum": .from(clearable)]]),
                ("filter", object([
                    ("status", choice(["todo", "inProgress", "done"])),
                    ("categoryId", str),
                    ("priority", choice(["low", "medium", "high"])),
                    ("due", choice(["overdue", "today", "upcoming", "noDate"])),
                    ("completedOlderThanDays", int),
                    ("titleContains", str),
                    ("scope", choice(["all"])),
                ])),
                ("operation", choice(["update", "delete"])),
                ("date", str),
                ("items", ["type": "array", "items": object([("taskId", str), ("start", str)])]),
            ]),
        ]),
    ])

    static func isSet(_ value: JSONValue?) -> Bool {
        guard let text = value?.stringValue else { return false }
        return !text.isEmpty && text != "unset"
    }

    static func hasLabels(_ raw: JSONValue, _ key: String = "labels") -> Bool {
        (raw[key]?.arrayValue?.isEmpty == false)
    }

    /// Task fields given in a wire action, plus cleared ones as null/[]. `titleFrom`: which wire
    /// field sets the title - "title" for create, "newTitle" for update, nil for bulk.
    static func fields(of raw: JSONValue, titleFrom: String?) -> [String: JSONValue]? {
        var fields: [String: JSONValue] = [:]
        if let titleFrom, isSet(raw[titleFrom]) { fields["title"] = raw[titleFrom] }
        for key in ["description", "dueDate", "dueTime", "categoryId", "newCategory"] where isSet(raw[key]) { fields[key] = raw[key] }
        for key in ["status", "priority"] where isSet(raw[key]) { fields[key] = raw[key] }
        if let list = raw["subtasks"]?.arrayValue, !list.isEmpty { fields["subtasks"] = .array(list) }
        if let list = raw["reminders"]?.arrayValue, !list.isEmpty { fields["reminders"] = .array(list) }
        if let rule = raw["recurrence"], rule.isPlainObject, isSet(rule["freq"]) {
            var result: [String: JSONValue] = ["freq": rule["freq"]!]
            let interval = rule["interval"]
            // `interval || 1`: 0, missing and non-numbers fall back to 1.
            if let interval, interval != .number(0), interval != .null, interval != .bool(false), interval != .string("") {
                result["interval"] = interval
            } else {
                result["interval"] = 1
            }
            if let days = rule["weekdays"]?.arrayValue, !days.isEmpty { result["weekdays"] = .array(days) }
            if let day = rule["monthDay"]?.intValue, day > 0 { result["monthDay"] = .number(Double(day)) }
            fields["recurrence"] = .object(result)
        }
        if let estimate = raw["estimateMinutes"]?.intValue, estimate > 0 { fields["estimateMinutes"] = .number(Double(estimate)) }
        if let clear = raw["clear"]?.arrayValue {
            for key in clear {
                guard let name = key.stringValue, clearable.contains(name) else { return nil }
                fields[name] = name == "reminders" ? .array([]) : name == "description" ? .string("") : .null
            }
        }
        return fields
    }

    /// One wire action -> an action of the app's plan format (validated later), or nil.
    static func toAction(_ raw: JSONValue) -> JSONValue? {
        guard raw.isPlainObject, let type = raw["type"]?.stringValue, actionTypes.contains(type) else { return nil }
        func pass(_ keys: [String]) -> [String: JSONValue] {
            var result: [String: JSONValue] = ["type": .string(type)]
            for key in keys { result[key] = raw[key] }
            return result
        }
        switch type {
        case "create":
            guard var fields = fields(of: raw, titleFrom: "title") else { return nil }
            if hasLabels(raw) { fields["labels"] = raw["labels"] }
            fields["type"] = "create"
            fields["title"] = raw["title"]
            return .object(fields)
        case "update":
            guard var changes = fields(of: raw, titleFrom: "newTitle") else { return nil }
            if hasLabels(raw) { changes["addLabels"] = raw["labels"] }
            if hasLabels(raw, "removeLabels") { changes["removeLabels"] = raw["removeLabels"] }
            var action = pass(["taskId"])
            action["changes"] = .object(changes)
            return .object(action)
        case "delete":
            return .object(pass(["taskId"]))
        case "addSubtask":
            return .object(pass(["taskId", "title"]))
        case "updateSubtask":
            var action = pass(["taskId", "subtaskId"])
            if isSet(raw["newTitle"]) { action["title"] = raw["newTitle"] }
            if raw["done"] == "true" || raw["done"] == "false" { action["done"] = .bool(raw["done"] == "true") }
            return .object(action)
        case "deleteSubtask":
            return .object(pass(["taskId", "subtaskId"]))
        case "moveSubtask":
            return .object(pass(["taskId", "subtaskId", "toTaskId"]))
        case "bulk":
            guard var changes = fields(of: raw, titleFrom: nil), let rawFilter = raw["filter"], rawFilter.isPlainObject else { return nil }
            if hasLabels(raw) { changes["addLabels"] = raw["labels"] }
            if hasLabels(raw, "removeLabels") { changes["removeLabels"] = raw["removeLabels"] }
            var filter: [String: JSONValue] = [:]
            for key in ["status", "priority", "due", "categoryId", "titleContains"] where isSet(rawFilter[key]) { filter[key] = rawFilter[key] }
            if let days = rawFilter["completedOlderThanDays"]?.intValue, days > 0 { filter["completedOlderThanDays"] = .number(Double(days)) }
            if rawFilter["scope"] == "all" { filter["scope"] = "all" }
            var action = pass(["operation"])
            action["filter"] = .object(filter)
            action["changes"] = .object(changes)
            return .object(action)
        case "renameLabel":
            return .object(pass(["label", "newLabel"]))
        case "deleteLabel":
            return .object(pass(["label"]))
        case "schedule":
            var action = pass(["date"])
            if let items = raw["items"]?.arrayValue {
                action["items"] = .array(items.filter(\.isPlainObject).map { item in
                    var entry: [String: JSONValue] = [:]
                    entry["taskId"] = item["taskId"]
                    entry["start"] = item["start"]
                    return .object(entry)
                })
            } else {
                action["items"] = raw["items"]
            }
            return .object(action)
        default:
            return nil
        }
    }

    /// Answers in the format of earlier versions ({ tasks, statusChanges, dueDateChanges }).
    static func legacyActions(_ parsed: JSONValue) -> [JSONValue]? {
        var actions: [JSONValue] = []
        for task in parsed["tasks"]?.arrayValue ?? [] {
            guard task.isPlainObject else { return nil }
            var action: [String: JSONValue] = ["type": "create"]
            action["title"] = task["title"]
            if let due = task["dueDate"], due != "" { action["dueDate"] = due }
            if let priority = task["priority"] { action["priority"] = priority }
            if let category = task["categoryId"], category != "" { action["categoryId"] = category }
            if let subtasks = task["subtasks"]?.arrayValue, !subtasks.isEmpty { action["subtasks"] = .array(subtasks) }
            actions.append(.object(action))
        }
        for change in parsed["statusChanges"]?.arrayValue ?? [] {
            guard change.isPlainObject else { return nil }
            var action: [String: JSONValue] = ["type": "update"]
            action["taskId"] = change["taskId"]
            var changes: [String: JSONValue] = [:]
            changes["status"] = change["status"]
            action["changes"] = .object(changes)
            actions.append(.object(action))
        }
        for change in parsed["dueDateChanges"]?.arrayValue ?? [] {
            guard change.isPlainObject else { return nil }
            var action: [String: JSONValue] = ["type": "update"]
            action["taskId"] = change["taskId"]
            var changes: [String: JSONValue] = [:]
            changes["dueDate"] = change["dueDate"] == "" ? .null : change["dueDate"]
            action["changes"] = .object(changes)
            actions.append(.object(action))
        }
        return actions
    }

    /// Turns the model's JSON into the app's action-plan format, or nil when it is not usable.
    public static func toPlan(_ parsed: JSONValue) -> JSONValue? {
        guard parsed.isPlainObject, let reply = parsed["reply"]?.stringValue, let question = parsed["question"]?.stringValue else { return nil }
        var actions: [JSONValue]
        if let list = parsed["actions"]?.arrayValue {
            if list.count > maxActions { return nil }
            var converted: [JSONValue] = []
            for item in list {
                guard let action = toAction(item) else { return nil }
                converted.append(action)
            }
            actions = converted
        } else {
            for key in ["tasks", "statusChanges", "dueDateChanges"] {
                if let value = parsed[key], value.arrayValue == nil { return nil }
            }
            guard let legacy = legacyActions(parsed), legacy.count <= maxActions else { return nil }
            actions = legacy
        }
        if actions.isEmpty { actions = [["type": "none"]] }
        return ["reply": .string(reply), "question": .string(question), "actions": .array(actions)]
    }

    /// The model's answer text -> a plan, or "MALFORMED".
    public static func planFromText(_ text: String?) -> Swift.Result<JSONValue, AICode> {
        guard let text, !text.isEmpty, JSText.length(text) <= maxResponseChars, let parsed = try? JSONValue.parse(text), let plan = toPlan(parsed) else {
            return .failure(.malformed)
        }
        return .success(plan)
    }

    /// App code for an HTTP error status (the same mapping for every provider).
    public static func code(forStatus status: Int) -> AICode {
        switch status {
        case 401: return .auth
        case 403: return .permission
        case 404: return .modelUnavailable
        case 429: return .rateLimit
        case 529, 503: return .overloaded
        case 500...: return .providerError
        case 400, 413, 422: return .badRequest
        default: return .providerError
        }
    }

    /// The app's JSON Schema in Gemini's Schema format (OpenAPI subset: upper-case types, no
    /// additionalProperties). propertyOrdering keeps the documented field order.
    public static func geminiSchema(_ schema: JSONValue) -> JSONValue {
        var out: [String: JSONValue] = ["type": .string(JSText.string(schema["type"]).uppercased())]
        if let values = schema["enum"] { out["enum"] = values }
        if let items = schema["items"] { out["items"] = geminiSchema(items) }
        if let properties = schema["properties"]?.objectValue {
            out["properties"] = .object(properties.mapValues(geminiSchema))
            let order = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? properties.keys.sorted()
            out["propertyOrdering"] = .from(order)
        }
        if let required = schema["required"] { out["required"] = required }
        return .object(out)
    }
}

/// App-level result codes of AI requests (never containing provider text).
public enum AICode: String, Error, Sendable, Equatable {
    case auth = "AUTH"
    case permission = "PERMISSION"
    case modelUnavailable = "MODEL_UNAVAILABLE"
    case rateLimit = "RATE_LIMIT"
    case overloaded = "OVERLOADED"
    case providerError = "PROVIDER_ERROR"
    case badRequest = "BAD_REQUEST"
    case timeout = "TIMEOUT"
    case network = "NETWORK"
    case malformed = "MALFORMED"
    case refused = "REFUSED"
    case truncated = "TRUNCATED"
    case cancelled = "CANCELLED"
    case endpointNotFound = "ENDPOINT_NOT_FOUND"
    case aiDisabled = "AI_DISABLED"
    case noKey = "NO_KEY"
    case providerUnsupported = "PROVIDER_UNSUPPORTED"
    case conversationLimit = "CONVERSATION_LIMIT"
    case invalidMessage = "INVALID_MESSAGE"
    case busy = "BUSY"
    case invalidKey = "INVALID_KEY"
    case unidentifiedKey = "UNIDENTIFIED_KEY"
    case ambiguousKey = "AMBIGUOUS_KEY"
    case unsupportedKey = "UNSUPPORTED_KEY"
    case invalidBaseUrl = "INVALID_BASE_URL"
    case invalidModel = "INVALID_MODEL"
    case secureStorageUnavailable = "SECURE_STORAGE_UNAVAILABLE"
    case encryptionFailed = "ENCRYPTION_FAILED"
}
