// Due-date state of a task, derived from its local "YYYY-MM-DD" due date and status - a port of
// src/data/dueDates.js. Nothing here is stored: overdue/today/upcoming always follow the current
// local date.
import Foundation

public enum DueState: String, Sendable {
    case none, done, overdue, today, tomorrow, upcoming
}

public enum DueFilter: String, CaseIterable, Sendable, Codable, Hashable {
    case overdue, today, upcoming
}

public enum DueDates {
    /// .none (no due date), .done (completed: never overdue), .overdue, .today, .tomorrow or
    /// .upcoming (later than tomorrow). Only a due time on the current day is compared with `now`
    /// (a task due today at 16:30 is overdue from 16:30).
    public static func dueState(_ task: TaskItem, now: Date = Date(), timeZone: TimeZone = .current) -> DueState {
        dueState(task, today: Today(now: now, timeZone: timeZone))
    }

    /// The current day, computed once when many tasks are compared with it.
    struct Today {
        let now: Date
        let timeZone: TimeZone
        let key: String
        let tomorrowKey: String

        init(now: Date, timeZone: TimeZone) {
            self.now = now
            self.timeZone = timeZone
            key = Schedule.localDateKey(now, timeZone: timeZone)
            tomorrowKey = Schedule.addDaysToKey(key, 1)
        }
    }

    static func dueState(_ task: TaskItem, today: Today) -> DueState {
        guard let dueDate = task.dueDate, Schedule.isDateKey(dueDate) else { return .none }
        if task.status == .done { return .done }
        if dueDate < today.key { return .overdue }
        if dueDate == today.key, task.dueTime != nil,
           let deadline = Schedule.deadlineInstant(dueDate: dueDate, dueTime: task.dueTime, timeZone: today.timeZone), today.now >= deadline {
            return .overdue
        }
        if dueDate == today.key { return .today }
        if dueDate == today.tomorrowKey { return .tomorrow }
        return .upcoming
    }

    /// - overdue:  due before today and not completed
    /// - today:    due today (any status, so finished work for today stays visible)
    /// - upcoming: due after today and not completed
    /// Tasks without a due date never match.
    public static func matches(_ task: TaskItem, filter: DueFilter, todayKey: String) -> Bool {
        guard let dueDate = task.dueDate, Schedule.isDateKey(dueDate) else { return false }
        switch filter {
        case .overdue: return task.status != .done && dueDate < todayKey
        case .today: return dueDate == todayKey
        case .upcoming: return task.status != .done && dueDate > todayKey
        }
    }
}
