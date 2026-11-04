// Read-only view of the task collection: search, filters, sorting and statistics - a port of
// src/state/taskView.js. Nothing here modifies tasks or their saved manual order.
import Foundation

public enum SortMode: String, CaseIterable, Sendable, Codable, Hashable {
    case manual, dueDate, priority, title
}

public struct ViewState: Equatable, Sendable, Codable, Hashable {
    public var query: String = ""
    public var statuses: [TaskStatus] = []
    public var priorities: [Priority] = []
    public var labels: [String] = []
    public var due: [DueFilter] = []
    public var sort: SortMode = .manual

    public init(query: String = "", statuses: [TaskStatus] = [], priorities: [Priority] = [], labels: [String] = [], due: [DueFilter] = [], sort: SortMode = .manual) {
        self.query = query
        self.statuses = statuses
        self.priorities = priorities
        self.labels = labels
        self.due = due
        self.sort = sort
    }

    public static let empty = ViewState()
}

/// A sidebar destination: all tasks, uncategorized, or one category.
public enum Destination: Hashable, Sendable, Codable {
    case all
    case uncategorized
    case category(String)

    public static let allKey = "__all__"
    public static let uncategorizedKey = "__uncategorized__"

    public var storageKey: String {
        switch self {
        case .all: return Self.allKey
        case .uncategorized: return Self.uncategorizedKey
        case .category(let id): return id
        }
    }

    public init(storageKey: String) {
        switch storageKey {
        case Self.allKey: self = .all
        case Self.uncategorizedKey: self = .uncategorized
        default: self = .category(storageKey)
        }
    }
}

public struct BoardView: Equatable, Sendable {
    public var columns: [TaskStatus: [TaskItem]]
    public var totals: [TaskStatus: Int]
    public var shown: Int
    public var total: Int
}

public struct TaskStats: Equatable, Sendable {
    public var total: Int
    public var done: Int
    public var overdue: Int
    public var percent: Int?
}

public enum TaskViews {
    /// Case-insensitive, whitespace-tolerant text form; treats Russian "ё" as "е".
    static func fold(_ text: String) -> String {
        JSText.collapseWhitespace(JSText.lower(text)) { $0 == "ё" ? "е" : $0 }
    }

    /// Folded titles and descriptions, so typing a search does not fold every task again on each
    /// keystroke. Keyed by the text itself, so an edited task simply gets a new entry; the cache is
    /// emptied when it grows large.
    private final class FoldCache: @unchecked Sendable {
        let lock = NSLock()
        var folded: [String: String] = [:]
    }

    private static let foldCache = FoldCache()
    static let foldCacheLimit = 20_000

    static func cachedFold(_ text: String) -> String {
        if text.isEmpty { return "" }
        foldCache.lock.lock()
        if let hit = foldCache.folded[text] {
            foldCache.lock.unlock()
            return hit
        }
        foldCache.lock.unlock()
        let result = fold(text)
        foldCache.lock.lock()
        if foldCache.folded.count >= foldCacheLimit { foldCache.folded.removeAll(keepingCapacity: true) }
        foldCache.folded[text] = result
        foldCache.lock.unlock()
        return result
    }

    public static func normalizeQuery(_ query: String) -> String { fold(JSText.trim(query)) }

    /// True when search or any filter hides part of the collection.
    public static func isFiltering(_ view: ViewState) -> Bool {
        !normalizeQuery(view.query).isEmpty || !view.statuses.isEmpty || !view.priorities.isEmpty || !view.labels.isEmpty || !view.due.isEmpty
    }

    /// Reordering is only safe on the complete board in manual order.
    public static func isDragAllowed(_ view: ViewState) -> Bool {
        !isFiltering(view) && view.sort == .manual
    }

    public static func matches(_ task: TaskItem, _ view: ViewState, todayKey: String) -> Bool {
        Matcher(view, todayKey: todayKey).matches(task)
    }

