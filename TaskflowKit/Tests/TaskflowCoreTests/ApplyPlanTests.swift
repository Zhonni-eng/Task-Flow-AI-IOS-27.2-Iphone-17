// Applying confirmed assistant plans and undoing them exactly - a port of
// tests/unit/applyPlan.test.js, plus the review/apply rules of useAssistant (proposal selection,
// re-validation before applying).
import Foundation
import Testing
@testable import TaskflowCore

private let now = local(2026, 10, 25, 12, 0)
private let categories = [makeCategory(id: "cat-study", name: "Учёба")]
private func base() -> [TaskItem] {
    [
        makeTask(id: "exam", title: "Экзамен", dueDate: "2026-10-30", order: 0, subtasks: [sub("s1", "Повторить ВВП"), sub("s2", "Инфляция", true)]),
        makeTask(id: "late", title: "Сдать эссе", dueDate: "2026-10-20", order: 1),
        makeTask(id: "rent", title: "Аренда", dueDate: "2026-11-01", recurrence: Recurrence(freq: .monthly, interval: 1, monthDay: 1), order: 2),
        makeTask(id: "old", title: "Старое", status: .done, completedAt: "2026-08-01T00:00:00.000Z"),
    ]
}

private func run(_ actions: String, _ tasks: [TaskItem] = base(), availability: Availability? = nil) -> (outcome: ApplyOutcome, tasks: [TaskItem]) {
    let validation = ActionPlan.validate(json("{\"actions\":\(actions)}"), context: ValidationContext(tasks: tasks, categories: categories, availability: availability, now: now, timeZone: berlin))
    #expect(validation.ok)
    return (ApplyPlan.apply(tasks: tasks, categories: categories, entries: validation.actions, now: now, timeZone: berlin), tasks)
}

/// The board after an applied outcome (through the real reducer).
private func board(_ tasks: [TaskItem], _ outcome: ApplyOutcome) -> [TaskItem] {
    tasksReducer(tasks, .replace(tasks: outcome.tasks, removeIds: outcome.removeIds))
}

private func undone(_ outcome: ApplyOutcome, _ after: [TaskItem]) -> [TaskItem] {
    let result = ApplyPlan.undo(outcome.undo, currentTasks: after)
    return tasksReducer(after, .replace(tasks: result.tasks, removeIds: result.removeIds))
}

