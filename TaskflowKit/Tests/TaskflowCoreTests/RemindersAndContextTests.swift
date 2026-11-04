// Reminders (port of tests/unit/reminders.test.js, adapted to scheduled iOS notifications), the
// assistant's task context (tests/unit/taskContext.test.js), the prompt and localization.
import Foundation
import Testing
@testable import TaskflowCore

@Suite("Reminders")
struct ReminderTests {
    let settings = ReminderSettings(enabled: true, allDayTime: "09:00")
    func exam(_ dueTime: String? = "16:30", reminders: [Int] = [30], status: TaskStatus = .todo) -> TaskItem {
        makeTask(id: "exam", title: "Экзамен", dueDate: "2026-10-30", dueTime: dueTime, reminders: reminders, status: status)
    }
    func sync(_ tasks: [TaskItem], at date: Date, state: ReminderState = ReminderState(), settings: ReminderSettings? = nil, language: Language = .ru) -> ReminderSync {
        ReminderEngine.sync(tasks: tasks, settings: settings ?? self.settings, language: language, state: state, now: date, timeZone: berlin)
    }

    @Test func schedulesAheadWithText() {
        let result = sync([exam()], at: local(2026, 10, 30, 15))
        #expect(result.immediate.isEmpty)
        #expect(result.pending.count == 1)
        #expect(result.pending[0].title == "Напоминание: Экзамен")
        #expect(result.pending[0].body == "Срок: 30 окт., 16:30")
        #expect(result.pending[0].fireAt == local(2026, 10, 30, 16, 0))
        #expect(result.state.scheduled == ["exam|2026-10-30|16:30|30"])
    }

    @Test func deliveredBySystemIsNotShownAgain() {
        let first = sync([exam()], at: local(2026, 10, 30, 15))
        let later = sync([exam()], at: local(2026, 10, 30, 16, 1), state: first.state)
        #expect(later.immediate.isEmpty)
        #expect(later.pending.isEmpty)
        #expect(later.state.fired["exam|2026-10-30|16:30|30"] != nil)
        #expect(sync([exam()], at: local(2026, 10, 30, 16, 2), state: later.state).immediate.isEmpty)
    }

    @Test func notScheduledButDueNowIsShownOnce() {
        let result = sync([exam()], at: local(2026, 10, 30, 16, 1))
        #expect(result.immediate.map(\.title) == ["Напоминание: Экзамен"])
        #expect(sync([exam()], at: local(2026, 10, 30, 16, 2), state: result.state).immediate.isEmpty)
    }

    @Test func changingDeadlineReschedules() {
        let first = sync([exam()], at: local(2026, 10, 30, 15))
        let moved = makeTask(id: "exam", title: "Экзамен", dueDate: "2026-10-31", dueTime: "16:30", reminders: [30])
        let result = sync([moved], at: local(2026, 10, 30, 15, 5), state: first.state)
        #expect(result.pending.map(\.id) == ["exam|2026-10-31|16:30|30"])
    }

    @Test func deletedAndCompletedHaveNoReminders() {
        let first = sync([exam()], at: local(2026, 10, 30, 16, 1))
        #expect(!first.state.fired.isEmpty)
        #expect(sync([exam(status: .done)], at: local(2026, 10, 30, 15)).pending.isEmpty)
        #expect(sync([], at: local(2026, 10, 30, 17), state: first.state).state.fired.isEmpty)
    }

    @Test func missedWhileClosed() {
        let tasks = [
            makeTask(id: "a", title: "A", dueDate: "2026-10-30", dueTime: "10:00", reminders: [0]),
            makeTask(id: "b", title: "B", dueDate: "2026-10-30", dueTime: "11:00", reminders: [0]),
            makeTask(id: "old", title: "Old", dueDate: "2026-10-20", dueTime: "11:00", reminders: [0]),
        ]
        let result = sync(tasks, at: local(2026, 10, 30, 15))
        #expect(result.immediate.count == 1)
        #expect(result.immediate[0].title == "Пропущенные напоминания: 2")
        #expect(result.immediate[0].body == "• A (30 окт., 10:00)\n• B (30 окт., 11:00)")
        #expect(result.state.fired.count == 3)
    }

    @Test func allDayTimeSetting() {
        let task = makeTask(id: "d", title: "D", dueDate: "2026-10-31", reminders: [1440])
        let result = sync([task], at: local(2026, 10, 30, 7), settings: ReminderSettings(enabled: true, allDayTime: "08:15"))
        #expect(result.pending[0].fireAt == local(2026, 10, 30, 8, 15))
        #expect(result.pending[0].id == "d|2026-10-31|day@08:15|1440")
    }