    /// Search and filters prepared once for a whole collection (the query is folded once, not
    /// once per task).
    struct Matcher {
        let view: ViewState
        let todayKey: String
        let query: String
        let labels: [String]
        /// No search or filter: every task matches.
        let all: Bool

        init(_ view: ViewState, todayKey: String) {
            self.view = view
            self.todayKey = todayKey
            query = normalizeQuery(view.query)
            labels = view.labels.map(JSText.lower)
            all = query.isEmpty && view.statuses.isEmpty && view.priorities.isEmpty && view.labels.isEmpty && view.due.isEmpty
        }

        func matches(_ task: TaskItem) -> Bool {
            if all { return true }
            if !query.isEmpty && !JSText.includes(cachedFold(task.title), query) && !JSText.includes(cachedFold(task.description), query) { return false }
            if !view.statuses.isEmpty && !view.statuses.contains(task.status) { return false }
            if !view.priorities.isEmpty && !view.priorities.contains(task.priority) { return false }
            if !labels.isEmpty {
                let taskLabels = Set(task.labels.map(JSText.lower))
                if !labels.contains(where: taskLabels.contains) { return false }
            }
            if !view.due.isEmpty && !view.due.contains(where: { DueDates.matches(task, filter: $0, todayKey: todayKey) }) { return false }
            return true
        }
    }

    /// Tasks matching search and filters, in their current order.
    public static func filtered(_ tasks: [TaskItem], _ view: ViewState, todayKey: String) -> [TaskItem] {
        let matcher = Matcher(view, todayKey: todayKey)
        return matcher.all ? tasks : tasks.filter(matcher.matches)
    }

    static let priorityRank: [Priority: Int] = [.high: 0, .medium: 1, .low: 2]

    /// Compares only the sort key of a mode (0 on ties; always 0 for manual).
    static func primary(_ sort: SortMode, locale: Locale) -> (TaskItem, TaskItem) -> Int {
        switch sort {
        case .dueDate:
            // Earliest first; tasks without a due date go last. On the same date (iPhone addition)
            // tasks with a due time come first, in time order; "some time that day" follows.
            return { a, b in
                if a.dueDate == b.dueDate {
                    guard a.dueDate != nil, a.dueTime != b.dueTime else { return 0 }
                    guard let left = a.dueTime else { return 1 }
                    guard let right = b.dueTime else { return -1 }
                    return left < right ? -1 : 1
                }
                guard let left = a.dueDate else { return 1 }
                guard let right = b.dueDate else { return -1 }
                return left < right ? -1 : 1
            }
        case .priority:
            return { a, b in priorityRank[a.priority]! - priorityRank[b.priority]! }
        case .title:
            return { a, b in
                switch a.title.compare(b.title, options: [.caseInsensitive, .diacriticInsensitive, .numeric, .widthInsensitive], range: nil, locale: locale) {
                case .orderedAscending: return -1
                case .orderedDescending: return 1
                case .orderedSame: return 0
                }
            }
        case .manual:
            return { _, _ in 0 }
        }
    }

    /// Comparator for a sort mode. Ties always fall back to the manual order.
    public static func comparator(_ sort: SortMode, locale: Locale) -> (TaskItem, TaskItem) -> Bool {
        let first = primary(sort, locale: locale)
        return { a, b in
            let result = first(a, b)
            if result != 0 { return result < 0 }
            return Tasks.compare(a, b)
        }
    }

