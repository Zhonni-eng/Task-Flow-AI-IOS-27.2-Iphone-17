// Task model, subtasks, categories, reducer ordering, views, filters and statistics - ports of
// tests/unit/{taskModel,subtasks,categories,tasksReducer,taskView,dueDates}.test.js.
import Foundation
import Testing
@testable import TaskflowCore

@Suite("Task model")
struct TaskModelTests {
    @Test func normalizesFields() {
        let task = TaskModel.createTask(json(#"""
        {"title":"  Отчёт  ","description":"  x  ","priority":"urgent","status":"nope","dueDate":"2026-02-30",
         "dueTime":"10:00","labels":["  a  b ","A  B","c"],"categoryId":"","estimateMinutes":0}
        """#).objectValue!)
        #expect(task.title == "Отчёт")
        #expect(task.description == "x")
        #expect(task.priority == .medium)
        #expect(task.status == .todo)
        #expect(task.dueDate == nil)
        #expect(task.dueTime == nil)
        #expect(task.labels == ["a b", "c"])
        #expect(task.categoryId == nil)
        #expect(task.estimateMinutes == nil)
    }

    @Test func limits() {
        let task = TaskModel.createTask(["title": .string(String(repeating: "я", count: 200)), "labels": .from((1...15).map(String.init))])
        #expect(task.title.count == 120)
        #expect(task.labels.count == 10)
        #expect(TaskModel.validateTaskFields(title: "   ") == ["title": "titleRequired"])
    }

    @Test func updateOnlyEditableFieldsAndClearDependents() {
        let task = makeTask(id: "a", dueDate: "2026-10-30", dueTime: "16:30", reminders: [30], recurrence: Recurrence(freq: .daily))
        let updated = TaskModel.updateTask(task, ["dueDate": .null, "id": "evil", "order": 99])
        #expect(updated.id == "a")
        #expect(updated.order == 0)
        #expect(updated.dueDate == nil && updated.dueTime == nil && updated.reminders.isEmpty && updated.recurrence == nil)
    }

    @Test func subtasks() {
        let list = Subtasks.normalize(json(#"[{"id":"a","title":"  One  "},{"id":"a","title":"dup"},{"title":"no id"},{"id":"b","title":"  "},{"id":"c","title":"Two","done":true,"extra":1}]"#))
        #expect(list == [sub("a", "One"), sub("c", "Two", true)])
        #expect(Subtasks.validateTitle("  ") == "subtaskRequired")
        #expect(Subtasks.progress(makeTask(subtasks: list))! == (1, 2))
        #expect(Subtasks.progress(makeTask()) == nil)
    }
}

@Suite("Categories")
struct CategoryTests {
    @Test func names() {
        #expect(CategoryModel.normalizeName("  Учёба   и   работа ") == "Учёба и работа")
        let categories = [makeCategory(id: "a", name: "Работа")]
        #expect(CategoryModel.validateName(" ", categories: categories) == .required)
        #expect(CategoryModel.validateName(" работа ", categories: categories) == .duplicate)
        #expect(CategoryModel.validateName("Работа", categories: categories, excludeId: "a") == nil)
    }

    @Test func restoreSortsAndRenumbers() {
        let restored = CategoryModel.restore(json(#"[{"id":"b","name":"B","order":5},{"id":"a","name":"A","order":1},{"id":"x","name":"  "},{"name":"no id"}]"#).arrayValue!)
        #expect(restored.map(\.id) == ["a", "b"])
        #expect(restored.map(\.order) == [0, 1])
    }

    @Test func reducer() {
        var state = categoriesReducer([], .create(name: "A"))
        state = categoriesReducer(state, .create(name: "B"))
        let id = state[0].id
        state = categoriesReducer(state, .rename(id: id, name: "  A2 "))
        #expect(state[0].name == "A2")
        state = categoriesReducer(state, .remove(id: id))
        #expect(state.map(\.name) == ["B"])
        #expect(state[0].order == 0)
    }

    @Test(arguments: [("учеба", "cat-study"), ("Учёбе", "cat-study"), ("Study", "cat-study"), ("work", "cat-work")])
    func matching(name: String, id: String) {
        let categories = [makeCategory(id: "cat-work", name: "Работа"), makeCategory(id: "cat-study", name: "Учёба")]
        #expect(CategoryMatch.findMatching(name, in: categories)?.id == id)
    }

    @Test func noFalseMatch() {
        let categories = [makeCategory(id: "cat-work", name: "Работа")]
        #expect(CategoryMatch.findMatching("Путешествия", in: categories) == nil)
        #expect(CategoryMatch.findMatching("Раб", in: categories) == nil)
    }
}

@Suite("Reducer ordering and moves")
struct ReducerTests {
    @Test func compareOrder() {
        let a = makeTask(id: "a", order: 1)
        let b = makeTask(id: "b", order: 0)
        let c = makeTask(id: "c", order: 0, createdAt: "2026-09-01T00:00:00.000Z")
        #expect([a, b, c].sorted(by: Tasks.compare).map(\.id) == ["c", "b", "a"])
    }

    @Test func restoreRenumbers() {
        let tasks = Tasks.restore([makeTask(id: "a", order: 5).json, makeTask(id: "b", order: 9).json, makeTask(id: "c", status: .done, order: 3).json])
        #expect(tasks.map(\.order) == [0, 1, 0])
    }

    @Test func createAtTopAndMove() {
        var state: [TaskItem] = []
        for id in ["a", "b", "c"] { state = tasksReducer(state, .create(makeTask(id: id))) }
        #expect(Tasks.column(state, .todo).map(\.id) == ["c", "b", "a"])
        state = tasksReducer(state, .move(id: "c", status: .todo, index: 2))
        #expect(Tasks.column(state, .todo).map(\.id) == ["b", "a", "c"])
        state = tasksReducer(state, .move(id: "a", status: .inProgress, index: 99))
        #expect(Tasks.column(state, .todo).map(\.id) == ["b", "c"])
        #expect(Tasks.column(state, .todo).map(\.order) == [0, 1])
        #expect(Tasks.column(state, .inProgress).map(\.id) == ["a"])
        state = tasksReducer(state, .remove(id: "b"))
        #expect(Tasks.column(state, .todo).map(\.order) == [0])
    }

    @Test func dropInPlaceIsNoOp() {
        var state: [TaskItem] = []
        for id in ["a", "b"] { state = tasksReducer(state, .create(makeTask(id: id))) }
        #expect(tasksReducer(state, .move(id: "b", status: .todo, index: 0)) == state)
    }

    @Test func categoryReassignment() {
        let state = [makeTask(id: "a", categoryId: "x"), makeTask(id: "b", categoryId: "y")]
        let moved = tasksReducer(state, .reassignCategory(from: "x", to: nil))
        #expect(moved.map(\.categoryId) == [nil, "y"])
        #expect(tasksReducer(state, .reassignCategory(from: "z", to: "x")) == state)
    }

    @Test func bulkActions() {
        var state: [TaskItem] = []
        for id in ["a", "b", "c"] { state = tasksReducer(state, .create(makeTask(id: id, priority: .low))) }
        state = tasksReducer(state, .bulkMove(ids: ["a", "b"], status: .done))
        #expect(Tasks.column(state, .done).map(\.id).sorted() == ["a", "b"])
        #expect(state.first { $0.id == "a" }!.completedAt != nil)
        state = tasksReducer(state, .bulkUpdate(ids: ["a", "c"], changes: ["priority": "high", "title": "ignored"]))
        #expect(state.first { $0.id == "a" }!.priority == .high)
        #expect(state.first { $0.id == "a" }!.title != "ignored")
        state = tasksReducer(state, .bulkRemove(ids: ["a", "c"]))
        #expect(state.map(\.id) == ["b"])
        #expect(state[0].order == 0)
    }

    @Test func collectLabels() {
        #expect(Tasks.collectLabels([makeTask(labels: ["Work", "home"]), makeTask(labels: ["work", "x"])]) == ["Work", "home", "x"])
    }
}

@Suite("Views, filters and statistics")
struct ViewTests {
    let today = "2026-10-21"
    let tasks = [
        makeTask(id: "1", title: "Ёлка новогодняя", description: "", priority: .high, dueDate: "2026-10-20", labels: ["Дом"], status: .todo, order: 0),
        makeTask(id: "2", title: "Отчёт 10", description: "квартальный", priority: .low, dueDate: "2026-10-21", status: .inProgress, order: 0),
        makeTask(id: "3", title: "Отчёт 9", priority: .medium, dueDate: nil, labels: ["work"], status: .done, order: 0),
        makeTask(id: "4", title: "Звонок", priority: .high, dueDate: "2026-10-25", status: .todo, order: 1),
    ]
    let ru = Locale(identifier: "ru_RU")

    @Test func search() {
        #expect(TaskViews.normalizeQuery("  ЁЛКА   новая ") == "елка новая")
        #expect(TaskViews.list(tasks, ViewState(query: "елка"), locale: ru, todayKey: today).map(\.id) == ["1"])
        #expect(TaskViews.list(tasks, ViewState(query: "КВАРТАЛ"), locale: ru, todayKey: today).map(\.id) == ["2"])
        #expect(TaskViews.list(tasks, ViewState(query: "   "), locale: ru, todayKey: today).count == 4)
    }

    @Test func filters() {
        #expect(TaskViews.list(tasks, ViewState(statuses: [.done]), locale: ru, todayKey: today).map(\.id) == ["3"])
        #expect(TaskViews.list(tasks, ViewState(priorities: [.high]), locale: ru, todayKey: today).map(\.id) == ["1", "4"])
        #expect(TaskViews.list(tasks, ViewState(labels: ["WORK", "дом"]), locale: ru, todayKey: today).map(\.id) == ["1", "3"])
        #expect(TaskViews.list(tasks, ViewState(due: [.overdue]), locale: ru, todayKey: today).map(\.id) == ["1"])
        #expect(TaskViews.list(tasks, ViewState(due: [.today, .upcoming]), locale: ru, todayKey: today).map(\.id) == ["4", "2"])
        #expect(TaskViews.isFiltering(ViewState(due: [.today])))
        #expect(!TaskViews.isDragAllowed(ViewState(sort: .title)))
        #expect(TaskViews.isDragAllowed(.empty))
    }

    @Test func sorting() {
        #expect(TaskViews.list(tasks, ViewState(sort: .dueDate), locale: ru, todayKey: today).map(\.id) == ["1", "2", "4", "3"])
        #expect(TaskViews.list(tasks, ViewState(sort: .priority), locale: ru, todayKey: today).map(\.id) == ["1", "4", "3", "2"])
        // Numeric collation: "Отчёт 9" before "Отчёт 10".
        let titles = TaskViews.list(tasks, ViewState(sort: .title), locale: ru, todayKey: today).map(\.title)
        #expect(titles.firstIndex(of: "Отчёт 9")! < titles.firstIndex(of: "Отчёт 10")!)
        // Manual: by status then order.
        #expect(TaskViews.list(tasks, .empty, locale: ru, todayKey: today).map(\.id) == ["1", "4", "2", "3"])
    }

    @Test func board() {
        let view = TaskViews.board(tasks, ViewState(query: "отчёт"), locale: ru, todayKey: today)
        #expect(view.shown == 2)
        #expect(view.total == 4)
        #expect(view.totals[.todo] == 2)
        #expect(view.columns[.todo]!.isEmpty)
    }

    @Test func statistics() {
        let now = local(2026, 10, 21, 12)
        let stats = TaskViews.stats(tasks + [tasks[0]], now: now, timeZone: berlin)
        #expect(stats == TaskStats(total: 4, done: 1, overdue: 1, percent: 25))
        #expect(TaskViews.stats([], now: now, timeZone: berlin).percent == nil)
    }

    @Test func dueStates() {
        let now = local(2026, 10, 21, 12)
        func state(_ date: String?, _ time: String? = nil, _ status: TaskStatus = .todo) -> DueState {
            DueDates.dueState(makeTask(dueDate: date, dueTime: time, status: status), now: now, timeZone: berlin)
        }
        #expect(state("2026-10-20") == .overdue)
        #expect(state("2026-10-21") == .today)
        #expect(state("2026-10-21", "11:00") == .overdue)
        #expect(state("2026-10-21", "13:00") == .today)
        #expect(state("2026-10-22") == .tomorrow)
        #expect(state("2026-10-30") == .upcoming)
        #expect(state("2026-10-01", nil, .done) == .done)
        #expect(state(nil) == .none)
        #expect(state("2026-13-01") == .none)
    }

    @Test func scopeAndCounts() {
        let list = [makeTask(id: "a", categoryId: "x"), makeTask(id: "b"), makeTask(id: "c", categoryId: "x")]
        #expect(TaskViews.scope(list, .uncategorized).map(\.id) == ["b"])
        #expect(TaskViews.scope(list, .category("x")).map(\.id) == ["a", "c"])
        let counts = TaskViews.countByCategory(list)
        #expect(counts[.all] == 3 && counts[.uncategorized] == 1 && counts[.category("x")] == 2)
    }

    @Test func scopedDragPositions() {
        let full = ["a", "h1", "b", "h2", "c"]
        let visible = ["a", "b", "c"]
        #expect(TaskViews.toFullColumnIndex(fullIds: full, visibleIds: visible, taskId: "c", visibleIndex: 1) == 2)
        #expect(TaskViews.toFullColumnIndex(fullIds: full, visibleIds: visible, taskId: "a", visibleIndex: 2) == 4)
        #expect(TaskViews.toFullColumnIndex(fullIds: ["h1"], visibleIds: [], taskId: "x", visibleIndex: 0) == 1)
        #expect(TaskViews.toFullColumnIndex(fullIds: ["a", "b", "c"], visibleIds: ["a", "b", "c"], taskId: "a", visibleIndex: 1) == 1)
    }

    @Test func dueDateSortUsesTime() {
        let list = [makeTask(id: "a", dueDate: "2026-10-21"), makeTask(id: "b", dueDate: "2026-10-21", dueTime: "18:00"), makeTask(id: "c", dueDate: "2026-10-21", dueTime: "09:00"), makeTask(id: "d")]
        #expect(TaskViews.list(list, ViewState(sort: .dueDate), locale: ru, todayKey: today).map(\.id) == ["c", "b", "a", "d"])
    }

    @Test func sections() {
        let now = local(2026, 10, 21, 12)
        let list = [
            makeTask(id: "late", dueDate: "2026-10-20"),
            makeTask(id: "today", dueDate: "2026-10-21", dueTime: "15:00"),
            makeTask(id: "todayPast", dueDate: "2026-10-21", dueTime: "10:00"),
            makeTask(id: "tomorrow", dueDate: "2026-10-22"),
            makeTask(id: "none"),
            makeTask(id: "doneOld", dueDate: "2026-10-21", status: .done, completedAt: "2026-10-20T10:00:00.000Z"),
            makeTask(id: "doneNew", status: .done, completedAt: "2026-10-21T09:00:00.000Z"),
        ]
        let result = TaskViews.sections(list, ViewState(sort: .dueDate), locale: ru, now: now, timeZone: berlin)
        #expect(result.map(\.section) == [.overdue, .today, .future, .noDate, .done])
        #expect(result.map { $0.tasks.map(\.id) } == [["late", "todayPast"], ["today"], ["tomorrow"], ["none"], ["doneNew", "doneOld"]])
        // Filters still apply; empty sections are left out.
        #expect(TaskViews.sections(list, ViewState(statuses: [.done], sort: .dueDate), locale: ru, now: now, timeZone: berlin).map(\.section) == [.done])
    }

    @Test func completionChart() {
        let now = local(2026, 10, 21, 12)
        let list = [
            makeTask(status: .done, completedAt: ISOTime.string(local(2026, 10, 21, 8))),
            makeTask(status: .done, completedAt: ISOTime.string(local(2026, 10, 21, 0, 30))),
            makeTask(status: .done, completedAt: ISOTime.string(local(2026, 10, 15, 9))),
            makeTask(status: .done, completedAt: ISOTime.string(local(2026, 10, 1, 9))),
            makeTask(),
        ]
        let days = TaskViews.completionsByDay(list, days: 7, now: now, timeZone: berlin)
        #expect(days.map(\.dateKey) == ["2026-10-15", "2026-10-16", "2026-10-17", "2026-10-18", "2026-10-19", "2026-10-20", "2026-10-21"])
        #expect(days.map(\.count) == [1, 0, 0, 0, 0, 0, 2])
    }

    @Test func calendarGroups() {
        let groups = TaskViews.tasksByDate([makeTask(id: "a", dueDate: "2026-10-21"), makeTask(id: "b", dueDate: "2026-10-21", dueTime: "09:00"), makeTask(id: "c")])
        #expect(groups.keys.sorted() == ["2026-10-21"])
        #expect(groups["2026-10-21"]?.map(\.id) == ["b", "a"])
    }
}

// MARK: - Optimized paths give the same results as the straightforward ones

@Suite("Optimized view paths")
struct OptimizedViewPathTests {
    /// Tasks with many ties (same dates, times, priorities, orders, titles differing in case).
    static let tasks: [TaskItem] = (0..<300).map { index in
        let dueDate = index % 5 == 0 ? nil : Schedule.addDaysToKey("2026-11-04", index % 9 - 3)
        return makeTask(
            id: "opt-\(String(format: "%03d", (index * 37) % 300))", title: index % 2 == 0 ? "Отчёт \(index % 13)" : "отчёт \(index % 13)",
            priority: [Priority.high, .medium, .low][index % 3], dueDate: dueDate,
            dueTime: dueDate != nil && index % 3 == 0 ? (index % 2 == 0 ? "09:30" : "18:05") : nil,
            status: [TaskStatus.todo, .inProgress, .done][index % 3], order: Double(index % 7),
            createdAt: "2026-10-0\(index % 9 + 1)T00:00:00.000Z"
        )
    }

    @Test(arguments: SortMode.allCases)
    func sortMatchesComparator(_ mode: SortMode) {
        let locale = Locale(identifier: "ru")
        let first = TaskViews.primary(mode, locale: locale)
        let rank = { (task: TaskItem) in TaskModel.statuses.firstIndex(of: task.status)! }
        let expected = Self.tasks.sorted { a, b in
            let result = first(a, b)
            if result != 0 { return result < 0 }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            return Tasks.compare(a, b)
        }
        #expect(TaskViews.sorted(Self.tasks, by: mode, locale: locale).map(\.id) == expected.map(\.id))
        // The board keeps the comparator order within each column.
        let board = TaskViews.board(Self.tasks, ViewState(sort: mode), locale: locale, todayKey: "2026-11-04")
        for status in TaskModel.statuses {
            let column = Self.tasks.filter { $0.status == status }.sorted(by: TaskViews.comparator(mode, locale: locale))
            #expect(board.columns[status]!.map(\.id) == column.map(\.id))
        }
    }

    @Test func includesIsACodeUnitMatch() {
        #expect(JSText.includes("отчёт за неделю", "за нед"))
        #expect(JSText.includes("abc", ""))
        #expect(!JSText.includes("ab", "abc"))
        #expect(!JSText.includes("отчет", "отчёт"))
        // "e" + combining acute: JavaScript finds "e"; Swift's Character matching would not.
        #expect(JSText.includes("cafe\u{301}", "cafe"))
        #expect(JSText.includes("😀 смайл", "смайл"))
    }

    @Test func searchFoldsOnce() {
        let task = makeTask(title: "Ёлка  к\tПРАЗДНИКУ", description: "Купить\nигрушки")
        for (query, expected) in [("елка к праздн", true), ("ЁЛКА", true), ("купить игрушки", true), ("ёлки", false), ("  ", true)] {
            #expect(TaskViews.matches(task, ViewState(query: query), todayKey: "2026-11-04") == expected, "\(query)")
        }
        #expect(TaskViews.fold("A\u{00A0}\u{2003}b\r\nc") == "a b c")
    }

    @Test func canonicalTimestampsReadExactly() throws {
        for text in ["2026-11-04T09:30:00.000Z", "2026-03-29T01:59:59.999Z", "2024-02-29T23:00:00.120Z", "1970-01-01T00:00:00.000Z"] {
            let fast = try #require(ISOTime.canonicalDate(text))
            let full = try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text)
            #expect(abs(fast.timeIntervalSince(full)) < 0.001, "\(text)")
            // Like the full parser, within the millisecond the text states (writing a parsed
            // value back can lose the last millisecond to floating point either way).
        }
        // Not the canonical form, or out of range: left to the full parser.
        for text in ["2026-11-04T09:30:00Z", "2026-02-30T00:00:00.000Z", "2026-11-04T24:00:00.000Z", "2026-11-04 09:30:00.000Z", "2026-1a-04T09:30:00.000Z"] {
            #expect(ISOTime.canonicalDate(text) == nil, "\(text)")
        }
        #expect(ISOTime.date("2026-11-04T09:30:00Z") != nil)
        // The full parser is lenient about day overflow; that stays as it was.
        #expect(ISOTime.date("2026-02-30T00:00:00.000Z") == (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse("2026-02-30T00:00:00.000Z")))
    }

    @Test func cachedDateFormatsFollowTheLanguage() {
        #expect(L10n(.ru).formatDate("2026-11-04", .weekdayFull) != L10n(.en).formatDate("2026-11-04", .weekdayFull))
        #expect(L10n(.en).formatDate("2026-11-04") == L10n(.en).formatDate("2026-11-04"))
    }
}
