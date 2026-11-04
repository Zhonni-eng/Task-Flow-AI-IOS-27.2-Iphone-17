// Human-readable texts derived from data - ports of src/data/scheduleText.js, the texts of
// DueDate.jsx / PlannedSlot.jsx, the review texts of AiPanel.jsx (describeEntry, resultText) and
// the demo tasks of src/data/sampleTasks.js.
import Foundation

public enum ScheduleText {
    /// "At the due time" / "30 min before" / "1 day before" ... for a reminder offset.
    public static func reminderLabel(_ l: L10n, offset: Int, timed: Bool) -> String {
        let day = Schedule.dayMinutes
        if offset == 0 { return l.t(timed ? "schedule.reminderAtTime" : "schedule.reminderOnDay") }
        if offset % (7 * day) == 0 { return l.t("schedule.reminderWeeks", ["count": offset / (7 * day)]) }
        if offset % day == 0 { return l.t("schedule.reminderDays", ["count": offset / day]) }
        if offset % 60 == 0 { return l.t("schedule.reminderHours", ["count": offset / 60]) }
        return l.t("schedule.reminderMinutes", ["count": offset])
    }

    /// "Every week on Mon, Thu" / "Every 2 days" / "Monthly on day 1" ...
    public static func recurrenceLabel(_ l: L10n, _ rule: Recurrence?) -> String {
        guard let rule else { return "" }
        let every = rule.interval > 1 ? l.t("schedule.every.\(rule.freq.rawValue)N", ["count": rule.interval]) : l.t("schedule.every.\(rule.freq.rawValue)")
        switch rule.freq {
        case .weekly:
            let days = [1, 2, 3, 4, 5, 6, 0].filter { rule.weekdays?.contains($0) ?? false }.map { l.t("schedule.weekdays.\($0)") }
            return l.t("schedule.onDays", ["rule": every, "days": days.joined(separator: ", ")])
        case .monthly:
            return l.t("schedule.onMonthDay", ["rule": every, "day": rule.monthDay ?? 1])
        case .daily:
            return every
        }
    }

    public static func remindersText(_ l: L10n, _ reminders: [Int], timed: Bool) -> String {
        reminders.map { reminderLabel(l, offset: $0, timed: timed).lowercased(with: l.locale) }.joined(separator: ", ")
    }
}

public struct DueText: Equatable, Sendable {
    public var state: DueState
    /// The visible text ("Сегодня, 16:30", "Просрочено · 30 окт.").
    public var text: String
    /// The full description for accessibility.
    public var description: String
    public var repeats: String?
    public var reminders: String?

    /// Due date of a task with its state. Overdue and due-today dates differ by icon and wording,
    /// not only by color; completed tasks are never shown as overdue. `list` adds the year.
    public static func make(_ task: TaskItem, l: L10n, list: Bool = false, now: Date = Date(), timeZone: TimeZone = .current) -> DueText? {
        guard let dueDate = task.dueDate, Schedule.isDateKey(dueDate) else { return nil }
        let state = DueDates.dueState(task, now: now, timeZone: timeZone)
        let date = l.formatDate(dueDate, list ? .shortWithYear : .short)
        let withTime = { (text: String) in task.dueTime.map { l.t("task.dateTime", ["date": text, "time": $0]) } ?? text }
        let formatted = withTime(date)
        let text: String
        let description: String
        switch state {
        case .overdue:
            text = list ? formatted : "\(l.t("task.overdue")) · \(formatted)"
            description = l.t("task.dueOverdue", ["date": formatted])
        case .today:
            text = withTime(l.t("task.dueToday"))
            description = l.t("task.dueTodayFull", ["date": formatted])
        case .tomorrow:
            text = withTime(l.t("task.dueTomorrow"))
            description = l.t("task.dueTomorrowFull", ["date": formatted])
        default:
            text = formatted
            description = l.t("task.due", ["date": formatted])
        }
        let repeats = task.recurrence.map { l.t("task.repeats", ["rule": ScheduleText.recurrenceLabel(l, $0)]) }
        let reminders = task.reminders.isEmpty ? nil : l.t("task.hasReminders", ["list": ScheduleText.remindersText(l, task.reminders, timed: task.dueTime != nil)])
        return DueText(state: state, text: text, description: description, repeats: repeats, reminders: reminders)
    }

    /// An accepted day-plan slot ("Planned: 22 Oct, 10:00") - a plan, not a deadline.
    public static func planned(_ task: TaskItem, l: L10n) -> String? {
        guard let planned = task.planned, Schedule.isDateKey(planned.date), task.status != .done else { return nil }
        return l.t("task.planned", ["date": l.formatDate(planned.date), "time": planned.time])
    }
}