    /// Sorts by a mode with the same result as `primary`, then status (To Do, In Progress, Done),
    /// then manual order. The due date and time are turned into numbers once per task instead of
    /// being compared as text in every comparison.
    static func sorted(_ tasks: [TaskItem], by sort: SortMode, locale: Locale) -> [TaskItem] {
        // Small key records are sorted instead of the tasks themselves: comparing whole tasks
        // copied (and retained) every field of both tasks in each of the n·log n comparisons.
        struct Entry {
            let index: Int
            let due: Int
            let time: Int
            let priority: Int
            let rank: Int
            let order: Double
        }
        let entries = tasks.indices.map { index in
            let task = tasks[index]
            return Entry(
                index: index, due: sort == .dueDate ? dayNumber(task.dueDate) : 0, time: sort == .dueDate ? minuteNumber(task.dueTime) : 0,
                priority: priorityRank[task.priority]!, rank: statusRank(task.status), order: task.order
            )
        }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .numeric, .widthInsensitive]
        return entries.sorted { a, b in
            switch sort {
            case .dueDate:
                if a.due != b.due { return a.due < b.due }
                // Same date: timed tasks first, by time ("some time that day" after them).
                if a.due != Int.max, a.time != b.time { return a.time < b.time }
            case .priority:
                if a.priority != b.priority { return a.priority < b.priority }
            case .title:
                switch tasks[a.index].title.compare(tasks[b.index].title, options: options, range: nil, locale: locale) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: break
                }
            case .manual:
                break
            }
            if a.rank != b.rank { return a.rank < b.rank }
            // Tasks.compare: order, then creation time, then id.
            if a.order != b.order { return a.order < b.order }
            return Tasks.compare(tasks[a.index], tasks[b.index])
        }.map { tasks[$0.index] }
    }

    /// "2026-11-04" as 20261104 (the same order as the text); no due date sorts last.
    static func dayNumber(_ key: String?) -> Int {
        guard let (year, month, day) = Schedule.dateParts(key) else { return Int.max }
        return year * 10_000 + month * 100 + day
    }

    /// "16:30" as 990 minutes; no time sorts after any time.
    static func minuteNumber(_ key: String?) -> Int {
        guard let key, Schedule.isTimeKey(key) else { return Int.max }
        let (hours, minutes) = Schedule.timeParts(key)
        return hours * 60 + minutes
    }

    static func statusRank(_ status: TaskStatus) -> Int {
        switch status {
        case .todo: return 0
        case .inProgress: return 1
        case .done: return 2
        }
    }

    /// Visible tasks per column plus totals.
    public static func board(_ tasks: [TaskItem], _ view: ViewState, locale: Locale, todayKey: String) -> BoardView {
        var columns: [TaskStatus: [TaskItem]] = [:]
        var totals: [TaskStatus: Int] = [:]
        var shown = 0
        for status in TaskModel.statuses {
            let inColumn = tasks.filter { $0.status == status }
            totals[status] = inColumn.count
            columns[status] = sorted(filtered(inColumn, view, todayKey: todayKey), by: view.sort, locale: locale)
            shown += columns[status]!.count
        }
        return BoardView(columns: columns, totals: totals, shown: shown, total: tasks.count)
    }

    /// Flat list: manual order groups by status (To Do, In Progress, Done) then manual position;
    /// other sorts apply across all statuses.
    public static func list(_ tasks: [TaskItem], _ view: ViewState, locale: Locale, todayKey: String) -> [TaskItem] {
        sorted(filtered(tasks, view, todayKey: todayKey), by: view.sort, locale: locale)
    }

    // MARK: Category scope

    /// Tasks belonging to a sidebar destination.
    public static func scope(_ tasks: [TaskItem], _ destination: Destination) -> [TaskItem] {
        switch destination {
        case .all: return tasks
        case .uncategorized: return tasks.filter { $0.categoryId == nil }
        case .category(let id): return tasks.filter { $0.categoryId == id }
        }
    }

    /// Task counts per destination for the sidebar.
    public static func countByCategory(_ tasks: [TaskItem]) -> [Destination: Int] {
        var counts: [Destination: Int] = [.all: tasks.count, .uncategorized: 0]
        for task in tasks {
            let key: Destination = task.categoryId.map(Destination.category) ?? .uncategorized
            counts[key, default: 0] += 1
        }
        return counts
    }

    /// Converts a drop position within a scoped (category) column into the index within the full
    /// column, so tasks hidden by the scope keep their relative order. `visibleIds` is the visible
    /// column before the move.
    public static func toFullColumnIndex(fullIds: [String], visibleIds: [String], taskId: String, visibleIndex: Int) -> Int {
        var visible = visibleIds.filter { $0 != taskId }
        let full = fullIds.filter { $0 != taskId }
        visible.insert(taskId, at: max(0, min(visibleIndex, visible.count)))
        let next = visibleIndex + 1 < visible.count ? visible[visibleIndex + 1] : nil
        let previous = visibleIndex - 1 >= 0 && visibleIndex - 1 < visible.count ? visible[visibleIndex - 1] : nil
        if let next, let index = full.firstIndex(of: next) { return index }
        if let previous, let index = full.firstIndex(of: previous) { return index + 1 }
        return full.count
    }

    /// Statistics over the whole collection (each task id counted once).
    public static func stats(_ tasks: [TaskItem], now: Date = Date(), timeZone: TimeZone = .current) -> TaskStats {
        let today = DueDates.Today(now: now, timeZone: timeZone)
        var seen = Set<String>()
        var done = 0
        var overdue = 0
        for task in tasks where !seen.contains(task.id) {
            seen.insert(task.id)
            if task.status == .done {
                done += 1
            } else if DueDates.dueState(task, today: today) == .overdue {
                overdue += 1
            }
        }
        let total = seen.count
        let percent = total > 0 ? Int((Double(done) / Double(total) * 100).rounded()) : nil
        return TaskStats(total: total, done: done, overdue: overdue, percent: percent)
    }

    // MARK: Sections (iPhone list)

    public enum Section: String, CaseIterable, Sendable {
        case overdue, today, future, noDate, done
    }

    /// The List view in sections, as in Todoery: overdue, today, the future, tasks without a due
    /// date, and completed tasks at the bottom (most recently completed first). Within a section the
    /// tasks keep the active sort (`list`). Empty sections are left out.
    public static func sections(_ tasks: [TaskItem], _ view: ViewState, locale: Locale, now: Date = Date(), timeZone: TimeZone = .current) -> [(section: Section, tasks: [TaskItem])] {
        let today = DueDates.Today(now: now, timeZone: timeZone)
        var groups: [Section: [TaskItem]] = [:]
        for task in list(tasks, view, locale: locale, todayKey: today.key) {
            let section: Section
            if task.status == .done {
                section = .done
            } else {
                switch DueDates.dueState(task, today: today) {
                case .overdue: section = .overdue
                case .today: section = .today
                case .none: section = .noDate
                default: section = .future
                }
            }
            groups[section, default: []].append(task)
        }
        if let done = groups[.done] {
            // Stable: equal completion times keep the list order.
            groups[.done] = done.enumerated().sorted { lhs, rhs in
                let left = lhs.element.completedAt ?? "", right = rhs.element.completedAt ?? ""
                return left != right ? left > right : lhs.offset < rhs.offset
            }.map(\.element)
        }
        return Section.allCases.compactMap { section in groups[section].map { (section, $0) } }
    }

    /// Completed tasks per day for the last `days` days (oldest first), from completedAt. A repeating
    /// task keeps only its last completion, so it counts once.
    public static func completionsByDay(_ tasks: [TaskItem], days: Int = 7, now: Date = Date(), timeZone: TimeZone = .current) -> [(dateKey: String, count: Int)] {
        let todayKey = Schedule.localDateKey(now, timeZone: timeZone)
        let keys = (0..<days).reversed().map { Schedule.addDaysToKey(todayKey, -$0) }
        var counts: [String: Int] = [:]
        for task in tasks {
            guard let completed = ISOTime.date(task.completedAt) else { continue }
            counts[Schedule.localDateKey(completed, timeZone: timeZone), default: 0] += 1
        }
        return keys.map { ($0, counts[$0] ?? 0) }
    }

    /// Open and completed tasks per due date, for the calendar.
    public static func tasksByDate(_ tasks: [TaskItem]) -> [String: [TaskItem]] {
        var result: [String: [TaskItem]] = [:]
        for task in tasks { if let due = task.dueDate { result[due, default: []].append(task) } }
        return result.mapValues { $0.sorted(by: comparator(.dueDate, locale: Locale(identifier: "en_US"))) }
    }
}
