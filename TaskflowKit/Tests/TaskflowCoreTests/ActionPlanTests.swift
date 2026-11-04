// AI action-plan validation: untrusted input in, structured results out - a port of
// tests/unit/actionPlan.test.js. Covers every action type, dates/times/reminders/recurrence,
// category reuse, subtasks, bulk filters resolved against real data, day plans, and references the
// provider was never shown.
import Foundation
import Testing
@testable import TaskflowCore

let planNow = local(2026, 10, 25, 12, 0) // Sunday 25 Oct 2026, 12:00 local
let planTasks = [
    makeTask(id: "t-report", title: "Подготовить отчёт", status: .todo, dueDate: "2026-10-25", estimateMinutes: 60),
    makeTask(id: "t-bank", title: "Call the bank", status: .inProgress, estimateMinutes: 30),
    makeTask(id: "t-done", title: "Купить ёлку", status: .done, categoryId: "cat-study", completedAt: "2026-08-01T10:00:00.000Z"),
    makeTask(id: "t-exam", title: "Экзамен", dueDate: "2026-10-30", dueTime: "16:30", reminders: [30], categoryId: "cat-study", subtasks: [sub("s1", "Повторить ВВП"), sub("s2", "Инфляция", true)]),
    makeTask(id: "t-late", title: "Сдать эссе", dueDate: "2026-10-20", categoryId: "cat-study"),
    makeTask(id: "t-rent", title: "Оплатить аренду", dueDate: "2026-11-01", recurrence: Recurrence(freq: .monthly, interval: 1, monthDay: 1)),
]
let planCategories = [makeCategory(id: "cat-work", name: "Работа"), makeCategory(id: "cat-study", name: "Учёба")]
let planContext = ValidationContext(tasks: planTasks, categories: planCategories, now: planNow, timeZone: berlin)

private func makeTask(id: String, title: String, status: TaskStatus = .todo, dueDate: String? = nil, dueTime: String? = nil, reminders: [Int] = [], recurrence: Recurrence? = nil, estimateMinutes: Int? = nil, labels: [String] = [], categoryId: String? = nil, subtasks: [Subtask] = [], completedAt: String? = nil) -> TaskItem {
    TaskflowCoreTests.makeTask(id: id, title: title, dueDate: dueDate, dueTime: dueTime, reminders: reminders, recurrence: recurrence, estimateMinutes: estimateMinutes, labels: labels, status: status, categoryId: categoryId, subtasks: subtasks, completedAt: completedAt)
}

func entry(_ action: String, _ context: ValidationContext = planContext) -> PlanEntry {
    ActionPlan.validate(json("{\"actions\":[\(action)]}"), context: context).actions[0]
}

func changes(_ entry: PlanEntry) -> [String: JSONValue]? {
    if case .update(_, let changes, _)? = entry.normalized { return changes }
    if case .bulk(_, _, let changes, _, _)? = entry.normalized { return changes }
    return nil
}

func createFields(_ entry: PlanEntry) -> [String: JSONValue]? {
    if case .create(let fields, _, _)? = entry.normalized { return fields }
    return nil
}

