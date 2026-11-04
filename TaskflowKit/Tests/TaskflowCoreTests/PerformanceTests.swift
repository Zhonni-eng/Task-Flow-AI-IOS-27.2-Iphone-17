// Timings of the work the interface repeats on every change (list, sections, board, statistics,
// due texts, saving, reminders) for a large collection. Nothing here fails on time - the numbers
// are printed so before/after changes can be compared:
//   ./scripts/test-core.sh -c release -Xswiftc -enable-testing --filter Performance
import Foundation
import Testing
@testable import TaskflowCore

@Suite("Performance (prints timings)", .serialized)
struct PerformanceTests {
    static let count = 3000
    static let now = local(2026, 11, 4, 12, 0)

    /// A mixed collection: due dates around today, times, labels, categories, all statuses,
    /// reminders and some repeating tasks.
    static let tasks: [TaskItem] = (0..<count).map { index in
        let day = index % 60 - 20
        let dueDate = index % 7 == 0 ? nil : Schedule.addDaysToKey("2026-11-04", day)
        let status: TaskStatus = index % 5 == 0 ? .done : index % 3 == 0 ? .inProgress : .todo
        return makeTask(
            id: "perf-\(index)", title: "Задача номер \(index) отчёт", description: "Описание \(index)",
            priority: [Priority.high, .medium, .low][index % 3],
            dueDate: dueDate, dueTime: dueDate != nil && index % 2 == 0 ? "1\(index % 10):30" : nil,
            reminders: dueDate != nil && index % 4 == 0 ? [0, 60] : [],
            recurrence: dueDate != nil && index % 11 == 0 ? Recurrence(freq: .weekly, interval: 1, weekdays: [1, 4], monthDay: nil) : nil,
            labels: index % 2 == 0 ? ["работа", "label\(index % 9)"] : [],
            status: status, order: Double(index), categoryId: index % 4 == 0 ? nil : "cat-\(index % 6)",
            completedAt: status == .done ? "2026-11-0\(index % 4 + 1)T10:00:00.000Z" : nil
        )
    }

    static func measure(_ name: String, repeat times: Int = 20, _ work: () -> Void) {
        work() // warm-up
        let clock = ContinuousClock()
        let elapsed = clock.measure { for _ in 0..<times { work() } }
        let micros = Double(elapsed.components.attoseconds) / 1e12 + Double(elapsed.components.seconds) * 1e6
        print(String(format: "PERF %-34@ %9.1f µs", name as NSString, micros / Double(times)))
    }

    @Test func viewComputations() {
        let tasks = Self.tasks
        let locale = Locale(identifier: "ru")
        let todayKey = Schedule.localDateKey(Self.now, timeZone: berlin)
        let sorted = ViewState(sort: .dueDate)
        let searching = ViewState(query: "номер 12", sort: .dueDate)
        Self.measure("list (due date)") { _ = TaskViews.list(tasks, sorted, locale: locale, todayKey: todayKey) }
        Self.measure("list (title)") { _ = TaskViews.list(tasks, ViewState(sort: .title), locale: locale, todayKey: todayKey) }
        Self.measure("list (search)") { _ = TaskViews.list(tasks, searching, locale: locale, todayKey: todayKey) }
        Self.measure("sections") { _ = TaskViews.sections(tasks, sorted, locale: locale, now: Self.now, timeZone: berlin) }
        Self.measure("board") { _ = TaskViews.board(tasks, sorted, locale: locale, todayKey: todayKey) }
        Self.measure("stats") { _ = TaskViews.stats(tasks, now: Self.now, timeZone: berlin) }
        Self.measure("countByCategory") { _ = TaskViews.countByCategory(tasks) }
        Self.measure("tasksByDate") { _ = TaskViews.tasksByDate(tasks) }
        Self.measure("completionsByDay") { _ = TaskViews.completionsByDay(tasks, now: Self.now, timeZone: berlin) }
    }

    @Test func dueTexts() {
        let l10n = L10n(.ru)
        let visible = Array(Self.tasks.prefix(200))
        Self.measure("DueText.make x200") {
            for task in visible { _ = DueText.make(task, l: l10n, list: true, now: Self.now, timeZone: berlin) }
        }
        Self.measure("formatDate x200") {
            for task in visible { _ = l10n.formatDate(task.dueDate ?? "2026-11-04", .weekdayFull) }
        }
    }

    @Test func savingAndLoading() throws {
        let document = TaskflowDocument(tasks: Self.tasks)
        let data = document.fileData()
        Self.measure("fileData (save encode)", repeat: 5) { _ = document.fileData() }
        Self.measure("decode (load)", repeat: 5) { _ = try? DocumentCodec.decode(data) }
        Self.measure("normalizedForSave", repeat: 5) { _ = DocumentCodec.normalizedForSave(document) }
        Self.measure("Tasks.restore (startup)", repeat: 5) { _ = Tasks.restore(Self.tasks.map(\.json)) }
        Self.measure("record JSON per task (store save)", repeat: 5) {
            for task in Self.tasks {
                _ = task.recurrence.map { $0.json.serialized() }
                _ = JSONValue.array(task.subtasks.map(\.json)).serialized()
            }
        }
        print("PERF file size: \(data.count / 1024) KB")
    }

    @Test func reminders() {
        let state = ReminderState()
        Self.measure("ReminderEngine.sync", repeat: 10) {
            _ = ReminderEngine.sync(tasks: Self.tasks, settings: ReminderSettings(), language: .ru, state: state, now: Self.now, timeZone: berlin)
        }
        // A long-used app: thousands of handled reminders are checked for expiry on every sync.
        var fired: [String: String] = [:]
        for index in 0..<4000 { fired["perf-\(index % Self.count)|2026-10-\(10 + index % 20)|day@09:00|\(index)"] = "2026-10-\(10 + index % 20)T09:00:00.000Z" }
        let used = ReminderState(fired: fired)
        Self.measure("ReminderEngine.sync (4000 records)", repeat: 10) {
            _ = ReminderEngine.sync(tasks: Self.tasks, settings: ReminderSettings(), language: .ru, state: used, now: Self.now, timeZone: berlin)
        }
    }
}