@Suite("Applying plans")
struct ApplyingTests {
    @Test func economicsExam() {
        let (outcome, _) = run(#"[{"type":"create","title":"Подготовиться к экзамену по экономике","description":"Подготовиться к экзамену: повторить ключевые понятия и проверить знания.","subtasks":["Повторить ВВП","Изучить инфляцию","Решить практические тесты"],"newCategory":"учеба"}]"#)
        let task = outcome.tasks[0]
        #expect(task.title == "Подготовиться к экзамену по экономике")
        #expect(task.description.hasPrefix("Подготовиться к экзамену"))
        #expect(task.subtasks.map(\.title) == ["Повторить ВВП", "Изучить инфляцию", "Решить практические тесты"])
        #expect(task.subtasks.allSatisfy { !$0.done })
        // "учеба" matched the existing "Учёба": no duplicate category.
        #expect(task.categoryId == "cat-study")
        #expect(outcome.categories.isEmpty)
        #expect(outcome.created == 1 && outcome.updated == 0 && outcome.deleted == 0)
    }

    @Test func newCategoryOnce() {
        let (outcome, _) = run(#"[{"type":"create","title":"A","newCategory":"Путешествия"},{"type":"create","title":"B","newCategory":"путешествия"}]"#)
        #expect(outcome.categories.map(\.name) == ["Путешествия"])
        #expect(Set(outcome.tasks.map(\.categoryId)) == [outcome.categories[0].id])
    }

    @Test func moveExamThenRemoveTime() {
        let first = run(#"[{"type":"update","taskId":"exam","changes":{"dueDate":"2026-10-30","dueTime":"16:30"}}]"#)
        let moved = board(first.tasks, first.outcome)
        let exam = moved.first { $0.id == "exam" }!
        #expect(exam.dueDate == "2026-10-30" && exam.dueTime == "16:30")
        let second = run(#"[{"type":"update","taskId":"exam","changes":{"dueTime":null}}]"#, moved)
        let after = board(moved, second.outcome).first { $0.id == "exam" }!
        #expect(after.dueDate == "2026-10-30" && after.dueTime == nil)
    }

    @Test func repeatingTaskMovesOn() {
        let task = run(#"[{"type":"update","taskId":"rent","changes":{"status":"done"}}]"#).outcome.tasks[0]
        #expect(task.status == .todo && task.dueDate == "2026-12-01" && task.completedAt == ISOTime.string(now))
    }

    @Test func overdueToTomorrow() {
        #expect(run(#"[{"type":"bulk","operation":"update","filter":{"due":"overdue"},"changes":{"dueDate":"2026-10-26"}}]"#).outcome.tasks.map { "\($0.id) \($0.dueDate ?? "")" } == ["late 2026-10-26"])
    }

    @Test func deleteOldCompleted() {
        let (outcome, tasks) = run(#"[{"type":"bulk","operation":"delete","filter":{"status":"done","completedOlderThanDays":30}}]"#)
        #expect(outcome.removeIds == ["old"])
        #expect(board(tasks, outcome).map(\.id).sorted() == ["exam", "late", "rent"])
    }

    @Test func deleteParentDeletesSubtasks() {
        let (outcome, tasks) = run(#"[{"type":"delete","taskId":"exam"}]"#)
        let after = board(tasks, outcome)
        #expect(!after.contains { $0.id == "exam" })
        #expect(!after.flatMap(\.subtasks).contains { $0.id == "s1" })
    }

    @Test func subtaskOperations() {
        let outcome = run(#"[{"type":"updateSubtask","taskId":"exam","subtaskId":"s1","done":true,"title":"Повторить ВВП и ВНП"},{"type":"addSubtask","taskId":"late","title":"Вычитать текст"}]"#).outcome
        #expect(outcome.tasks.first { $0.id == "exam" }!.subtasks[0] == sub("s1", "Повторить ВВП и ВНП", true))
        #expect(outcome.tasks.first { $0.id == "late" }!.subtasks.map(\.title) == ["Вычитать текст"])
        let moved = run(#"[{"type":"moveSubtask","taskId":"exam","subtaskId":"s2","toTaskId":"late"}]"#).outcome
        #expect(moved.tasks.first { $0.id == "exam" }!.subtasks.map(\.id) == ["s1"])
        #expect(moved.tasks.first { $0.id == "late" }!.subtasks == [sub("s2", "Инфляция", true)])
    }

    @Test func dayPlanSetsPlannedNotDeadline() {
        let tasks = base().map { task -> TaskItem in
            var copy = task
            if copy.id == "late" { copy.estimateMinutes = 60 }
            return copy
        }
        let task = run(#"[{"type":"schedule","date":"2026-10-26","items":[{"taskId":"late","start":"10:00"}]}]"#, tasks, availability: Availability(start: "09:00", end: "18:00")).outcome.tasks[0]
        #expect(task.planned == Planned(date: "2026-10-26", time: "10:00"))
        #expect(task.dueDate == "2026-10-20")
    }
}

@Suite("Tags, all tasks and undo")
struct ApplyTagUndoTests {
    @Test func addTagsKeepsExistingAndUndoRestores() {
        let tasks = [
            makeTask(id: "a", title: "A", labels: ["срочно", "Учёба"], categoryId: "cat-study"),
            makeTask(id: "b", title: "B", categoryId: "cat-study"),
            makeTask(id: "c", title: "C", labels: ["дом"]),
        ]
        let (outcome, _) = run(#"[{"type":"bulk","operation":"update","filter":{"categoryId":"cat-study"},"changes":{"addLabels":["учёба","вуз"]}}]"#, tasks)
        let after = board(tasks, outcome)
        #expect(after.map(\.labels) == [["срочно", "Учёба", "вуз"], ["учёба", "вуз"], ["дом"]])
        #expect(undone(outcome, after).map(\.labels) == [["срочно", "Учёба"], [], ["дом"]])
    }

    @Test func deleteAllAndUndo() {
        let (outcome, tasks) = run(#"[{"type":"bulk","operation":"delete","filter":{"scope":"all"}}]"#)
        #expect(outcome.deleted == tasks.count)
        let after = board(tasks, outcome)
        #expect(after.isEmpty)
        #expect(undone(outcome, after).map(\.id).sorted() == tasks.map(\.id).sorted())
    }

    func tagged() -> [TaskItem] {
        [
            makeTask(id: "a", title: "A", labels: ["Срочно", "учёба"], categoryId: "cat-study"),
            makeTask(id: "b", title: "B", labels: ["учёба", "Study"], categoryId: "cat-study"),
            makeTask(id: "c", title: "C", labels: ["срочно"], status: .done, completedAt: "2026-10-01T00:00:00.000Z"),
        ]
    }

    @Test func deleteTagEverywhere() {
        let (outcome, tasks) = run(#"[{"type":"deleteLabel","label":"срочно"}]"#, tagged())
        let after = board(tasks, outcome)
        #expect(after.map(\.labels) == [["учёба"], ["учёба", "Study"], []])
        #expect(outcome.created == 0 && outcome.updated == 2 && outcome.deleted == 0)
        #expect(undone(outcome, after).map(\.labels) == tasks.map(\.labels))
    }

    @Test func renameTagMerges() {
        let (outcome, tasks) = run(#"[{"type":"renameLabel","label":"учёба","newLabel":"study"}]"#, tagged())
        let after = board(tasks, outcome)
        #expect(after.map(\.labels) == [["Срочно", "study"], ["study"], ["срочно"]])
        #expect(undone(outcome, after).map(\.labels) == tasks.map(\.labels))
    }

    @Test func addAndRemoveInOneChange() {
        let (outcome, tasks) = run(#"[{"type":"bulk","operation":"update","filter":{"categoryId":"cat-study"},"changes":{"addLabels":["вуз"],"removeLabels":["учёба"]}}]"#, tagged())
        #expect(board(tasks, outcome).map(\.labels) == [["Срочно", "вуз"], ["Study", "вуз"], ["срочно"]])
    }

    @Test func undoRevertsExactly() {
        let (outcome, tasks) = run(#"[{"type":"create","title":"Новая"},{"type":"update","taskId":"late","changes":{"priority":"high"}},{"type":"delete","taskId":"exam"}]"#)
        let after = board(tasks, outcome)
        let result = ApplyPlan.undo(outcome.undo, currentTasks: after)
        #expect(result.removed == 1 && result.restored == 2 && result.kept == 0)
        let restored = tasksReducer(after, .replace(tasks: result.tasks, removeIds: result.removeIds))
        #expect(restored.map { "\($0.id) \($0.priority) \($0.subtasks.count)" }.sorted() == tasks.map { "\($0.id) \($0.priority) \($0.subtasks.count)" }.sorted())
    }

    @Test func undoKeepsUserEdits() {
        let (outcome, tasks) = run(#"[{"type":"update","taskId":"late","changes":{"priority":"high"}}]"#)
        let edited = board(tasks, outcome).map { task -> TaskItem in
            var copy = task
            if copy.id == "late" { copy.title = "Сдать эссе (правка)" }
            return copy
        }
        let result = ApplyPlan.undo(outcome.undo, currentTasks: edited)
        #expect(result.restored == 0 && result.kept == 1 && result.tasks.isEmpty)
    }
}

@Suite("Review and confirmation")
struct ProposalTests {
    func context(_ tasks: [TaskItem] = base(), allowed: [String]? = nil) -> ValidationContext {
        ValidationContext(tasks: tasks, categories: categories, allowedTaskIds: allowed, now: now, timeZone: berlin)
    }

    func proposal(_ actions: String, _ context: ValidationContext) -> Proposal {
        let plan = json("{\"reply\":\"\",\"question\":\"\",\"actions\":\(actions)}")
        return AssistantEngine.buildProposal(plan: plan, validation: ActionPlan.validate(plan, context: context))!
    }

    @Test func blockingItemsAreNotPreselected() {
        let items = proposal(#"[{"type":"create","title":"Экзамен"},{"type":"update","taskId":"late","changes":{"priority":"high"}},{"type":"delete","taskId":"late"},{"type":"update","taskId":"ghost","changes":{"status":"done"}}]"#, context()).items
        #expect(items[0].selectable && !items[0].selected) // possible duplicate
        #expect(items[1].conflict && !items[1].selected) // two actions on one task
        #expect(items[2].conflict && !items[2].selected)
        #expect(!items[3].selectable) // invalid
    }

    @Test func noMatchesCannotBeSelected() {
        let item = proposal(#"[{"type":"bulk","operation":"delete","filter":{"titleContains":"нет"}}]"#, context()).items[0]
        #expect(!item.selectable && !item.selected)
    }

    @Test func applyRechecksAgainstCurrentData() {
        let original = proposal(#"[{"type":"bulk","operation":"update","filter":{"due":"overdue"},"changes":{"priority":"high"}}]"#, context())
        #expect(original.items[0].selected)
        // Another task became overdue while the user was reviewing: the bulk change no longer matches.
        var changed = base()
        changed[0].dueDate = "2026-10-21"
        guard case .changed = AssistantEngine.prepareApply(original, context: context(changed)) else {
            Issue.record("expected 'changed'")
            return
        }
        guard case .apply(let outcome) = AssistantEngine.prepareApply(original, context: context()) else {
            Issue.record("expected apply")
            return
        }
        #expect(outcome.tasks.map(\.id) == ["late"])
    }

    @Test func conflictingSelectionIsRefused() {
        var conflicting = proposal(#"[{"type":"update","taskId":"late","changes":{"priority":"high"}},{"type":"delete","taskId":"late"}]"#, context())
        conflicting = AssistantEngine.toggle(conflicting, index: 0)
        conflicting = AssistantEngine.toggle(conflicting, index: 1)
        guard case .conflict = AssistantEngine.prepareApply(conflicting, context: context()) else {
            Issue.record("expected conflict")
            return
        }
    }

    @Test func deletedTaskMeansChanged() {
        let original = proposal(#"[{"type":"update","taskId":"late","changes":{"priority":"high"}}]"#, context())
        guard case .changed = AssistantEngine.prepareApply(original, context: context(base().filter { $0.id != "late" })) else {
            Issue.record("expected changed")
            return
        }
    }

    @Test func nothingSelected() {
        var item = proposal(#"[{"type":"update","taskId":"late","changes":{"priority":"high"}}]"#, context())
        item = AssistantEngine.toggle(item, index: 0)
        guard case .nothingSelected = AssistantEngine.prepareApply(item, context: context()) else {
            Issue.record("expected nothingSelected")
            return
        }
    }

    @Test func usageTotals() {
        let total = UsageTotal().adding(TokenUsage(inputTokens: 10, outputTokens: 5), cost: 0.5).adding(TokenUsage(inputTokens: 1, outputTokens: 1), cost: nil)
        #expect(total.requests == 2 && total.inputTokens == 11 && total.outputTokens == 6 && total.costUsd == nil)
    }
}
