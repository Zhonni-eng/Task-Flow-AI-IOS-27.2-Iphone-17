// Deadlines, reminder schedules and recurrence, plus the reducer's completion behaviour - a port
// of tests/unit/schedule.test.js (Europe/Berlin).
import Foundation
import Testing
@testable import TaskflowCore

@Suite("Due times and reminders")
struct DueTimeTests {
    @Test func dueTimeNeedsDate() {
        #expect(Schedule.normalizeDueTime("16:30", dueDate: "2026-10-30") == "16:30")
        #expect(Schedule.normalizeDueTime("16:30", dueDate: nil) == nil)
        #expect(Schedule.normalizeDueTime("24:00", dueDate: "2026-10-30") == nil)
        #expect(Schedule.normalizeDueTime("9:5", dueDate: "2026-10-30") == nil)
    }

    @Test func remindersNormalization() {
        #expect(Schedule.normalizeReminders([60, 10, 10, 1440], dueDate: "2026-10-30", dueTime: "16:30") == [10, 60, 1440])
        #expect(Schedule.normalizeReminders([60, 10, 1440, 2880], dueDate: "2026-10-30", dueTime: nil) == [1440, 2880])
        #expect(Schedule.normalizeReminders([10], dueDate: nil, dueTime: nil) == [])
        #expect(Schedule.normalizeReminders([0, 10, 30, 60, 120, 1440], dueDate: "2026-10-30", dueTime: "16:30").count == 5)
        #expect(Schedule.normalizeReminders(json(#"[-5, 1.5, "10", 50000]"#), dueDate: "2026-10-30", dueTime: "16:30") == [])
    }

    @Test func timedRemindersAcrossDST() {
        // 25 Oct 2026: clocks go back. A 1-day reminder for 26 Oct 09:00 fires 25 Oct 09:00 local.
        let schedule = Schedule.reminderSchedule(reminders: [30, 1440], dueDate: "2026-10-26", dueTime: "09:00", timeZone: berlin)
        let parts = schedule.map { item -> [String] in
            [String(item.offset), Schedule.localDateKey(item.at, timeZone: berlin), Schedule.localTimeKey(item.at, timeZone: berlin)]
        }
        #expect(parts == [["30", "2026-10-26", "08:30"], ["1440", "2026-10-25", "09:00"]])
    }

    @Test func dateOnlyRemindersUseSetting() {
        let item = Schedule.reminderSchedule(reminders: [1440], dueDate: "2026-10-30", dueTime: nil, allDayTime: "08:15", timeZone: berlin)[0]
        #expect(Schedule.localDateKey(item.at, timeZone: berlin) == "2026-10-29")
        #expect(Schedule.localTimeKey(item.at, timeZone: berlin) == "08:15")
    }

    @Test func springForwardGap() {
        let at = Schedule.localInstant("2026-03-29", "02:30", timeZone: berlin)
        #expect(Schedule.localTimeKey(at, timeZone: berlin) == "03:30")
    }

    @Test func fallBackAmbiguousIsEarlier() {
        // 25 Oct 2026 02:30 happens twice in Berlin; the first one (CEST, UTC+2) is 00:30 UTC.
        let at = Schedule.localInstant("2026-10-25", "02:30", timeZone: berlin)
        #expect(ISOTime.string(at) == "2026-10-25T00:30:00.000Z")
    }

    @Test func deadlines() {
        #expect(Schedule.deadlineInstant(dueDate: "2026-10-30", dueTime: "16:30", timeZone: berlin) == local(2026, 10, 30, 16, 30))
        #expect(Schedule.deadlineInstant(dueDate: "2026-10-30", dueTime: nil, timeZone: berlin) == local(2026, 10, 31, 0, 0))
        #expect(Schedule.deadlineInstant(dueDate: nil, dueTime: nil) == nil)
    }

    @Test func dateKeys() {
        #expect(Schedule.isDateKey("2026-02-28"))
        #expect(!Schedule.isDateKey("2026-02-30"))
        #expect(Schedule.isDateKey("2028-02-29"))
        #expect(!Schedule.isDateKey("2026-2-28"))
        #expect(!Schedule.isDateKey("0050-01-01"))
        #expect(Schedule.addDaysToKey("2026-12-31", 1) == "2027-01-01")
        #expect(Schedule.addDaysToKey("2026-03-01", -1) == "2026-02-28")
        #expect(Schedule.weekdayOf("2026-10-30") == 5)
        #expect(Schedule.weekdayOf("2026-11-01") == 0)
    }
}