@Suite("Plan shape")
struct PlanShapeTests {
    @Test(arguments: [
        (#""do it""#, "invalidPlan"),
        (#"{"reply":"ok"}"#, "invalidActions"),
        (#"{"actions":[],"execute":"rm -rf"}"#, "unknownField"),
        ("{\"actions\":[\(Array(repeating: #"{"type":"none"}"#, count: 51).joined(separator: ","))]}", "tooManyActions"),
    ])
    func rejectsPlans(plan: String, code: String) {
        #expect(ActionPlan.validate(json(plan), context: planContext).errors.contains(code))
    }

    @Test(arguments: [
        (#"{"type":"runCode"}"#, "unknownType"),
        (#"{"type":"deleteCategory","categoryId":"cat-work"}"#, "unknownType"),
        (#"{"type":"delete","taskId":"t-bank","sql":"DROP"}"#, "unknownField"),
    ])
    func rejectsActions(action: String, code: String) {
        #expect(entry(action).errors.contains(code))
    }
}

@Suite("Create")
struct CreateTests {
    @Test func fullTask() {
        let result = entry(#"""
        {"type":"create","title":"  Подготовка к экзамену по экономике ","description":"Повторить ключевые понятия и проверить знания.",
         "dueDate":"2026-11-02","dueTime":"09:30","priority":"high","reminders":[60,1440],"recurrence":{"freq":"weekly"},
         "estimateMinutes":120,"categoryId":"cat-study","subtasks":["Повторить ВВП"," изучить инфляцию ","Решить тесты"]}
        """#)
        #expect(result.valid)
        guard case .create(let fields, let subtasks, let newCategory)? = result.normalized else {
            Issue.record("not a create")
            return
        }
        #expect(fields == json(#"""
        {"title":"Подготовка к экзамену по экономике","description":"Повторить ключевые понятия и проверить знания.","priority":"high",
         "status":"todo","dueDate":"2026-11-02","dueTime":"09:30","reminders":[60,1440],"recurrence":{"freq":"weekly","interval":1,"weekdays":[1]},
         "estimateMinutes":120,"categoryId":"cat-study","labels":[]}
        """#).objectValue!)
        #expect(subtasks == ["Повторить ВВП", "изучить инфляцию", "Решить тесты"])
        #expect(newCategory == nil)
    }

    @Test func defaults() {
        let fields = createFields(entry(#"{"type":"create","title":"Только название"}"#))!
        #expect(fields["title"] == "Только название")
        #expect(fields["description"] == "")
        #expect(fields["priority"] == "medium")
        #expect(fields["status"] == "todo")
        for key in ["dueDate", "dueTime", "recurrence", "estimateMinutes", "categoryId"] { #expect(fields[key] == .null) }
        #expect(fields["reminders"] == .array([]))
    }

    @Test(arguments: [
        (#"{"type":"create"}"#, "titleRequired"),
        ("{\"type\":\"create\",\"title\":\"\(String(repeating: "x", count: 121))\"}", "titleTooLong"),
        (#"{"type":"create","title":"A","priority":"urgent"}"#, "invalidPriority"),
        (#"{"type":"create","title":"A","status":"Готово"}"#, "invalidStatus"),
        (#"{"type":"create","title":"A","dueDate":"2026-02-30"}"#, "invalidDate"),
        (#"{"type":"create","title":"A","dueTime":"16:30"}"#, "timeWithoutDate"),
        (#"{"type":"create","title":"A","dueDate":"2026-11-01","dueTime":"25:00"}"#, "invalidTime"),
        (#"{"type":"create","title":"A","dueDate":"2026-11-01","reminders":[30]}"#, "invalidReminders"),
        (#"{"type":"create","title":"A","reminders":[1440]}"#, "remindersWithoutDate"),
        (#"{"type":"create","title":"A","recurrence":{"freq":"daily"}}"#, "recurrenceWithoutDate"),
        (#"{"type":"create","title":"A","dueDate":"2026-11-01","recurrence":{"freq":"hourly"}}"#, "invalidRecurrence"),
        (#"{"type":"create","title":"A","estimateMinutes":0}"#, "invalidEstimate"),
        (#"{"type":"create","title":"A","categoryId":"cat-missing"}"#, "unknownCategory"),
        (#"{"type":"create","title":"A","subtasks":["ok","  "]}"#, "invalidSubtasks"),
        (#"{"type":"create","title":"A","subtasks":[{"title":"x","subtasks":[]}]}"#, "invalidSubtasks"),
    ])
    func rejects(action: String, code: String) {
        let result = entry(action)
        #expect(!result.valid)
        #expect(result.errors.contains(code))
        #expect(result.normalized == nil)
    }

    @Test func duplicates() {
        let result = ActionPlan.validate(json(#"{"actions":[{"type":"create","title":"подготовить ОТЧЕТ"},{"type":"create","title":"Новая"},{"type":"create","title":"новая"}]}"#), context: planContext)
        #expect(result.actions[0].warnings.contains("possibleDuplicate"))
        #expect(result.actions[2].warnings.contains("duplicateInPlan"))
    }

    @Test(arguments: [("учеба", "cat-study"), ("Учёбе", "cat-study"), ("Study", "cat-study"), ("work", "cat-work")])
    func reusesCategory(name: String, id: String) {
        let result = entry("{\"type\":\"create\",\"title\":\"A\",\"newCategory\":\"\(name)\"}")
        #expect(createFields(result)?["categoryId"] == .string(id))
        #expect(result.newCategory == nil)
    }

    @Test func genuinelyNewCategory() {
        let result = entry(#"{"type":"create","title":"A","newCategory":"  Путешествия "}"#)
        guard case .create(let fields, _, let newCategory)? = result.normalized else {
            Issue.record("not a create")
            return
        }
        #expect(newCategory == "Путешествия")
        #expect(fields["categoryId"] == .null)
    }
}

@Suite("Update and delete")
struct UpdateTests {
    @Test func onlyGivenFields() {
        let result = entry(#"{"type":"update","taskId":"t-exam","changes":{"dueDate":"2026-10-30","dueTime":"18:00","priority":"high","title":"Экзамен по экономике"}}"#)
        #expect(result.valid)
        #expect(changes(result) == ["dueDate": "2026-10-30", "dueTime": "18:00", "priority": "high", "title": "Экзамен по экономике"])
        #expect(result.target?.id == "t-exam")
    }

    @Test func removeTimeKeepDate() {
        #expect(changes(entry(#"{"type":"update","taskId":"t-exam","changes":{"dueTime":null}}"#)) == ["dueTime": .null, "reminders": .array([])])
    }

    @Test func clearDateClearsDependents() {
        #expect(changes(entry(#"{"type":"update","taskId":"t-rent","changes":{"dueDate":null}}"#)) == ["dueDate": .null, "dueTime": .null, "reminders": .array([]), "recurrence": .null])
    }

    @Test func timeWithoutDate() {
        #expect(entry(#"{"type":"update","taskId":"t-bank","changes":{"dueTime":"10:00"}}"#).errors.contains("timeWithoutDate"))
    }

    @Test func noChangeAndConflicts() {
        #expect(entry(#"{"type":"update","taskId":"t-report","changes":{"status":"todo"}}"#).warnings.contains("noChange"))
        let result = ActionPlan.validate(json(#"{"actions":[{"type":"update","taskId":"t-report","changes":{"status":"done"}},{"type":"delete","taskId":"t-report"}]}"#), context: planContext)
        #expect(result.actions[1].warnings.contains("conflictsWithEarlier"))
    }

    @Test func advancesRecurrence() {
        #expect(entry(#"{"type":"update","taskId":"t-rent","changes":{"status":"done"}}"#).warnings.contains("advancesRecurrence"))
    }

    @Test func legacyActions() {
        let status = entry(#"{"type":"setStatus","taskId":"t-report","status":"done"}"#)
        #expect(status.type == "update" && status.valid && changes(status) == ["status": "done"])
        let due = entry(#"{"type":"setDueDate","taskId":"t-report","dueDate":null}"#)
        #expect(due.type == "update" && due.valid)
    }

    @Test(arguments: [
        (#"{"type":"update","taskId":"t-report","changes":{}}"#, "invalidChanges"),
        (#"{"type":"update","taskId":"t-report","changes":{"id":"x"}}"#, "unknownField"),
        (#"{"type":"update","taskId":"t-ghost","changes":{"status":"done"}}"#, "unknownTask"),
    ])
    func rejects(action: String, code: String) {
        #expect(entry(action).errors.contains(code))
    }

    @Test func deleteWarnings() {
        #expect(entry(#"{"type":"delete","taskId":"t-exam"}"#).warnings.contains("deletesSubtasks"))
        #expect(entry(#"{"type":"delete","taskId":"t-rent"}"#).warnings.contains("deletesSeries"))
    }
}

@Suite("Subtasks")
struct SubtaskActionTests {
    @Test func allOperations() {
        #expect(entry(#"{"type":"addSubtask","taskId":"t-exam","title":"Решить тесты"}"#).valid)
        let update = entry(#"{"type":"updateSubtask","taskId":"t-exam","subtaskId":"s1","done":true}"#)
        #expect(update.normalized == .updateSubtask(taskId: "t-exam", subtaskId: "s1", title: nil, done: true))
        #expect(entry(#"{"type":"deleteSubtask","taskId":"t-exam","subtaskId":"s2"}"#).valid)
        #expect(entry(#"{"type":"moveSubtask","taskId":"t-exam","subtaskId":"s1","toTaskId":"t-report"}"#).valid)
    }

    @Test(arguments: [
        (#"{"type":"updateSubtask","taskId":"t-report","subtaskId":"s1","done":true}"#, "unknownSubtask"),
        (#"{"type":"moveSubtask","taskId":"t-exam","subtaskId":"s1","toTaskId":"t-exam"}"#, "sameTask"),
        (#"{"type":"moveSubtask","taskId":"t-exam","subtaskId":"s1","toTaskId":"t-ghost"}"#, "unknownTask"),
        (#"{"type":"updateSubtask","taskId":"t-exam","subtaskId":"s1"}"#, "invalidChanges"),
        (#"{"type":"addSubtask","taskId":"t-exam","title":" "}"#, "invalidSubtasks"),
    ])
    func rejects(action: String, code: String) {
        #expect(entry(action).errors.contains(code))
    }

    @Test func doneAgainIsNoChange() {
        #expect(entry(#"{"type":"updateSubtask","taskId":"t-exam","subtaskId":"s2","done":true}"#).warnings.contains("noChange"))
    }
}

@Suite("Bulk changes (resolved by the app)")
struct BulkTests {
    @Test func overdueToTomorrow() {
        let result = entry(#"{"type":"bulk","operation":"update","filter":{"due":"overdue"},"changes":{"dueDate":"2026-10-26"}}"#)
        #expect(result.valid)
        #expect(result.matches == ["t-late"])
        #expect(changes(result) == ["dueDate": "2026-10-26"])
    }

    @Test func byCategory() {
        #expect(entry(#"{"type":"bulk","operation":"update","filter":{"categoryId":"cat-study"},"changes":{"status":"done"}}"#).matches == ["t-done", "t-exam", "t-late"])
        #expect(entry(#"{"type":"bulk","operation":"update","filter":{"categoryId":"cat-study","status":"todo"},"changes":{"status":"done"}}"#).matches == ["t-exam", "t-late"])
    }

    @Test func completedOlderThan() {
        #expect(entry(#"{"type":"bulk","operation":"delete","filter":{"status":"done","completedOlderThanDays":30}}"#).matches == ["t-done"])
    }

    @Test func needsCriterion() {
        #expect(entry(#"{"type":"bulk","operation":"delete","filter":{}}"#).errors.contains("emptyFilter"))
    }

    @Test func explicitScopeAll() {
        let result = entry(#"{"type":"bulk","operation":"delete","filter":{"scope":"all"}}"#)
        #expect(result.valid)
        #expect(result.errors.isEmpty)
        #expect(result.matches == planTasks.map(\.id))
        if case .bulk(let operation, let filter, _, _, _)? = result.normalized {
            #expect(operation == "delete" && filter.scope == "all")
        } else {
            Issue.record("not a bulk")
        }
    }

    @Test func scopeWithCriteria() {
        #expect(entry(#"{"type":"bulk","operation":"delete","filter":{"scope":"all","status":"done"}}"#).matches == ["t-done"])
        #expect(entry(#"{"type":"bulk","operation":"delete","filter":{"scope":"everything"}}"#).errors.contains("invalidFilter"))
    }

    @Test func noMatches() {
        #expect(entry(#"{"type":"bulk","operation":"delete","filter":{"titleContains":"нет такого"}}"#).warnings.contains("noMatches"))
    }

    @Test(arguments: [
        (#"{"type":"bulk","operation":"archive","filter":{"status":"done"}}"#, "invalidOperation"),
        (#"{"type":"bulk","operation":"delete","filter":{"due":"someday"}}"#, "invalidFilter"),
        (#"{"type":"bulk","operation":"update","filter":{"status":"todo"},"changes":{"title":"Same"}}"#, "unknownField"),
        (#"{"type":"bulk","operation":"delete","filter":{"categoryId":"cat-x"}}"#, "unknownCategory"),
    ])
    func rejects(action: String, code: String) {
        #expect(entry(action).errors.contains(code))
    }

    @Test func passedDueTimeIsOverdue() {
        let list = [TaskflowCoreTests.makeTask(id: "a", dueDate: "2026-10-25", dueTime: "09:00"), TaskflowCoreTests.makeTask(id: "b", dueDate: "2026-10-25", dueTime: "18:00")]
        #expect(ActionPlan.resolveBulkFilter(BulkFilter(due: "overdue"), tasks: list, now: planNow, timeZone: berlin).map(\.id) == ["a"])
    }
}

@Suite("Tags")
struct TagTests {
    let ctx = ValidationContext(tasks: [
        TaskflowCoreTests.makeTask(id: "a", title: "A", labels: ["срочно"], categoryId: "cat-study"),
        TaskflowCoreTests.makeTask(id: "b", title: "B", categoryId: "cat-study"),
        TaskflowCoreTests.makeTask(id: "c", title: "C", labels: ["учёба"], categoryId: "cat-work"),
        TaskflowCoreTests.makeTask(id: "full", title: "Full", labels: (1...10).map(String.init), categoryId: "cat-work"),
    ], categories: planCategories, now: planNow, timeZone: berlin)

    let managed = ValidationContext(tasks: [
        TaskflowCoreTests.makeTask(id: "a", title: "A", labels: ["Срочно", "учёба"], categoryId: "cat-study"),
        TaskflowCoreTests.makeTask(id: "b", title: "B", labels: ["учёба"], categoryId: "cat-study"),
        TaskflowCoreTests.makeTask(id: "c", title: "C", labels: ["срочно"], status: .done, categoryId: "cat-work"),
        TaskflowCoreTests.makeTask(id: "d", title: "D", categoryId: "cat-work"),
    ], categories: planCategories, now: planNow, timeZone: berlin)

    @Test func createTags() {
        #expect(createFields(entry(#"{"type":"create","title":"X","labels":[" учёба ","Учёба","экзамен"]}"#, ctx))?["labels"] == .from(["учёба", "экзамен"]))
    }

    @Test func bulkAddByCategory() {
        let result = entry(#"{"type":"bulk","operation":"update","filter":{"categoryId":"cat-study"},"changes":{"addLabels":["учёба"]}}"#, ctx)
        #expect(result.valid)
        #expect(result.matches == ["a", "b"])
        #expect(changes(result) == ["addLabels": .from(["учёба"])])
    }

    @Test func addExistingAndLimit() {
        #expect(entry(#"{"type":"update","taskId":"c","changes":{"addLabels":["Учёба"]}}"#, ctx).warnings.contains("noChange"))
        #expect(!entry(#"{"type":"update","taskId":"a","changes":{"addLabels":["учёба"]}}"#, ctx).warnings.contains("noChange"))
        #expect(entry(#"{"type":"update","taskId":"full","changes":{"addLabels":["11"]}}"#, ctx).warnings.contains("labelLimit"))
        #expect(entry(#"{"type":"bulk","operation":"update","filter":{"categoryId":"cat-work"},"changes":{"addLabels":["работа"]}}"#, ctx).warnings.contains("labelLimit"))
    }

    @Test(arguments: [#""учёба""#, #"["  "]"#, "[\"\(String(repeating: "x", count: 31))\"]", "[5]"])
    func rejectsLabels(value: String) {
        #expect(entry("{\"type\":\"update\",\"taskId\":\"a\",\"changes\":{\"addLabels\":\(value)}}", ctx).errors.contains("invalidLabels"))
    }

    @Test func deleteAndRename() {
        let deleted = entry(#"{"type":"deleteLabel","label":"срочно"}"#, managed)
        #expect(deleted.valid)
        #expect(deleted.normalized == .deleteLabel(label: "срочно", matches: ["a", "c"]))
        let renamed = entry(#"{"type":"renameLabel","label":"учёба","newLabel":"Study"}"#, managed)
        #expect(renamed.normalized == .renameLabel(label: "учёба", newLabel: "Study", matches: ["a", "b"]))
        #expect(entry(#"{"type":"renameLabel","label":"учёба","newLabel":"учёба"}"#, managed).warnings.contains("noChange"))
    }

    @Test(arguments: [
        (#"{"type":"deleteLabel","label":"нет такой"}"#, "unknownLabel"),
        (#"{"type":"deleteLabel","label":" "}"#, "invalidLabels"),
        (#"{"type":"renameLabel","label":"учёба","newLabel":""}"#, "invalidLabels"),
        ("{\"type\":\"renameLabel\",\"label\":\"учёба\",\"newLabel\":\"\(String(repeating: "x", count: 31))\"}", "invalidLabels"),
        (#"{"type":"deleteLabel","label":"учёба","taskId":"a"}"#, "unknownField"),
    ])
    func rejectsManagement(action: String, code: String) {
        #expect(entry(action, managed).errors.contains(code))
    }

    @Test func removeLabels() {
        let result = entry(#"{"type":"update","taskId":"a","changes":{"removeLabels":["срочно"]}}"#, managed)
        #expect(result.valid && !result.warnings.contains("noChange"))
        #expect(entry(#"{"type":"update","taskId":"d","changes":{"removeLabels":["срочно"]}}"#, managed).warnings.contains("noChange"))
        #expect(entry(#"{"type":"bulk","operation":"update","filter":{"categoryId":"cat-work"},"changes":{"removeLabels":["срочно"]}}"#, managed).matches == ["c"])
        #expect(entry(#"{"type":"bulk","operation":"update","filter":{"categoryId":"cat-work"},"changes":{"removeLabels":["нет такой"]}}"#, managed).warnings.contains("noMatches"))
        #expect(entry(#"{"type":"update","taskId":"a","changes":{"addLabels":["x"],"removeLabels":["X"]}}"#, managed).errors.contains("labelConflict"))
    }
}

@Suite("Day plans and references")
struct DayPlanTests {
    func plan(_ items: String, availability: Availability? = Availability(start: "09:00", end: "18:00")) -> PlanEntry {
        var context = planContext
        context.availability = availability
        return entry("{\"type\":\"schedule\",\"date\":\"2026-10-26\",\"items\":\(items)}", context)
    }

    @Test func validPlan() {
        let result = plan(#"[{"taskId":"t-report","start":"09:00"},{"taskId":"t-bank","start":"10:00"}]"#)
        #expect(result.valid)
        if case .schedule(_, let items)? = result.normalized {
            #expect(items.map { "\($0.taskId) \($0.start) \($0.endMin ?? -1)" } == ["t-report 09:00 600", "t-bank 10:00 630"])
        } else {
            Issue.record("not a schedule")
        }
    }

    @Test func rejects() {
        #expect(plan(#"[{"taskId":"t-report","start":"09:00"}]"#, availability: nil).errors.contains("noAvailability"))
        #expect(plan(#"[{"taskId":"t-report","start":"17:30"}]"#).errors.contains("outsideAvailability"))
        #expect(plan(#"[{"taskId":"t-report","start":"09:00"},{"taskId":"t-bank","start":"09:30"}]"#).errors.contains("overlap"))
        #expect(plan(#"[{"taskId":"t-done","start":"09:00"}]"#).errors.contains("taskDone"))
        #expect(plan(#"[{"taskId":"t-report","start":"9am"}]"#).errors.contains("invalidSchedule"))
    }

    @Test func noEstimateFlagged() {
        #expect(plan(#"[{"taskId":"t-exam","start":"09:00"}]"#).warnings.contains("noEstimate"))
    }

    @Test func pastDate() {
        var context = planContext
        context.availability = Availability(start: "09:00", end: "18:00")
        #expect(entry(#"{"type":"schedule","date":"2026-10-24","items":[{"taskId":"t-report","start":"09:00"}]}"#, context).errors.contains("dateInPast"))
    }

    @Test func onlySharedTasks() {
        var context = planContext
        context.allowedTaskIds = ["t-report"]
        #expect(entry(#"{"type":"update","taskId":"t-bank","changes":{"status":"done"}}"#, context).errors.contains("notOffered"))
        #expect(entry(#"{"type":"delete","taskId":"t-bank"}"#, context).errors.contains("notOffered"))
        #expect(entry(#"{"type":"update","taskId":"t-report","changes":{"status":"done"}}"#, context).valid)
    }

    @Test func uncheckableReferences() {
        #expect(entry(#"{"type":"delete","taskId":"t-report"}"#, ValidationContext()).errors.contains("notVerified"))
        #expect(entry(#"{"type":"create","title":"A","categoryId":"cat-work"}"#, ValidationContext(tasks: planTasks)).errors.contains("notVerified"))
        #expect(entry(#"{"type":"bulk","operation":"delete","filter":{"status":"done"}}"#, ValidationContext()).errors.contains("notVerified"))
    }
}