    @Test func switchedOff() {
        let off = ReminderSettings(enabled: false, allDayTime: "09:00")
        let result = sync([exam()], at: local(2026, 10, 30, 16, 5), settings: off)
        #expect(result.immediate.isEmpty && result.pending.isEmpty)
        // Switching back on later does not bring them back as missed.
        #expect(sync([exam()], at: local(2026, 10, 30, 16, 10), state: result.state).immediate.isEmpty)
    }

    @Test func englishText() {
        let result = sync([exam()], at: local(2026, 10, 30, 15), language: .en)
        #expect(result.pending[0].title == "Reminder: Экзамен")
        #expect(result.pending[0].body == "Due: 30 Oct, 16:30")
    }

    @Test func pendingLimitKeepsNearest() {
        let tasks = (1...80).map { makeTask(id: "t\($0)", title: "T\($0)", dueDate: Schedule.addDaysToKey("2026-11-01", $0), dueTime: "10:00", reminders: [0]) }
        let result = ReminderEngine.sync(tasks: tasks, settings: settings, language: .ru, state: ReminderState(), now: local(2026, 10, 30, 15), timeZone: berlin, limit: 60)
        #expect(result.pending.count == 60)
        #expect(result.pending.first?.id.hasPrefix("t1|") == true)
        #expect(result.pending.last?.id.hasPrefix("t60|") == true)
    }
}

@Suite("Task context for the assistant")
struct TaskContextTests {
    let today = "2026-10-25"
    let tasks = [
        makeTask(id: "lab", title: "Лабораторная по физике", dueDate: "2026-10-26"),
        makeTask(id: "lab2", title: "Лабораторная по химии"),
        makeTask(id: "exam", title: "Экзамен", description: "secret description", dueDate: "2026-10-20", labels: ["учёба"], categoryId: "cat-study", subtasks: [sub("s1", "A")]),
        makeTask(id: "groceries", title: "Buy groceries", priority: .high),
        makeTask(id: "done", title: "Report", status: .done, completedAt: "2026-10-01T00:00:00.000Z"),
    ]

    func ids(_ message: String, pinned: [String] = [], categories: [(id: String, name: String)] = []) -> [String] {
        TaskContext.select(message: message, tasks: tasks, pinnedIds: pinned, categories: categories, todayKey: today, nowTime: "12:00").map(\.task.id)
    }

    @Test func wordForms() {
        #expect(ids("перенеси лабораторную на завтра") == ["lab", "lab2"])
        #expect(ids("лабораторной по физике").first == "lab")
        #expect(ids("grocery") == ["groceries"])
        #expect(TaskContext.wordsMatch("лабораторной", "лабораторная"))
        #expect(!TaskContext.wordsMatch("лаб", "лабиринт"))
    }

    @Test func ignoresCommandWords() {
        #expect(ids("пожалуйста, измени это").isEmpty)
        // "выполненной" asks for completed tasks as a group (as in the Windows app).
        #expect(ids("отметь задачу выполненной") == ["done"])
    }

    @Test func pinnedFirst() {
        #expect(ids("купить молоко", pinned: ["done", "ghost"]) == ["done"])
    }

    @Test func groupRequests() {
        #expect(ids("что просрочено?") == ["exam"])
        #expect(ids("что в учёбе", categories: [("cat-study", "Учёба")]).contains("exam"))
        #expect(Set(ids("составь план на мой день")) == ["exam", "lab", "groceries"])
        #expect(ids("what have i done").contains("done"))
        #expect(!ids("Report is done").contains("lab"))
    }

    @Test func tagsAndSummary() {
        #expect(ids("убери метку учёба").contains("exam"))
        #expect(TaskContext.tagSummary(tasks + [makeTask(labels: ["Учёба", "дом"])]) == [Prompt.Tag(name: "учёба", count: 2), Prompt.Tag(name: "дом", count: 1)])
        let summary = TaskContext.summary(tasks, todayKey: today, nowTime: "12:00")
        #expect(summary == Prompt.Summary(total: 5, todo: 4, inProgress: 0, done: 1, overdue: 1, dueToday: 0))
    }

    @Test func limit() {
        let many = (1...60).map { makeTask(id: "m\($0)", title: "Отчёт \($0)") }
        #expect(TaskContext.select(message: "отчёт", tasks: many, todayKey: today).count == TaskContext.maxContextTasks)
    }