@Suite("Recurrence")
struct RecurrenceTests {
    @Test func normalization() {
        #expect(Schedule.normalizeRecurrence(json(#"{"freq":"weekly"}"#), dueDate: "2026-10-30") == Recurrence(freq: .weekly, interval: 1, weekdays: [5]))
        #expect(Schedule.normalizeRecurrence(json(#"{"freq":"monthly","interval":2}"#), dueDate: "2026-01-31") == Recurrence(freq: .monthly, interval: 2, monthDay: 31))
        #expect(Schedule.normalizeRecurrence(json(#"{"freq":"daily","interval":500}"#), dueDate: "2026-10-30") == Recurrence(freq: .daily, interval: 1))
        #expect(Schedule.normalizeRecurrence(json(#"{"freq":"hourly"}"#), dueDate: "2026-10-30") == nil)
        #expect(Schedule.normalizeRecurrence(json(#"{"freq":"daily"}"#), dueDate: nil) == nil)
    }

    @Test(arguments: [
        (Recurrence(freq: .daily, interval: 1), "2026-10-30", "2026-10-30", "2026-10-31"),
        (Recurrence(freq: .daily, interval: 3), "2026-10-30", "2026-11-04", "2026-11-05"),
        (Recurrence(freq: .weekly, interval: 1, weekdays: [1, 4]), "2026-10-26", "2026-10-26", "2026-10-29"),
        (Recurrence(freq: .weekly, interval: 2, weekdays: [5]), "2026-10-30", "2026-10-30", "2026-11-13"),
        (Recurrence(freq: .monthly, interval: 1, monthDay: 31), "2026-01-31", "2026-01-31", "2026-02-28"),
        (Recurrence(freq: .monthly, interval: 1, monthDay: 1), "2026-11-01", "2026-11-01", "2026-12-01"),
    ])
    func nextOccurrence(rule: Recurrence, from: String, after: String, expected: String) {
        #expect(Schedule.nextOccurrence(rule, from: from, after: after) == expected)
    }

    @Test func completingSkipsMissed() {
        #expect(Schedule.nextDueDateAfterCompletion(Recurrence(freq: .daily), dueDate: "2026-10-20", todayKey: "2026-10-25") == "2026-10-26")
        #expect(Schedule.nextDueDateAfterCompletion(Recurrence(freq: .monthly, monthDay: 1), dueDate: "2026-11-01", todayKey: "2026-10-25") == "2026-12-01")
    }
}

@Suite("Completing tasks (reducer)")
struct CompletingTests {
    let now = local(2026, 10, 25, 10, 0)

    @Test func completedAtRecorded() {
        let done = Tasks.withStatus(TaskModel.createTask(["title": "A"]), .done, now: now, timeZone: berlin)
        #expect(done.status == .done)
        #expect(done.completedAt == ISOTime.string(now))
        let reopened = Tasks.withStatus(done, .todo, now: now, timeZone: berlin)
        #expect(reopened.status == .todo)
        #expect(reopened.completedAt == nil)
    }

    @Test func recurringMovesToNextOccurrence() {
        let task = TaskModel.createTask(json(#"""
        {"title":"Оплатить аренду","dueDate":"2026-11-01","recurrence":{"freq":"monthly","monthDay":1},
         "subtasks":[{"id":"s1","title":"Перевод","done":true}],"status":"inProgress"}
        """#).objectValue!)
        var state = tasksReducer([], .create(task), now: now, timeZone: berlin)
        state = tasksReducer(state, .move(id: task.id, status: .done, index: 0), now: now, timeZone: berlin)
        #expect(state[0].status == .todo)
        #expect(state[0].dueDate == "2026-12-01")
        #expect(state[0].recurrence == Recurrence(freq: .monthly, interval: 1, monthDay: 1))
        #expect(state[0].subtasks[0].done == false)
        #expect(state[0].completedAt != nil)
    }

    @Test func replaceSwapsInsertsRemoves() {
        let a = TaskModel.createTask(["id": "a", "title": "A"])
        let b = TaskModel.createTask(["id": "b", "title": "B"])
        var state = [a, b].reduce([TaskItem]()) { tasksReducer($0, .create($1)) }
        var a2 = a
        a2.title = "A2"
        state = tasksReducer(state, .replace(tasks: [a2, TaskModel.createTask(["id": "c", "title": "C"])], removeIds: ["b"]))
        #expect(state.map { [$0.id, $0.title] }.sorted { $0[0] < $1[0] } == [["a", "A2"], ["c", "C"]])
        #expect(state.map(\.order).sorted() == [0, 1])
    }
}