// MARK: - Assistant review texts

public struct ReviewText: Equatable, Sendable {
    public var kind: String
    public var title: String
    public var details: [String]
    public var list: [String]
    public var notes: [String]
}

public enum ReviewTexts {
    static let maxListed = 10
    static let warningNotes: [(String, String)] = [
        ("possibleDuplicate", "assistant.duplicate"),
        ("duplicateInPlan", "assistant.duplicateInPlan"),
        ("noChange", "assistant.noChange"),
        ("advancesRecurrence", "assistant.advancesRecurrence"),
        ("deletesSeries", "assistant.deletesSeries"),
        ("noMatches", "assistant.noMatches"),
        ("noEstimate", "assistant.noEstimate"),
        ("afterDeadline", "assistant.afterDeadline"),
        ("timeKeepsDates", "assistant.timeKeepsDates"),
        ("labelLimit", "assistant.labelLimit"),
    ]
    public static let knownErrors: Set<String> = ["AI_DISABLED", "NO_KEY", "AUTH", "PERMISSION", "RATE_LIMIT", "TIMEOUT", "NETWORK", "OVERLOADED", "MODEL_UNAVAILABLE", "REFUSED", "TRUNCATED", "MALFORMED", "CONVERSATION_LIMIT", "INVALID_MESSAGE", "BUSY", "UNAVAILABLE"]

    public static func errorText(_ l: L10n, code: String) -> String {
        l.t("assistant.errors.\(knownErrors.contains(code) ? code : "generic")")
    }

