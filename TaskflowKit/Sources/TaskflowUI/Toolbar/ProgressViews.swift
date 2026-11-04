// iPhone additions inspired by Todoery: category chips above the tasks (switch the destination in
// one tap instead of opening the sidebar) and a progress overview with completed tasks per day.
import Charts
import SwiftUI
import TaskflowCore

/// "Все · Работа · Дом · Без категории" - shown when there are categories.
struct CategoryChipsBar: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let l10n = store.l10n
        if !store.categories.isEmpty {
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        chip(l10n.t("nav.allTasks"), .all)
                        ForEach(store.categories) { category in chip(category.name, .category(category.id)) }
                        chip(l10n.t("nav.uncategorized"), .uncategorized)
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
                .onAppear { proxy.scrollTo(store.activeDestination, anchor: .center) }
                .onChange(of: store.activeDestination) {
                    withAnimation(Theme.standard) { proxy.scrollTo(store.activeDestination, anchor: .center) }
                }
            }
            .padding(.top, 6)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(l10n.t("nav.sectionCategories"))
        }
    }

    func chip(_ name: String, _ destination: Destination) -> some View {
        let active = store.activeDestination == destination
        let count = store.counts[destination] ?? 0
        return Button {
            store.destination = destination
            Haptics.tap()
        } label: {
            HStack(spacing: 5) {
                Text(name).lineLimit(1)
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(active ? Theme.bgApp.opacity(0.7) : Theme.textMuted)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .foregroundStyle(active ? Theme.bgApp : Theme.textPrimary)
            .background(active ? Theme.accent : Theme.bgCard, in: Capsule())
            .overlay(Capsule().strokeBorder(active ? Color.clear : Theme.borderDefault))
        }
        .buttonStyle(.plain)
        .id(destination)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

/// Progress of the current destination: totals and completed tasks per day for the last week.
struct ProgressSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let l10n = store.l10n
        let stats = store.stats
        let days = TaskViews.completionsByDay(store.scopedTasks, days: 7, now: store.now)
        let week = days.reduce(0) { $0 + $1.count }
        let today = days.last?.count ?? 0
        let open = store.scopedTasks.filter { $0.status != .done }
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                        tile("\(today)", l10n.t("ios.doneToday"), Theme.accent)
                        tile("\(week)", l10n.t("ios.doneWeek"), Theme.accent)
                        tile("\(open.count)", l10n.t("ios.openTasks"), Theme.info)
                        tile("\(stats.overdue)", l10n.t("stats.overdue"), stats.overdue > 0 ? Theme.danger : Theme.textPrimary)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text(l10n.t("ios.completedPerDay")).font(.headline).foregroundStyle(Theme.textPrimary)
                        Chart(days, id: \.dateKey) { day in
                            BarMark(
                                x: .value(l10n.t("ios.day"), weekday(day.dateKey)),
                                y: .value(l10n.t("stats.done"), day.count)
                            )
                            .foregroundStyle(day.dateKey == store.todayKey ? Theme.accent : Theme.accent.opacity(0.55))
                            .cornerRadius(4)
                            .annotation(position: .top) {
                                if day.count > 0 {
                                    Text("\(day.count)").font(.caption2.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                                }
                            }
                        }
                        .chartYAxis(.hidden)
                        .chartXAxis {
                            AxisMarks { _ in AxisValueLabel().foregroundStyle(Theme.textMuted) }
                        }
                        .frame(height: 180)
                        if week == 0 {
                            Text(l10n.t("ios.noCompletions")).font(.footnote).foregroundStyle(Theme.textMuted)
                        }
                    }
                    .padding(14)
                    .cardSurface()
                    VStack(alignment: .leading, spacing: 10) {
                        Text(l10n.t("ios.openByPriority")).font(.headline).foregroundStyle(Theme.textPrimary)
                        ForEach([Priority.high, .medium, .low], id: \.self) { priority in
                            let count = open.filter { $0.priority == priority }.count
                            HStack {
                                Image(systemName: "flag.fill").foregroundStyle(Theme.priority(priority))
                                Text(l10n.t("priority.\(priority.rawValue)")).foregroundStyle(Theme.textPrimary)
                                Spacer()
                                Text("\(count)").monospacedDigit().foregroundStyle(Theme.textSecondary)
                            }
                            .font(.subheadline)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .padding(14)
                    .cardSurface()
                }
                .padding(16)
            }
            .background(Theme.bgApp)
            .navigationTitle(l10n.t("ios.progress"))
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(l10n.t("ios.done")) { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }

    func tile(_ value: String, _ name: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.title.weight(.bold).monospacedDigit()).foregroundStyle(color)
            Text(name).font(.footnote).foregroundStyle(Theme.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .cardSurface()
        .accessibilityElement(children: .combine)
    }

    /// "Пн" / "Mon" for a date key.
    func weekday(_ key: String) -> String {
        let utc = TimeZone(identifier: "UTC")!
        return Formatters.template("EEE", locale: store.locale, timeZone: utc).string(from: Schedule.localInstant(key, timeZone: utc)).capitalizedFirst
    }
}
