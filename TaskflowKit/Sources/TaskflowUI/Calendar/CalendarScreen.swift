// The calendar (an iPhone addition, as in Todoery): a month grid with a dot per task due that day,
// and the tasks of the chosen day below it. Search and filters apply; a repeating task appears on
// its next due date (the only one stored). The board/list layout of the data file is not changed.
import SwiftUI
import TaskflowCore

struct CalendarScreen: View {
    @Environment(AppStore.self) private var store
    var onEdit: (String) -> Void
    var onDelete: (String) -> Void
    var onNew: (String) -> Void
    /// First day of the month on screen.
    @LocalState private var month = Date()
    @LocalState private var selectedKey: String?

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = store.locale
        calendar.timeZone = .current
        return calendar
    }

    var body: some View {
        let l10n = store.l10n
        let byDate = store.tasksByDate
        let selected = selectedKey ?? store.todayKey
        let dayTasks = (byDate[selected] ?? []).sorted { ($0.status == .done ? 1 : 0) < ($1.status == .done ? 1 : 0) }
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                monthHeader(l10n)
                grid(byDate: byDate, selected: selected)
                    .padding(12)
                    .cardSurface()
                HStack {
                    Text(l10n.formatDate(selected, .weekdayFull).capitalizedFirst)
                        .font(.headline)
                        .foregroundStyle(Theme.textPrimary)
                    Text("\(dayTasks.count)").font(.subheadline.monospacedDigit()).foregroundStyle(Theme.textMuted)
                    Spacer()
                    Button { onNew(selected) } label: { Label(l10n.t("actions.newTask"), systemImage: "plus") }
                        .font(.subheadline.weight(.semibold))
                        .labelStyle(.iconOnly)
                        .accessibilityLabel(l10n.t("actions.newTask"))
                }
                if dayTasks.isEmpty {
                    Text(l10n.t("ios.calendarNoTasks"))
                        .font(.subheadline)
                        .foregroundStyle(Theme.textMuted)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 24)
                } else {
                    LazyVStack(spacing: 8) {
                        ForEach(dayTasks) { task in
                            TaskRow(task: task)
                                .contentShape(Rectangle())
                                .onTapGesture { onEdit(task.id) }
                                .contextMenu {
                                    TaskContextMenu(task: task, onEdit: { onEdit(task.id) }, onDelete: { onDelete(task.id) })
                                }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Theme.bgApp)
        .onAppear { month = startOfMonth(Date()) }
    }

    func monthHeader(_ l10n: L10n) -> some View {
        HStack {
            Button { shift(-1) } label: { Image(systemName: "chevron.left").frame(width: 36, height: 36) }
                .accessibilityLabel(l10n.t("ios.previousMonth"))
            Spacer()
            Button {
                month = startOfMonth(Date())
                selectedKey = nil
            } label: {
                Text(monthTitle)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
            }
            .accessibilityHint(l10n.t("ios.calendarToday"))
            Spacer()
            Button { shift(1) } label: { Image(systemName: "chevron.right").frame(width: 36, height: 36) }
                .accessibilityLabel(l10n.t("ios.nextMonth"))
        }
        .font(.headline)
    }

    var monthTitle: String {
        Formatters.template("LLLLy", locale: store.locale, timeZone: .current).string(from: month).capitalizedFirst
    }

    func grid(byDate: [String: [TaskItem]], selected: String) -> some View {
        let calendar = calendar
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let first = calendar.firstWeekday - 1
        let weekdays = (0..<7).map { symbols[(first + $0) % 7].capitalizedFirst }
        let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
        return LazyVGrid(columns: columns, spacing: 6) {
            ForEach(Array(weekdays.enumerated()), id: \.offset) { _, name in
                Text(name).font(.caption2.weight(.semibold)).foregroundStyle(Theme.textMuted)
            }
            ForEach(Array(days.enumerated()), id: \.offset) { _, key in
                if let key {
                    dayCell(key, tasks: byDate[key] ?? [], selected: key == selected)
                } else {
                    Color.clear.frame(height: 44)
                }
            }
        }
    }

    func dayCell(_ key: String, tasks: [TaskItem], selected: Bool) -> some View {
        let today = key == store.todayKey
        let open = tasks.filter { $0.status != .done }
        let overdue = key < store.todayKey && !open.isEmpty
        return Button {
            selectedKey = key
            Haptics.tap()
        } label: {
            VStack(spacing: 3) {
                Text("\(Int(key.suffix(2)) ?? 0)")
                    .font(.subheadline.weight(today || selected ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(selected ? Theme.bgApp : today ? Theme.accent : Theme.textPrimary)
                    .frame(width: 32, height: 32)
                    .background {
                        if selected { Circle().fill(Theme.accent) } else if today { Circle().strokeBorder(Theme.accent, lineWidth: 1.5) }
                    }
                HStack(spacing: 3) {
                    ForEach(Array(open.prefix(3).enumerated()), id: \.offset) { _, task in
                        Circle().fill(overdue ? Theme.danger : Theme.priority(task.priority)).frame(width: 5, height: 5)
                    }
                    if open.isEmpty && !tasks.isEmpty {
                        Circle().fill(Theme.textMuted.opacity(0.5)).frame(width: 5, height: 5)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(store.l10n.formatDate(key, .weekdayLong))
        .accessibilityValue(store.l10n.t("ios.calendarDayCount", ["count": tasks.count]))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Date keys of the month, with nil for the empty cells before the first day.
    var days: [String?] {
        let calendar = calendar
        guard let range = calendar.range(of: .day, in: .month, for: month) else { return [] }
        let leading = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        let firstKey = Schedule.localDateKey(month)
        return Array(repeating: nil, count: leading) + (0..<range.count).map { Schedule.addDaysToKey(firstKey, $0) }
    }

    func startOfMonth(_ date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    func shift(_ months: Int) {
        guard let next = calendar.date(byAdding: .month, value: months, to: month) else { return }
        withAnimation(Theme.fast) {
            month = startOfMonth(next)
            // The current month opens on today, others on their first day.
            let key = Schedule.localDateKey(month)
            selectedKey = key.prefix(7) == store.todayKey.prefix(7) ? nil : key
        }
    }
}

extension String {
    /// "ноябрь 2026" -> "Ноябрь 2026".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