    /// Texts for one review item.
    public static func describe(_ l: L10n, item: ProposalItem, categories: [TaskCategory]) -> ReviewText {
        let entry = item.entry
        let raw = item.raw
        func shortDate(_ key: String?) -> String {
            guard let key, Schedule.isDateKey(key) else { return l.t("assistant.noDueDate") }
            return l.formatDate(key, .weekdayLong)
        }
        func categoryName(_ id: String?) -> String {
            guard let id else { return l.t("assistant.field.noCategory") }
            return categories.first { $0.id == id }?.name ?? "?"
        }
        func categoryText(_ id: String?, _ newName: String?) -> String {
            newName.map { l.t("assistant.field.newCategory", ["name": $0]) } ?? categoryName(id)
        }
        func remindersText(_ list: [Int], timed: Bool) -> String {
            list.isEmpty ? l.t("assistant.field.none") : ScheduleText.remindersText(l, list, timed: timed)
        }
        func estimateText(_ minutes: Int?) -> String {
            minutes.map { l.t("task.estimate", ["count": $0]) } ?? l.t("assistant.field.none")
        }
        func labelText(_ labels: [String]) -> String { labels.isEmpty ? l.t("assistant.field.none") : labels.joined(separator: ", ") }
        var details: [String] = []
        var list: [String] = []
        var notes: [String] = []
        func listTasks(_ matched: [TaskItem]) {
            list += matched.prefix(maxListed).map { task in task.dueDate.map { "\(task.title) (\(shortDate($0)))" } ?? task.title }
            if matched.count > maxListed { list.append(l.t("assistant.bulkMore", ["count": matched.count - maxListed])) }
        }
        let target = entry.target
        var kind = l.t("assistant.kind.\(entry.type == "create" ? "create" : "unknown")")
        var title = entry.type == "create" ? (raw["title"]?.stringValue ?? l.t("assistant.untitled")) : (target?.title ?? l.t("assistant.unknownTask"))

        /// One line per changed field ("Срок: 23 окт. → 25 окт.").
        func changeLines(_ changes: [String: JSONValue], _ newCategory: String?, _ before: TaskItem?) -> [String] {
            var lines: [String] = []
            if let value = changes["title"]?.stringValue { lines.append(l.t("assistant.field.title", ["from": before?.title ?? "", "to": value])) }
            if let value = changes["status"]?.stringValue {
                lines.append(l.t("assistant.statusChange", ["from": before.map { l.t("columns.\($0.status.rawValue)") } ?? "?", "to": l.t("columns.\(value)")]))
            }
            if let value = changes["dueDate"] { lines.append(l.t("assistant.dueChange", ["from": shortDate(before?.dueDate), "to": shortDate(value.stringValue)])) }
            if let value = changes["dueTime"] {
                lines.append(l.t("assistant.field.time", ["from": before?.dueTime ?? l.t("assistant.field.none"), "to": value.stringValue ?? l.t("assistant.field.none")]))
            }
            if let value = changes["priority"]?.stringValue {
                lines.append(l.t("assistant.field.priority", ["from": before.map { l.t("priority.\($0.priority.rawValue)") } ?? "?", "to": l.t("priority.\(value)")]))
            }
            if changes["categoryId"] != nil || newCategory != nil {
                lines.append(l.t("assistant.field.category", ["from": categoryName(before?.categoryId), "to": categoryText(changes["categoryId"]?.stringValue, newCategory)]))
            }
            if let value = changes["description"] {
                let text = value.stringValue ?? ""
                lines.append(text.isEmpty ? l.t("assistant.field.descriptionCleared") : l.t("assistant.field.description", ["to": text]))
            }
            if let value = changes["reminders"] {
                let timed = changes["dueTime"]?.stringValue != nil || (changes["dueTime"] == nil && before?.dueTime != nil)
                lines.append(l.t("assistant.field.reminders", ["to": remindersText(value.arrayValue?.compactMap(\.intValue) ?? [], timed: timed)]))
            }
            if let value = changes["recurrence"] {
                let rule = value == .null ? nil : Schedule.normalizeRecurrence(value, dueDate: changes["dueDate"]?.stringValue ?? before?.dueDate ?? "2000-01-03")
                lines.append(l.t("assistant.field.recurrence", ["to": rule.map { ScheduleText.recurrenceLabel(l, $0) } ?? l.t("schedule.noRepeat")]))
            }
            if let value = changes["estimateMinutes"] { lines.append(l.t("assistant.field.estimate", ["to": estimateText(value.intValue)])) }
            if changes["planned"] != nil { lines.append(l.t("assistant.field.planned")) }
            let added = ActionPlan.strings(changes["addLabels"])
            let removed = ActionPlan.strings(changes["removeLabels"])
            if let before, changes["addLabels"] != nil || changes["removeLabels"] != nil {
                lines.append(l.t("assistant.field.labels", ["from": labelText(before.labels), "to": labelText(ActionPlan.editLabels(before.labels, added: added, removed: removed))]))
            } else {
                if changes["addLabels"] != nil { lines.append(l.t("assistant.field.addLabels", ["list": added.joined(separator: ", ")])) }
                if changes["removeLabels"] != nil { lines.append(l.t("assistant.field.removeLabels", ["list": removed.joined(separator: ", ")])) }
            }
            return lines
        }

        switch entry.type {
        case "create":
            let fields = entry.reviewChanges
            if let name = fields?["title"]?.stringValue, !name.isEmpty { title = name }
            // Date, priority, status and category on one line ("Срок: чт, 22 октября · Высокий · Дом").
            var head: [String] = []
            if let due = fields?["dueDate"]?.stringValue {
                let date = fields?["dueTime"]?.stringValue.map { l.t("task.dateTime", ["date": shortDate(due), "time": $0]) } ?? shortDate(due)
                head.append(l.t("assistant.due", ["date": date]))
            }
            if let priority = fields?["priority"]?.stringValue, priority != "medium" { head.append(l.t("priority.\(priority)")) }
            if let status = fields?["status"]?.stringValue, status != "todo" { head.append(l.t("columns.\(status)")) }
            if let newCategory = entry.newCategory { head.append(l.t("assistant.field.newCategory", ["name": newCategory])) } else if let category = fields?["categoryId"]?.stringValue { head.append(categoryName(category)) }
            if !head.isEmpty { details.append(head.joined(separator: " · ")) }
            if let rule = fields?["recurrence"], rule != .null, let due = fields?["dueDate"]?.stringValue, let parsed = Schedule.normalizeRecurrence(rule, dueDate: due) {
                details.append(l.t("task.repeats", ["rule": ScheduleText.recurrenceLabel(l, parsed)]))
            }
            if let reminders = fields?["reminders"]?.arrayValue?.compactMap(\.intValue), !reminders.isEmpty {
                details.append(l.t("task.hasReminders", ["list": remindersText(reminders, timed: fields?["dueTime"]?.stringValue != nil)]))
            }
            if let estimate = fields?["estimateMinutes"]?.intValue { details.append(estimateText(estimate)) }
            if let description = fields?["description"]?.stringValue, !description.isEmpty { details.append(l.t("assistant.field.description", ["to": description])) }
            let subtasks = ActionPlan.strings(fields?["subtasks"])
            if !subtasks.isEmpty { details.append(l.t("assistant.subtasks", ["list": subtasks.joined(separator: ", ")])) }
            let labels = ActionPlan.strings(fields?["labels"])
            if !labels.isEmpty { details.append(l.t("assistant.field.newLabels", ["list": labels.joined(separator: ", ")])) }
        case "update":
            let changes = entry.reviewChanges ?? raw["changes"]?.objectValue ?? [:]
            let keys = Array(changes.keys)
            kind = keys == ["status"] ? l.t("assistant.kind.setStatus") : keys == ["dueDate"] ? l.t("assistant.kind.setDueDate") : l.t("assistant.kindMore.update")
            if entry.valid { details += changeLines(changes, entry.newCategory, target) }
        case "delete":
            kind = l.t("assistant.kindMore.delete")
            details.append(l.t("assistant.deleteTask"))
            if let count = target?.subtasks.count, count > 0 { details.append(l.t("assistant.deletesSubtasks", ["count": count])) }
        case "addSubtask":
            kind = l.t("assistant.kindMore.addSubtask")
            var subtaskTitle = raw["title"]?.stringValue ?? ""
            if case .addSubtask(_, let normalizedTitle)? = entry.normalized { subtaskTitle = normalizedTitle }
            details.append(l.t("assistant.subtaskAdd", ["title": subtaskTitle]))
        case "updateSubtask":
            kind = l.t("assistant.kindMore.updateSubtask")
            var parts: [String] = []
            if case .updateSubtask(_, _, let newTitle, let done)? = entry.normalized {
                if let done { parts.append(l.t(done ? "assistant.subtaskDone" : "assistant.subtaskOpen")) }
                if let newTitle { parts.append(l.t("assistant.subtaskRename", ["title": newTitle])) }
            }
            details.append("«\(entry.subtask?.title ?? "?")»: \(parts.joined(separator: ", "))")
        case "deleteSubtask":
            kind = l.t("assistant.kindMore.deleteSubtask")
            details.append(l.t("assistant.subtaskDelete", ["title": entry.subtask?.title ?? "?"]))
        case "moveSubtask":
            kind = l.t("assistant.kindMore.moveSubtask")
            details.append(l.t("assistant.subtaskMove", ["title": entry.subtask?.title ?? "?", "to": entry.destination?.title ?? "?"]))
        case "bulk":
            let delete = raw["operation"] == "delete"
            kind = l.t(delete ? "assistant.kindMore.bulkDelete" : "assistant.kindMore.bulk")
            let matched = entry.matchedTasks ?? []
            // An invalid bulk change resolved no tasks: never present that as "affects 0 tasks".
            title = entry.valid ? l.t("assistant.bulkCount", ["count": matched.count]) : l.t("assistant.bulkUnresolved")
            if case .bulk(_, let filter, let changes, let newCategory, _)? = entry.normalized {
                if filter.scope == "all" { details.append(l.t("assistant.bulkAll")) }
                if !delete {
                    details += changeLines(changes, newCategory, nil).map { line in
                        // "Field: from → to" without the unknown "from" part.
                        guard let colon = line.range(of: ": "), let arrow = line.range(of: "→ ", range: colon.upperBound..<line.endIndex),
                              !line[colon.upperBound..<arrow.lowerBound].contains("→") else { return line }
                        return String(line[..<colon.upperBound]) + String(line[arrow.upperBound...])
                    }
                }
            }
            if delete { details.append(l.t("assistant.bulkDeleteNote")) }
            listTasks(matched)
        case "renameLabel", "deleteLabel":
            // A tag exists only on tasks: renaming or deleting it changes every task that has it.
            let rename = entry.type == "renameLabel"
            var label = raw["label"]?.stringValue ?? ""
            var newLabel = raw["newLabel"]?.stringValue ?? ""
            if case .renameLabel(let from, let to, _)? = entry.normalized {
                label = from
                newLabel = to
            }
            if case .deleteLabel(let name, _)? = entry.normalized { label = name }
            kind = l.t(rename ? "assistant.kindMore.renameLabel" : "assistant.kindMore.deleteLabel")
            title = rename ? l.t("assistant.labelRename", ["from": label, "to": newLabel]) : l.t("assistant.labelName", ["label": label])
            details.append(l.t(rename ? "assistant.labelRenameNote" : "assistant.labelDeleteNote"))
            let matched = entry.matchedTasks ?? []
            if !matched.isEmpty { details.append(l.t("assistant.bulkCount", ["count": matched.count])) }
            listTasks(matched)
        case "schedule":
            kind = l.t("assistant.kindMore.schedule")
            var date = raw["date"]?.stringValue
            var items: [ScheduleItem] = []
            if case .schedule(let planDate, let planItems)? = entry.normalized {
                date = planDate
                items = planItems
            }
            title = l.t("assistant.scheduleFor", ["date": shortDate(date)])
            for item in items {
                if let end = item.endMin {
                    let endText = "\(Schedule.pad((end / 60) % 24)):\(Schedule.pad(end % 60))"
                    list.append(l.t("assistant.scheduleItem", ["start": item.start, "end": endText, "title": item.title]))
                } else {
                    list.append(l.t("assistant.scheduleItemOpen", ["start": item.start, "title": item.title]))
                }
            }
            details.append(l.t("assistant.scheduleNote"))
        default:
            break
        }
        if ["addSubtask", "updateSubtask", "deleteSubtask", "moveSubtask"].contains(entry.type ?? ""), let target {
            details.insert(l.t("assistant.inTask", ["title": target.title]), at: 0)
        }
        for (warning, key) in warningNotes where entry.warnings.contains(warning) { notes.append(l.t(key)) }
        return ReviewText(kind: kind, title: title, details: details, list: list, notes: notes)
    }

