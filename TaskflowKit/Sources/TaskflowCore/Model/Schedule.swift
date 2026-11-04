// Deadlines, reminder schedules and recurrence rules - a port of electron/shared/schedule.mjs.
//
// Three separate things:
//   - deadline:  task.dueDate ("YYYY-MM-DD", local calendar date) + optional task.dueTime ("HH:MM",
//                local wall-clock time). No time means "some time that day" - never a made-up time.
//   - reminders: task.reminders = minutes before the deadline. With a due time any offset works;
//                without one only whole days are allowed, and they fire at the user's "reminder time
//                for tasks without a time" (a reminder setting, not a deadline).
//   - recurrence: task.recurrence = a rule; the task always holds its NEXT occurrence in dueDate.
//
// Times are local wall-clock values and are turned into instants only when needed, with the
// current time zone. So a time-zone change moves nothing on the calendar ("09:00" stays 09:00), and
// DST follows JavaScript's rules: a time that does not exist (spring forward) becomes the next valid
// time, an ambiguous one (fall back) is the first of the two.
import Foundation

public enum Schedule {
    public static let dayMinutes = 1440
    public static let reminderPresets = [0, 10, 30, 60, 120, dayMinutes, 2 * dayMinutes, 7 * dayMinutes]
    public static let maxReminders = 5
    public static let maxReminderMinutes = 30 * dayMinutes
    public static let defaultAllDayReminderTime = "09:00"
    public static let recurrenceFrequencies: [Recurrence.Frequency] = [.daily, .weekly, .monthly]
    public static let maxRecurrenceInterval = 99
    public static let maxEstimateMinutes = 24 * 60

    // MARK: Keys

    /// A real calendar date in "YYYY-MM-DD" form (2026-02-30 is rejected).
    public static func isDateKey(_ value: String?) -> Bool {
        guard let parts = dateParts(value) else { return false }
        let (year, month, day) = parts
        // Date.UTC maps years 0-99 to 1900-1999, so JavaScript rejects them too.
        guard year >= 100, (1...12).contains(month), day >= 1 else { return false }
        return day <= daysInMonth(year: year, month: month)
    }

    public static func isDateKey(_ value: JSONValue?) -> Bool { isDateKey(value?.stringValue) }

    /// "HH:MM", 24 hours.
    public static func isTimeKey(_ value: String?) -> Bool {
        guard let value, value.utf8.count == 5 else { return false }
        let chars = Array(value.utf8)
        guard chars[2] == UInt8(ascii: ":"), chars.enumerated().allSatisfy({ $0.offset == 2 || ($0.element >= 48 && $0.element <= 57) }) else { return false }
        let hours = Int(chars[0] - 48) * 10 + Int(chars[1] - 48)
        let minutes = Int(chars[3] - 48) * 10 + Int(chars[4] - 48)
        return hours <= 23 && minutes <= 59
    }

    public static func isTimeKey(_ value: JSONValue?) -> Bool { isTimeKey(value?.stringValue) }

    static func dateParts(_ value: String?) -> (Int, Int, Int)? {
        guard let value, value.utf8.count == 10 else { return nil }
        let chars = Array(value.utf8)
        guard chars[4] == UInt8(ascii: "-"), chars[7] == UInt8(ascii: "-") else { return nil }
        for (index, char) in chars.enumerated() where index != 4 && index != 7 {
            guard char >= 48 && char <= 57 else { return nil }
        }
        let number = { (range: Range<Int>) in range.reduce(0) { $0 * 10 + Int(chars[$1] - 48) } }
        return (number(0..<4), number(5..<7), number(8..<10))
    }

    static func parseDate(_ key: String) -> (Int, Int, Int) {
        dateParts(key) ?? (1970, 1, 1)
    }