    @Test func promptNeverContainsDescriptions() {
        let selected = TaskContext.select(message: "экзамен", tasks: tasks, todayKey: today, nowTime: "12:00")
        let turn = Prompt.buildUserTurn(message: "экзамен", language: .ru, categories: [("cat-study", "Учёба")], tasks: selected, summary: TaskContext.summary(tasks, todayKey: today), tags: TaskContext.tagSummary(tasks), availability: nil, date: Prompt.dateContext(now: local(2026, 10, 25, 12), timeZone: berlin))
        #expect(!turn.contains("secret description"))
        #expect(turn.contains(#"- id: exam | "Экзамен" | todo | category: cat-study | due: 2026-10-20 | tags: "учёба""#))
        #expect(turn.contains("subtasks: s1 [ ] \"A\""))
        #expect(turn.contains("- Today: 2026-10-25 (Sunday), now 12:00"))
        #expect(turn.contains("- Time zone: Europe/Berlin"))
        #expect(turn.contains("- Planning availability: not set"))
        #expect(turn.hasSuffix("User message:\nэкзамен"))
    }
}

@Suite("Localization")
struct L10nTests {
    @Test func pluralsAndInterpolation() {
        let ru = L10n(.ru)
        #expect(ru.t("board.columnTaskCount", ["count": 1]) == "1 задача")
        #expect(ru.t("board.columnTaskCount", ["count": 3]) == "3 задачи")
        #expect(ru.t("board.columnTaskCount", ["count": 5]) == "5 задач")
        #expect(ru.t("board.columnTaskCount", ["count": 21]) == "21 задача")
        #expect(ru.t("board.columnTaskCount", ["count": 12]) == "12 задач")
        let en = L10n(.en)
        #expect(en.t("board.columnTaskCount", ["count": 1]) == "1 task")
        #expect(en.t("board.columnTaskCount", ["count": 2]) == "2 tasks")
        #expect(en.t("toast.taskCreated", ["title": "X"]) == "Task “X” created")
        #expect(en.t("missing.key") == "missing.key")
    }

    @Test func iosOverridesAndFallback() {
        #expect(L10n(.ru).t("appSettings.remindersEnabled") == "Показывать напоминания")
        #expect(L10n(.en).t("ios.export") == "Export tasks (JSON)")
        #expect(L10n(.ru).t("columns.inProgress") == "В работе")
    }

    @Test func dates() {
        #expect(L10n(.ru).formatDate("2026-10-30") == "30 окт.")
        #expect(L10n(.en).formatDate("2026-10-30") == "Oct 30")
        // iOS capitalizes Russian short weekdays ("Чт"); the Windows app (Intl) writes "чт".
        #expect(L10n(.ru).formatDate("2026-10-22", .weekdayLong) == "Чт, 22 октября")
    }

    @Test func scheduleTexts() {
        let ru = L10n(.ru)
        #expect(ScheduleText.reminderLabel(ru, offset: 0, timed: true) == "В момент срока")
        #expect(ScheduleText.reminderLabel(ru, offset: 30, timed: true) == "За 30 минут")
        #expect(ScheduleText.reminderLabel(ru, offset: 1440, timed: false) == "За 1 день")
        #expect(ScheduleText.reminderLabel(ru, offset: 10080, timed: false) == "За 1 неделю")
        #expect(ScheduleText.recurrenceLabel(ru, Recurrence(freq: .weekly, interval: 1, weekdays: [4, 1])) == "Каждую неделю: Пн, Чт")
        #expect(ScheduleText.recurrenceLabel(L10n(.en), Recurrence(freq: .monthly, interval: 1, monthDay: 1)) == "Every month, on day 1")
        #expect(ScheduleText.recurrenceLabel(ru, Recurrence(freq: .daily, interval: 3)) == "Каждые 3 дня")
    }

    @Test func dueTexts() {
        let ru = L10n(.ru)
        let now = local(2026, 10, 25, 12)
        #expect(DueText.make(makeTask(dueDate: "2026-10-20"), l: ru, now: now, timeZone: berlin)?.text == "Просрочено · 20 окт.")
        #expect(DueText.make(makeTask(dueDate: "2026-10-25", dueTime: "16:30"), l: ru, now: now, timeZone: berlin)?.text == "Сегодня, 16:30")
        #expect(DueText.make(makeTask(dueDate: "2026-10-26"), l: ru, now: now, timeZone: berlin)?.text == "Завтра")
        #expect(DueText.make(makeTask(), l: ru) == nil)
    }

    @Test func sampleTasks() {
        let samples = SampleTasks.create(L10n(.ru), now: local(2026, 10, 25, 12), timeZone: berlin)
        #expect(samples.count == 8)
        #expect(samples[0].title == "Подготовить план спринта")
        #expect(samples[0].dueDate == "2026-10-27")
        #expect(samples.filter { $0.status == .inProgress }.map(\.order) == [0, 1, 2])
    }
}