    /// The warning shown for an item that cannot be applied, or nil.
    public static func invalidText(_ l: L10n, item: ProposalItem) -> String? {
        if !item.supported { return l.t("assistant.notSupported") }
        if !item.entry.valid {
            let reasons = item.entry.errors.map { l.t("assistant.reasons.\($0)") }.joined(separator: ", ")
            return l.t(item.entry.type == "create" ? "assistant.invalid" : "assistant.invalidChange", ["reasons": reasons])
        }
        return nil
    }

    /// Outcome text: never claims success unless the save succeeded.
    public static func resultText(_ l: L10n, _ result: ProposalResult) -> String {
        switch result {
        case .changed:
            return l.t("assistant.changed")
        case .conflict:
            return l.t("assistant.conflictBlocked")
        case .applied(let created, let updated, let deleted, _, let saved):
            if !saved { return l.t("assistant.appliedNotSaved", ["count": created + updated + deleted]) }
            if deleted > 0 { return l.t("assistant.appliedAll", ["created": created, "updated": updated, "deleted": deleted]) }
            return updated == 0 ? l.t("assistant.applied", ["count": created]) : l.t("assistant.appliedSummary", ["created": created, "updated": updated])
        case .undone(let removed, let restored, let kept, let saved):
            if !saved { return l.t("assistant.undoneNotSaved", ["count": removed + restored]) }
            let main = restored == 0 ? l.t("assistant.undone", ["count": removed]) : l.t("assistant.undoneSummary", ["removed": removed, "restored": restored])
            return kept > 0 ? "\(main) \(l.t("assistant.undoKept", ["count": kept]))" : main
        }
    }
}

