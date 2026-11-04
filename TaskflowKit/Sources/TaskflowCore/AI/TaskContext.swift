// Chooses the existing tasks a message is about, so the assistant sees only what it needs (never
// the whole task list) - a port of electron/ai/taskContext.cjs: tasks of this assistant session
// (follow-ups), tasks whose title shares words with the message, and - when the message asks about
// them - overdue / due soon tasks, tasks of a mentioned category, status or priority, or open tasks
// for a day plan. Subtasks only for tasks the message names or the session worked with. Never
// descriptions.
import Foundation

public struct ContextTask: Equatable, Sendable {
    public var task: TaskItem
    /// Whether subtasks (with ids) are included.
    public var detail: Bool
}

public enum TaskContext {
    public static let maxContextTasks = 40
    static let minToken = 3
    static let maxTags = 50

    // Words that say what to do rather than which task (RU/EN). They must not pull in unrelated tasks.
    static let stopWords: Set<String> = Set([
        // English
        "the", "and", "for", "with", "task", "tasks", "todo", "mark", "set", "make", "move", "change", "done", "finished", "complete",
        "completed", "progress", "start", "started", "due", "date", "deadline", "today", "tomorrow", "yesterday", "week", "next", "this",
        "that", "please", "remove", "clear", "from", "into", "it", "its", "my", "all", "reopen", "monday", "tuesday", "wednesday",
        "thursday", "friday", "saturday", "sunday", "create", "add", "new", "delete", "rename", "time", "remind", "every",
        // Russian
        "задача", "задачи", "задачу", "задаче", "задач", "отметь", "отметить", "сделай", "сделать", "перенеси", "перенести", "поставь",
        "поставить", "измени", "изменить", "готово", "готова", "готов", "выполнено", "выполнена", "выполни", "работе", "работу",
        "срок", "сроком", "дедлайн", "сегодня", "завтра", "вчера", "послезавтра", "неделю", "неделе", "следующую", "следующий",
        "эту", "это", "этот", "эта", "её", "ее", "его", "мою", "мой", "все", "всё", "убери", "убрать", "сними", "снять", "пожалуйста",
        "понедельник", "вторник", "среду", "среда", "четверг", "пятницу", "пятница", "субботу", "суббота", "воскресенье", "создай",
        "создать", "добавь", "добавить", "новую", "начни", "начать", "верни", "вернуть", "как", "для", "что", "про", "удали", "удалить",
        "переименуй", "время", "напомни", "каждый", "каждую", "каждое",
    ].map { $0.replacingOccurrences(of: "ё", with: "е") })

    // Words that ask for a group of tasks rather than naming one (folded text).
    static let intents: [(String, NSRegularExpression)] = [
        ("overdue", "просроч|опозд|overdue|late|missed"),
        ("today", "сегодн|today|tonight"),
        ("soon", "завтра|tomorrow|недел|week|скоро|soon|ближайш|upcoming|дедлайн|deadline|срок"),
        ("plan", "план|расписан|schedule|plan|agenda|мой день|my day"),
        // Completed tasks as a group ("выполненные", "completed tasks") - not "X is done", which names one task.
        ("done", "выполненн|завершенн|сделанн|completed tasks|finished tasks|done tasks|what (have|did) i (do|done|finish|complete)"),
        ("inProgress", "в работе|in progress|начат"),
        ("high", "важн|срочн|приоритет|urgent|important|priority"),
    ].map { ($0.0, try! NSRegularExpression(pattern: $0.1)) }

    static func fold(_ text: String) -> String {
        JSText.lower(text).replacingOccurrences(of: "ё", with: "е")
    }

