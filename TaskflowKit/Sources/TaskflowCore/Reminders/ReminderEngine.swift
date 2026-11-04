// Local reminders - the rules of electron/reminders.cjs, adapted to iOS notifications. Reminder
// times are computed from the saved tasks (Schedule.reminderSchedule); every reminder that was
// shown or deliberately skipped is recorded, so a restart never repeats nor loses one.
//
// A reminder key contains the task id, its deadline and the offset, so changing the deadline
// creates new reminders and the old ones are simply never due again. Deleted or completed tasks
// have no reminders.
//
// iPhone difference: the system delivers scheduled notifications even when Taskflow is closed. iOS
// keeps at most 64 pending notifications per app, so the nearest `limit` reminders are scheduled
// and the rest are scheduled later (on every change, launch and return to the app). A reminder
// whose time passed while it was not scheduled is shown like on Windows: on time (up to 5 minutes
// late) as itself, otherwise - if less than a day old - in one "missed reminders" notification;
// older ones are recorded as handled without a notification.
import Foundation

public struct ReminderNotification: Equatable, Sendable {
    public var id: String
    public var title: String
    public var body: String
    public var taskId: String?
    /// nil = deliver now.
    public var fireAt: Date?
}

public struct ReminderState: Equatable, Sendable, Codable {
    public static let version = 1
    /// reminder key -> ISO time it was handled
    public var fired: [String: String] = [:]
    /// keys currently handed to the system as pending notifications
    public var scheduled: Set<String> = []

    public init(fired: [String: String] = [:], scheduled: Set<String> = []) {
        self.fired = fired
        self.scheduled = scheduled
    }
}

public struct ReminderSync: Equatable, Sendable {
    /// The pending notifications that should exist after this sync (replaces all earlier ones).
    public var pending: [ReminderNotification]
    /// Notifications to show now.
    public var immediate: [ReminderNotification]
    public var state: ReminderState
}

public enum ReminderEngine {
    public static let onTimeGrace: TimeInterval = 5 * 60 // up to 5 minutes late still counts as on time
    public static let missedWindow: TimeInterval = 24 * 60 * 60
    static let keepRecords: TimeInterval = 60 * 24 * 60 * 60
    static let maxRecords = 5000
    /// iOS allows 64 pending notifications per app; a few stay free for immediate ones.
    public static let defaultLimit = 60

    public static func key(_ task: TaskItem, offset: Int, allDayTime: String) -> String {
        [task.id, task.dueDate ?? "", task.dueTime ?? "day@\(allDayTime)", String(offset)].joined(separator: "|")
    }

    static let texts: [Language: (title: @Sendable (String) -> String, due: @Sendable (String) -> String, missed: @Sendable (Int) -> String, more: @Sendable (Int) -> String)] = [
        .ru: ({ "Напоминание: \($0)" }, { "Срок: \($0)" }, { "Пропущенные напоминания: \($0)" }, { "и ещё \($0)" }),
        .en: ({ "Reminder: \($0)" }, { "Due: \($0)" }, { "Missed reminders: \($0)" }, { "and \($0) more" }),
    ]

    /// "30 Oct, 16:30" / "30 окт., 16:30" or the date alone, in local time.
    public static func formatDeadline(_ task: TaskItem, language: Language) -> String {
        guard let dueDate = task.dueDate else { return "" }
        let formatter = Formatters.template("dMMM", locale: Locale(identifier: language == .en ? "en_GB" : "ru_RU"), timeZone: L10n.utc)
        let date = formatter.string(from: Schedule.localInstant(dueDate, timeZone: L10n.utc))
        return task.dueTime.map { "\(date), \($0)" } ?? date
    }

    struct Item {
        var key: String
        var at: Date
        var task: TaskItem
    }

    static func collect(_ tasks: [TaskItem], allDayTime: String, timeZone: TimeZone) -> [Item] {
        tasks.filter { $0.status != .done }.flatMap { task in
            Schedule.reminderSchedule(reminders: task.reminders, dueDate: task.dueDate, dueTime: task.dueTime, allDayTime: allDayTime, timeZone: timeZone).map {
                Item(key: key(task, offset: $0.offset, allDayTime: allDayTime), at: $0.at, task: task)
            }
        }
    }

    public static func sync(tasks: [TaskItem], settings: ReminderSettings, language: Language, state: ReminderState, now: Date = Date(), timeZone: TimeZone = .current, limit: Int = defaultLimit) -> ReminderSync {
        var fired = state.fired
        let text = texts[language]!
        let all = collect(tasks, allDayTime: settings.allDayTime, timeZone: timeZone)
        var onTime: [Item] = []
        var missed: [Item] = []
        var future: [Item] = []

        for item in all where fired[item.key] == nil {
            let late = now.timeIntervalSince(item.at)
            if late < 0 {
                future.append(item)
                continue
            }
            // Due now: recorded either way. With reminders switched off nothing is shown, and switching
            // them back on later does not bring these back as "missed". One the system already
            // delivered (it was pending) is not shown again.
            fired[item.key] = ISOTime.string(now)
            if !settings.enabled || state.scheduled.contains(item.key) { continue }
            if late <= onTimeGrace { onTime.append(item) } else if late <= missedWindow { missed.append(item) }
        }

        var immediate = onTime.map { item in
            ReminderNotification(id: item.key, title: text.title(item.task.title), body: text.due(formatDeadline(item.task, language: language)), taskId: item.task.id, fireAt: nil)
        }
        if !missed.isEmpty {
            var names = missed.prefix(3).map { "• \($0.task.title) (\(formatDeadline($0.task, language: language)))" }
            if missed.count > 3 { names.append(text.more(missed.count - 3)) }
            immediate.append(ReminderNotification(id: "missed|\(ISOTime.string(now))", title: text.missed(missed.count), body: names.joined(separator: "\n"), taskId: nil, fireAt: nil))
        }

        let pending: [ReminderNotification] = settings.enabled
            ? future.indices.sorted { future[$0].at < future[$1].at }.prefix(limit).map { future[$0] }.map { item in
                ReminderNotification(id: item.key, title: text.title(item.task.title), body: text.due(formatDeadline(item.task, language: language)), taskId: item.task.id, fireAt: item.at)
            }
            : []

        // Forget records of deleted tasks and old reminders, so the state stays small.
        let liveTasks = Set(tasks.map(\.id))
        for (key, handled) in fired {
            let taskId = String(key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            let handledAt = ISOTime.date(handled)
            if !liveTasks.contains(taskId) || handledAt == nil || now.timeIntervalSince(handledAt!) >= keepRecords { fired[key] = nil }
        }
        if fired.count > maxRecords {
            fired = Dictionary(uniqueKeysWithValues: fired.sorted { $0.value > $1.value }.prefix(maxRecords).map { ($0.key, $0.value) })
        }
        return ReminderSync(pending: pending, immediate: immediate, state: ReminderState(fired: fired, scheduled: Set(pending.map(\.id))))
    }
}
