// Search, filters, sorting and statistics - Toolbar.jsx, FilterMenu.jsx, ViewStatus.jsx and
// TaskStats.jsx on iPhone. Nothing here changes tasks or their saved order; the view state is
// temporary.
import SwiftUI
import TaskflowCore

struct FilterSortSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var store = store
        let l10n = store.l10n
        let labels = store.labelSuggestions
        NavigationStack {
            Form {
                Section(l10n.t("toolbar.sortLabel")) {
                    Picker(l10n.t("toolbar.sortLabel"), selection: $store.view.sort) {
                        ForEach(SortMode.allCases, id: \.self) { mode in
                            Text(l10n.t("toolbar.sort.\(mode.rawValue)")).tag(mode)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                .listRowBackground(Theme.bgCard)
                Section(l10n.t("filters.status")) {
                    ForEach(TaskStatus.allCases, id: \.self) { status in
                        toggleRow(l10n.t("columns.\(status.rawValue)"), color: Theme.status(status), on: store.view.statuses.contains(status)) {
                            store.view.statuses.toggle(status)
                        }
                    }
                }
                .listRowBackground(Theme.bgCard)
                Section(l10n.t("filters.priority")) {
                    ForEach([Priority.high, .medium, .low], id: \.self) { priority in
                        toggleRow(l10n.t("priority.\(priority.rawValue)"), color: Theme.priority(priority), on: store.view.priorities.contains(priority)) {
                            store.view.priorities.toggle(priority)
                        }
                    }
                }
                .listRowBackground(Theme.bgCard)
                Section(l10n.t("filters.due")) {
                    ForEach(DueFilter.allCases, id: \.self) { filter in
                        toggleRow(l10n.t("filters.dueOptions.\(filter.rawValue)"), color: filter == .overdue ? Theme.danger : filter == .today ? Theme.warning : Theme.info, on: store.view.due.contains(filter)) {
                            store.view.due.toggle(filter)
                        }
                    }
                }
                .listRowBackground(Theme.bgCard)
                Section(l10n.t("filters.labels")) {
                    if labels.isEmpty {
                        Text(l10n.t("filters.noLabels")).foregroundStyle(Theme.textMuted)
                    }
                    ForEach(labels, id: \.self) { label in
                        toggleRow(label, color: Theme.label(label), on: store.view.labels.contains { $0.lowercased() == label.lowercased() }) {
                            if let index = store.view.labels.firstIndex(where: { $0.lowercased() == label.lowercased() }) {
                                store.view.labels.remove(at: index)
                            } else {
                                store.view.labels.append(label)
                            }
                        }
                    }
                }
                .listRowBackground(Theme.bgCard)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bgApp)
            .navigationTitle(l10n.t("ios.sortAndFilter"))
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(l10n.t("view.resetAll")) { store.resetView() }
                        .disabled(store.view == AppStore.defaultView)
                }
                ToolbarItem(placement: .confirmationAction) { Button(l10n.t("ios.done")) { dismiss() }.fontWeight(.semibold) }
            }
        }
        .sheetDetents(large: false)
        .tint(Theme.accent)
    }

    func toggleRow(_ title: String, color: Color, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(title).foregroundStyle(Theme.textPrimary)
                Spacer()
                if on { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
            }
        }
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

extension Array where Element: Equatable {
    mutating func toggle(_ element: Element) {
        if let index = firstIndex(of: element) { remove(at: index) } else { append(element) }
    }
}

/// Total / done / overdue and the share of completed tasks (the whole scope, not just the filter).
struct StatsBar: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let l10n = store.l10n
        let stats = store.stats
        HStack(spacing: 14) {
            item("\(stats.total)", l10n.t("stats.total"), Theme.textPrimary)
            item("\(stats.done)", l10n.t("stats.done"), Theme.accent)
            item("\(stats.overdue)", l10n.t("stats.overdue"), stats.overdue > 0 ? Theme.danger : Theme.textPrimary)
            VStack(alignment: .trailing, spacing: 4) {
                Text(stats.percent.map { l10n.t("stats.percent", ["percent": $0]) } ?? "—")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.bgElevated)
                        Capsule().fill(Theme.accent).frame(width: proxy.size.width * CGFloat(stats.percent ?? 0) / 100)
                    }
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(l10n.t("stats.progress"))
            .accessibilityValue(stats.percent.map { l10n.t("stats.percent", ["percent": $0]) } ?? l10n.t("stats.noTasks"))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l10n.t("stats.label"))
    }

    func item(_ value: String, _ name: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.headline.monospacedDigit()).foregroundStyle(color)
            Text(name).font(.caption2).foregroundStyle(Theme.textMuted)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Active search and filters as removable chips, "Showing X of Y", and the drag hint.
struct ViewStatusBar: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let l10n = store.l10n
        let view = store.view
        if store.viewChanged {
            VStack(alignment: .leading, spacing: 6) {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        let board = store.visibleCount
                        Text(l10n.t("view.showing", ["shown": board.shown, "total": board.total]))
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                        if !TaskViews.normalizeQuery(view.query).isEmpty {
                            chip(l10n.t("view.searchChip", ["query": view.query.trimmingCharacters(in: .whitespaces)])) { store.view.query = "" }
                        }
                        ForEach(view.statuses, id: \.self) { status in
                            chip(l10n.t("columns.\(status.rawValue)")) { store.view.statuses.toggle(status) }
                        }
                        ForEach(view.priorities, id: \.self) { priority in
                            chip(l10n.t("priority.\(priority.rawValue)")) { store.view.priorities.toggle(priority) }
                        }
                        ForEach(view.due, id: \.self) { due in
                            chip(l10n.t("filters.dueOptions.\(due.rawValue)")) { store.view.due.toggle(due) }
                        }
                        ForEach(view.labels, id: \.self) { label in
                            chip(label) { store.view.labels.toggle(label) }
                        }
                        if view.sort != AppStore.defaultView.sort {
                            chip(l10n.t("toolbar.sort.\(view.sort.rawValue)"), icon: "arrow.up.arrow.down") { store.view.sort = AppStore.defaultView.sort }
                        }
                        Button(l10n.t("view.resetAll")) { store.resetView() }
                            .font(.caption.weight(.semibold))
                    }
                    .padding(.horizontal, 16)
                }
                .scrollIndicators(.hidden)
                if store.layout == .board && !store.showCalendar && !store.dragAllowed {
                    Text(l10n.t("view.dragDisabled"))
                        .font(.caption2)
                        .foregroundStyle(Theme.textMuted)
                        .padding(.horizontal, 16)
                }
            }
            .padding(.vertical, 4)
        }
    }

    func chip(_ text: String, icon: String = "xmark", remove: @escaping () -> Void) -> some View {
        Button(action: remove) {
            HStack(spacing: 4) {
                Text(text)
                Image(systemName: icon).font(.caption2)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .foregroundStyle(Theme.accent)
            .background(Theme.accentSoft, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(store.l10n.t("view.removeFilter", ["name": text]))
    }
}