    /// Words of 3+ letters/digits that are not stop words (folded).
    public static func tokens(_ text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for scalar in fold(text).unicodeScalars {
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) || scalar.properties.numericType != nil {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words.filter { JSText.length($0) >= minToken && !stopWords.contains($0) }
    }

    /// Same word or same stem: the shorter word without its ending starts the longer one. The ending
    /// is one letter, or two for words of 6+ letters (Russian case endings).
    public static func wordsMatch(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        if short.count < 4 { return false }
        let ending = short.count >= 6 ? 2 : 1
        return long.hasPrefix(String(short.prefix(max(3, short.count - ending))))
    }

    static func isOverdue(_ task: TaskItem, todayKey: String, nowTime: String) -> Bool {
        guard task.status != .done, let due = task.dueDate else { return false }
        return due < todayKey || (due == todayKey && task.dueTime != nil && task.dueTime! <= nowTime)
    }

    /// Counts for the summary line.
    public static func summary(_ tasks: [TaskItem], todayKey: String, nowTime: String = "00:00") -> Prompt.Summary {
        Prompt.Summary(
            total: tasks.count,
            todo: tasks.filter { $0.status == .todo }.count,
            inProgress: tasks.filter { $0.status == .inProgress }.count,
            done: tasks.filter { $0.status == .done }.count,
            overdue: tasks.filter { isOverdue($0, todayKey: todayKey, nowTime: nowTime) }.count,
            dueToday: tasks.filter { $0.status != .done && $0.dueDate == todayKey }.count
        )
    }

    /// `pinnedIds`: tasks of this assistant session (kept first). Returns at most maxContextTasks.
    public static func select(message: String, tasks: [TaskItem], pinnedIds: [String] = [], categories: [(id: String, name: String)] = [], todayKey: String?, nowTime: String = "00:00") -> [ContextTask] {
        let byId = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var chosen: [ContextTask] = []
        var chosenIds = Set<String>()
        func add(_ task: TaskItem, _ detail: Bool) {
            if chosenIds.contains(task.id) || chosen.count >= maxContextTasks { return }
            chosenIds.insert(task.id)
            chosen.append(ContextTask(task: task, detail: detail))
        }
        for id in pinnedIds { if let task = byId[id] { add(task, true) } }

        let words = tokens(message)
        if !words.isEmpty {
            let scored = tasks.filter { !chosenIds.contains($0.id) }.enumerated().compactMap { offset, task -> (Int, Int, TaskItem)? in
                let titleWords = tokens(task.title)
                let score = words.filter { word in titleWords.contains { wordsMatch(word, $0) } }.count
                return score > 0 ? (score, offset, task) : nil
            }
            // Stable: equal scores keep the task order.
            for (_, _, task) in scored.sorted(by: { $0.0 != $1.0 ? $0.0 > $1.0 : $0.1 < $1.1 }) { add(task, true) }
        }

        // Group requests: the tasks the question or plan is about (without subtasks).
        let text = fold(message)
        let range = NSRange(text.startIndex..., in: text)
        let found = Set(intents.filter { $0.1.firstMatch(in: text, range: range) != nil }.map(\.0))
        let open = tasks.filter { $0.status != .done }
        let byDue: (TaskItem, TaskItem) -> Bool = { a, b in
            let left = a.dueDate ?? "9999", right = b.dueDate ?? "9999"
            if left != right { return left < right }
            return (a.dueTime ?? "") < (b.dueTime ?? "")
        }
        func stableSorted(_ list: [TaskItem]) -> [TaskItem] {
            list.enumerated().sorted { byDue($0.element, $1.element) || (!byDue($1.element, $0.element) && $0.offset < $1.offset) }.map(\.element)
        }
        if let todayKey {
            if found.contains("overdue") || found.contains("plan") {
                stableSorted(open.filter { isOverdue($0, todayKey: todayKey, nowTime: nowTime) }).forEach { add($0, false) }
            }
            if found.contains("today") || found.contains("plan") {
                stableSorted(open.filter { $0.dueDate == todayKey }).forEach { add($0, false) }
            }
            if found.contains("soon") || found.contains("plan") {
                let weekEnd = Schedule.addDaysToKey(todayKey, 7)
                stableSorted(open.filter { task in task.dueDate.map { $0 >= todayKey && $0 <= weekEnd } ?? false }).forEach { add($0, false) }
            }
        }
        if found.contains("plan") || found.contains("high") {
            stableSorted(open.filter { $0.priority == .high }).forEach { add($0, false) }
        }
        if found.contains("done") { tasks.filter { $0.status == .done }.forEach { add($0, false) } }
        if found.contains("inProgress") { tasks.filter { $0.status == .inProgress }.forEach { add($0, false) } }
        // Tasks with a tag the message names.
        let namesTag = { (label: String) -> Bool in
            let tagWords = tokens(label)
            return !tagWords.isEmpty && tagWords.allSatisfy { tag in words.contains { wordsMatch($0, tag) } }
        }
        tasks.filter { $0.labels.contains(where: namesTag) }.forEach { add($0, false) }
        for category in categories {
            let nameWords = tokens(category.name)
            if !nameWords.isEmpty && nameWords.allSatisfy({ name in words.contains { wordsMatch($0, name) } }) {
                stableSorted(tasks.filter { $0.categoryId == category.id }).forEach { add($0, false) }
            }
        }
        return chosen
    }

    /// Existing tags (case-insensitive) with how many tasks carry each, most used first.
    public static func tagSummary(_ tasks: [TaskItem]) -> [Prompt.Tag] {
        var counts: [String: Prompt.Tag] = [:]
        for task in tasks {
            for label in task.labels {
                let key = JSText.lower(label)
                counts[key, default: Prompt.Tag(name: label, count: 0)].count += 1
            }
        }
        return Array(counts.values.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name.localizedCompare($1.name) == .orderedAscending }.prefix(maxTags))
    }
}