// MARK: - Demo tasks

public enum SampleTasks {
    static let samples: [(id: String, status: TaskStatus, priority: Priority, dueIn: Int, labels: [String])] = [
        ("t1", .todo, .high, 2, ["planning"]),
        ("t2", .todo, .medium, 6, ["docs"]),
        ("t3", .todo, .low, 10, ["research"]),
        ("t4", .inProgress, .high, 1, ["design", "ui"]),
        ("t5", .inProgress, .high, -1, ["bug"]),
        ("t6", .inProgress, .medium, 4, ["dev"]),
        ("t7", .done, .medium, -3, ["dev"]),
        ("t8", .done, .low, -5, ["design"]),
    ]

    /// Demo tasks shown on first launch, in the language active at startup. Afterwards they are
    /// ordinary user content and are not re-translated.
    public static func create(_ l: L10n, now: Date = Date(), timeZone: TimeZone = .current) -> [TaskItem] {
        let today = Schedule.localDateKey(now, timeZone: timeZone)
        var nextOrder: [TaskStatus: Int] = [:]
        return samples.map { sample in
            let order = (nextOrder[sample.status] ?? -1) + 1
            nextOrder[sample.status] = order
            return TaskModel.createTask([
                "id": .string("sample-\(sample.id)"),
                "order": .number(Double(order)),
                "title": .string(l.t("sample.tasks.\(sample.id).title")),
                "description": .string(l.t("sample.tasks.\(sample.id).description")),
                "priority": .string(sample.priority.rawValue),
                "status": .string(sample.status.rawValue),
                "dueDate": .string(Schedule.addDaysToKey(today, sample.dueIn)),
                "labels": .from(sample.labels.map { l.t("sample.labels.\($0)") }),
            ], now: now)
        }
    }
}