    static func timeParts(_ key: String) -> (Int, Int) {
        let parts = key.split(separator: ":").compactMap { Int($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : (0, 0)
    }

    static func pad(_ value: Int) -> String { value < 10 ? "0\(value)" : "\(value)" }

    static func key(year: Int, month: Int, day: Int) -> String {
        let yearText = String(year)
        let paddedYear = String(repeating: "0", count: max(0, 4 - yearText.count)) + yearText
        return "\(paddedYear)-\(pad(month))-\(pad(day))"
    }

    // MARK: Calendar arithmetic (no time zone involved)

    /// Days since 1970-01-01 of a proleptic Gregorian date (like Date.UTC / 86400000).
    static func epochDay(year: Int, month: Int, day: Int) -> Int {
        // Normalizes month overflow first (JS Date.UTC accepts month 13 etc.).
        var y = year + Int((Double(month - 1) / 12).rounded(.down))
        var m = ((month - 1) % 12 + 12) % 12 + 1
        // Howard Hinnant's days_from_civil.
        y -= m <= 2 ? 1 : 0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (m + 9) % 12
        m = mp
        let doy = (153 * m + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func civil(fromEpochDay z0: Int) -> (Int, Int, Int) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let y = yoe + era * 400
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp < 10 ? mp + 3 : mp - 9
        return (m <= 2 ? y + 1 : y, m, d)
    }

    public static func addDaysToKey(_ key: String, _ days: Int) -> String {
        let (year, month, day) = parseDate(key)
        let (y, m, d) = civil(fromEpochDay: epochDay(year: year, month: month, day: day) + days)
        return Schedule.key(year: y, month: m, day: d)
    }

    static func daysBetween(_ fromKey: String, _ toKey: String) -> Int {
        let (y1, m1, d1) = parseDate(fromKey)
        let (y2, m2, d2) = parseDate(toKey)
        return epochDay(year: y2, month: m2, day: d2) - epochDay(year: y1, month: m1, day: d1)
    }

    /// 0 = Sunday.
    public static func weekdayOf(_ key: String) -> Int {
        let (year, month, day) = parseDate(key)
        let days = epochDay(year: year, month: month, day: day)
        return ((days % 7) + 7 + 4) % 7 // 1970-01-01 was a Thursday
    }

    static func daysInMonth(year: Int, month: Int) -> Int {
        let next = month == 12 ? epochDay(year: year + 1, month: 1, day: 1) : epochDay(year: year, month: month + 1, day: 1)
        return next - epochDay(year: year, month: month, day: 1)
    }

    // MARK: Local time

    /// Local "YYYY-MM-DD" of an instant.
    public static func localDateKey(_ date: Date, timeZone: TimeZone = .current) -> String {
        let (y, m, d, _, _) = wallClock(date, timeZone: timeZone)
        return key(year: y, month: m, day: d)
    }

    /// Local "HH:MM" of an instant.
    public static func localTimeKey(_ date: Date, timeZone: TimeZone = .current) -> String {
        let (_, _, _, h, min) = wallClock(date, timeZone: timeZone)
        return "\(pad(h)):\(pad(min))"
    }

    static func wallClock(_ date: Date, timeZone: TimeZone) -> (Int, Int, Int, Int, Int) {
        let seconds = Int((date.timeIntervalSince1970).rounded(.down)) + timeZone.secondsFromGMT(for: date)
        let day = Int((Double(seconds) / 86_400).rounded(.down))
        let secondOfDay = seconds - day * 86_400
        let (y, m, d) = civil(fromEpochDay: day)
        return (y, m, d, secondOfDay / 3600, (secondOfDay % 3600) / 60)
    }

    /// The instant of a local wall-clock time, with JavaScript's `new Date(y, m - 1, d, h, min)`
    /// semantics: components may overflow (minute -30 = 30 minutes earlier); a time in a DST gap
    /// moves forward by the gap; an ambiguous time is the earlier of the two instants.
    public static func localInstant(year: Int, month: Int, day: Int, hour: Int, minute: Int, timeZone: TimeZone = .current) -> Date {
        let naive = Double(epochDay(year: year, month: month, day: day)) * 86_400 + Double(hour * 3600 + minute * 60)
        let offsetBefore = Double(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: naive - 43_200)))
        let offsetAfter = Double(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: naive + 43_200)))
        var candidates: [Double] = []
        for offset in [offsetBefore, offsetAfter] {
            let instant = naive - offset
            if Double(timeZone.secondsFromGMT(for: Date(timeIntervalSince1970: instant))) == offset, !candidates.contains(instant) {
                candidates.append(instant)
            }
        }
        if let earliest = candidates.min() { return Date(timeIntervalSince1970: earliest) }
        // In a gap: interpret with the offset before the transition (the clock moved forward).
        return Date(timeIntervalSince1970: naive - offsetBefore)
    }

    public static func localInstant(_ dateKey: String, _ timeKey: String = "00:00", timeZone: TimeZone = .current) -> Date {
        let (year, month, day) = parseDate(dateKey)
        let (hours, minutes) = timeParts(timeKey)
        return localInstant(year: year, month: month, day: day, hour: hours, minute: minutes, timeZone: timeZone)
    }

    // MARK: Normalization

    /// A due time only exists together with a due date.
    public static func normalizeDueTime(_ value: String?, dueDate: String?) -> String? {
        isDateKey(dueDate) && isTimeKey(value) ? value : nil
    }

    /// Reminder offsets in minutes before the deadline: whole numbers, unique, sorted, at most
    /// maxReminders. Without a due date there are none; without a due time only whole days remain.
    public static func normalizeReminders(_ list: [Int]?, dueDate: String?, dueTime: String?) -> [Int] {
        guard let list, isDateKey(dueDate) else { return [] }
        var result: [Int] = []
        for value in list {
            if value < 0 || value > maxReminderMinutes { continue }
            if !isTimeKey(dueTime) && value % dayMinutes != 0 { continue }
            if !result.contains(value) { result.append(value) }
        }
        return Array(result.sorted().prefix(maxReminders))
    }

    /// The JSON form (values that are not whole numbers are skipped, as in JS).
    public static func normalizeReminders(_ raw: JSONValue?, dueDate: String?, dueTime: String?) -> [Int] {
        guard let list = raw?.arrayValue else { return [] }
        return normalizeReminders(list.compactMap(\.intValue), dueDate: dueDate, dueTime: dueTime)
    }

    /// Estimated duration in minutes (1...1440) or nil.
    public static func normalizeEstimate(_ value: Int?) -> Int? {
        guard let value, value >= 1, value <= maxEstimateMinutes else { return nil }
        return value
    }

    public static func normalizeEstimate(_ raw: JSONValue?) -> Int? { normalizeEstimate(raw?.intValue) }

    /// Recurrence rule or nil (see Recurrence). A rule needs a due date: the due date is the next
    /// occurrence.
    public static func normalizeRecurrence(_ raw: JSONValue?, dueDate: String?) -> Recurrence? {
        guard let raw, raw.isPlainObject, let dueDate, isDateKey(dueDate) else { return nil }
        guard let freqText = raw["freq"]?.stringValue, let freq = Recurrence.Frequency(rawValue: freqText) else { return nil }
        let rawInterval = raw["interval"]?.intValue
        let interval = rawInterval.map { (1...maxRecurrenceInterval).contains($0) ? $0 : 1 } ?? 1
        var rule = Recurrence(freq: freq, interval: interval)
        if freq == .weekly {
            let days = (raw["weekdays"]?.arrayValue ?? []).compactMap(\.intValue).filter { (0...6).contains($0) }
            let unique = Array(Set(days)).sorted()
            rule.weekdays = unique.isEmpty ? [weekdayOf(dueDate)] : unique
        }
        if freq == .monthly {
            if let day = raw["monthDay"]?.intValue, (1...31).contains(day) {
                rule.monthDay = day
            } else {
                rule.monthDay = parseDate(dueDate).2
            }
        }
        return rule
    }

    public static func normalizeRecurrence(_ rule: Recurrence?, dueDate: String?) -> Recurrence? {
        guard let rule else { return nil }
        return normalizeRecurrence(rule.json, dueDate: dueDate)
    }

    // MARK: Recurrence

    /// Monday-based week number, for "every N weeks".
    static func weekIndex(_ key: String) -> Int {
        Int((Double(daysBetween("2000-01-03", key)) / 7).rounded(.down)) // 2000-01-03 was a Monday
    }

    /// The first occurrence of `rule` after `afterKey` (exclusive), stepping from `fromKey` (the
    /// current occurrence, which keeps "every N" aligned). Returns a date key.
    public static func nextOccurrence(_ rule: Recurrence, from fromKey: String, after afterKey: String) -> String {
        let after = afterKey < fromKey ? fromKey : afterKey
        switch rule.freq {
        case .daily:
            let gap = daysBetween(fromKey, after)
            let steps = Int((Double(gap) / Double(rule.interval)).rounded(.down)) + 1
            return addDaysToKey(fromKey, steps * rule.interval)
        case .weekly:
            let baseWeek = weekIndex(fromKey)
            let weekdays = rule.weekdays ?? [weekdayOf(fromKey)]
            var key = addDaysToKey(after, 1)
            // Bounded: within interval * 7 days of any start there is an occurrence.
            for _ in 0..<(rule.interval * 7 + 7) {
                let difference = weekIndex(key) - baseWeek
                // JS % keeps the sign; a negative difference is never 0 here unless divisible.
                if difference % rule.interval == 0 && weekdays.contains(weekdayOf(key)) { return key }
                key = addDaysToKey(key, 1)
            }
            return addDaysToKey(after, 7 * rule.interval)
        case .monthly:
            let (fromYear, fromMonth, _) = parseDate(fromKey)
            let monthDay = rule.monthDay ?? parseDate(fromKey).2
            for step in 1..<(12 * 200) {
                let total = fromYear * 12 + (fromMonth - 1) + step * rule.interval
                let year = Int((Double(total) / 12).rounded(.down))
                let month = total - year * 12
                let key = Schedule.key(year: year, month: month + 1, day: min(monthDay, daysInMonth(year: year, month: month + 1)))
                if key > after { return key }
            }
            return after
        }
    }

    /// Completing an occurrence of a recurring task: the next due date. Missed occurrences are
    /// skipped (an overdue series continues after today); completing early continues after the
    /// current one.
    public static func nextDueDateAfterCompletion(_ rule: Recurrence, dueDate: String, todayKey: String) -> String {
        nextOccurrence(rule, from: dueDate, after: todayKey > dueDate ? todayKey : dueDate)
    }

    // MARK: Deadlines and reminders

    /// The deadline instant for "is it overdue": the due time, or the end of the due day when there
    /// is no time. nil without a due date.
    public static func deadlineInstant(dueDate: String?, dueTime: String?, timeZone: TimeZone = .current) -> Date? {
        guard let dueDate, isDateKey(dueDate) else { return nil }
        if let dueTime, isTimeKey(dueTime) { return localInstant(dueDate, dueTime, timeZone: timeZone) }
        return localInstant(addDaysToKey(dueDate, 1), "00:00", timeZone: timeZone)
    }

    public struct ReminderTime: Equatable, Sendable {
        public let offset: Int
        public let at: Date
    }

    /// When each reminder of a task fires. With a due time, offsets count back from it; without
    /// one, whole-day offsets count back from the due date at `allDayTime`.
    public static func reminderSchedule(reminders: [Int], dueDate: String?, dueTime: String?, allDayTime: String = defaultAllDayReminderTime, timeZone: TimeZone = .current) -> [ReminderTime] {
        let offsets = normalizeReminders(reminders, dueDate: dueDate, dueTime: dueTime)
        guard let dueDate, !offsets.isEmpty else { return [] }
        let time = isTimeKey(allDayTime) ? allDayTime : defaultAllDayReminderTime
        return offsets.map { offset in
            if let dueTime, isTimeKey(dueTime) {
                // Count back on the wall clock (calendar days + minutes) so DST days do not shift reminders.
                let days = offset / dayMinutes
                let minutes = offset % dayMinutes
                let day = addDaysToKey(dueDate, -days)
                let base = localInstant(day, dueTime, timeZone: timeZone)
                let (y, m, d, h, min) = wallClock(base, timeZone: timeZone)
                return ReminderTime(offset: offset, at: localInstant(year: y, month: m, day: d, hour: h, minute: min - minutes, timeZone: timeZone))
            }
            return ReminderTime(offset: offset, at: localInstant(addDaysToKey(dueDate, -offset / dayMinutes), time, timeZone: timeZone))
        }
    }
}

/// { freq: daily|weekly|monthly, interval: 1...99, weekdays: [0...6] (weekly, Sunday = 0; defaults
/// to the due date's weekday), monthDay: 1...31 (monthly; defaults to the due date's day; shorter
/// months use their last day) }.
public struct Recurrence: Equatable, Hashable, Sendable, Codable {
    public enum Frequency: String, Sendable, Codable, CaseIterable { case daily, weekly, monthly }
    public var freq: Frequency
    public var interval: Int
    public var weekdays: [Int]?
    public var monthDay: Int?

    public init(freq: Frequency, interval: Int = 1, weekdays: [Int]? = nil, monthDay: Int? = nil) {
        self.freq = freq
        self.interval = interval
        self.weekdays = weekdays
        self.monthDay = monthDay
    }

    public var json: JSONValue {
        var dict: [String: JSONValue] = ["freq": .string(freq.rawValue), "interval": .number(Double(interval))]
        if let weekdays { dict["weekdays"] = .from(weekdays) }
        if let monthDay { dict["monthDay"] = .number(Double(monthDay)) }
        return .object(dict)
    }
}
