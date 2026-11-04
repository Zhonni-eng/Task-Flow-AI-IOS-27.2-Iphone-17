// The List view - TaskList.jsx and BulkToolbar.jsx on iPhone: one row per task with its status,
// priority, category, labels and due date (with year); swipe to complete or delete; Select for
// bulk actions on the visible tasks (status, category, priority, due date, delete with
// confirmation). Selection is cleared when the destination or layout changes.
import SwiftUI
import TaskflowCore

struct TaskListView: View {
    @Environment(AppStore.self) private var store
    var onEdit: (String) -> Void
    var onDelete: (String) -> Void
    @Binding var selecting: Bool
    @LocalState private var selection = Set<String>()
    @LocalState private var confirmBulkDelete = false
    @LocalState private var bulkDate = false
    /// Collapsed sections, remembered on this device.
    @AppStorage("taskflow.list.collapsed") private var collapsedRaw = ""

    var collapsed: Set<String> { Set(collapsedRaw.split(separator: ",").map(String.init)) }

    func toggle(_ section: TaskViews.Section) {
        var next = collapsed
        if next.contains(section.rawValue) { next.remove(section.rawValue) } else { next.insert(section.rawValue) }
        withAnimation(Theme.standard) { collapsedRaw = next.sorted().joined(separator: ",") }
    }

    /// "Сегодня ⌃ 3" - tap to collapse or expand.
    func sectionHeader(_ section: TaskViews.Section, count: Int, _ l10n: L10n) -> some View {
        Button { toggle(section) } label: {
            HStack(spacing: 6) {
                Text(l10n.t("ios.section.\(section.rawValue)"))
                    .font(.headline)
                    .foregroundStyle(section == .overdue ? Theme.danger : Theme.textPrimary)
                Text("\(count)")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.textMuted)
                Image(systemName: "chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.textMuted)
                    .rotationEffect(.degrees(collapsed.contains(section.rawValue) ? -90 : 0))
                Spacer()
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .textCase(nil)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(collapsed.contains(section.rawValue) ? l10n.t("ios.collapsed") : l10n.t("ios.expanded"))
    }

    var body: some View {
        let l10n = store.l10n
        let tasks = store.listTasks
        let sections = store.listSections
        List(selection: selecting ? $selection : nil) {
            ForEach(sections, id: \.section) { group in
                Section {
                    if !collapsed.contains(group.section.rawValue) {
                        ForEach(group.tasks) { task in
                            ListTaskRow(task: task, selecting: selecting, onEdit: onEdit, onDelete: onDelete).tag(task.id)
                        }
                    }
                } header: {
                    sectionHeader(group.section, count: group.tasks.count, l10n)
                }
            }
            if tasks.isEmpty {
                Text(l10n.t("list.empty"))
                    .foregroundStyle(Theme.textMuted)
                    .listRowBackground(Color.clear)
            }
        }
        .listStyle(.plain)
        .sectionSpacing(6)
        .scrollContentBackground(.hidden)
        .background(Theme.bgApp)
        .selectionEditMode(selecting)
        .onChange(of: store.activeDestination) { selection = [] }
        .onChange(of: selecting) { if !selecting { selection = [] } }
        .onChange(of: tasks.map(\.id)) { _, visible in selection.formIntersection(visible) }
        .safeAreaInset(edge: .bottom) {
            if selecting { bulkBar(tasks: tasks) }
        }
        .confirmationDialog(l10n.t("bulk.confirmTitle"), isPresented: $confirmBulkDelete, titleVisibility: .visible) {
            Button(l10n.t("bulk.confirmButton", ["count": selection.count]), role: .destructive) {
                store.bulkDelete(selection)
                selection = []
            }
            Button(l10n.t("actions.cancel"), role: .cancel) {}
        } message: {
            Text(l10n.t("bulk.confirmMessage", ["count": selection.count]))
        }
        .sheet(isPresented: $bulkDate) {
            BulkDueDateSheet { key in
                store.bulkSetDueDate(selection, key)
                selection = []
            }
            .environment(store)
        }
    }

    @ViewBuilder
    func bulkBar(tasks: [TaskItem]) -> some View {
        let l10n = store.l10n
        let disabled = selection.isEmpty
        VStack(spacing: 8) {
            HStack {
                Text(l10n.t("bulk.selected", ["count": selection.count]))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Button(selection.count == tasks.count && !tasks.isEmpty ? l10n.t("bulk.clear") : l10n.t("ios.selectAll")) {
                    selection = selection.count == tasks.count ? [] : Set(tasks.map(\.id))
                }
                .font(.footnote)
            }
            HStack(spacing: 10) {
                Button {
                    store.bulkSetStatus(selection, .done)
                    selection = []
                } label: { Label(l10n.t("bulk.markDone"), systemImage: "checkmark.circle") }
                Menu {
                    ForEach(TaskStatus.allCases, id: \.self) { status in
                        Button(l10n.t("columns.\(status.rawValue)")) {
                            store.bulkSetStatus(selection, status)
                            selection = []
                        }
                    }
                } label: { Label(l10n.t("bulk.status"), systemImage: "arrow.left.arrow.right") }
                Menu {
                    Button(l10n.t("nav.uncategorized")) {
                        store.bulkSetCategory(selection, nil)
                        selection = []
                    }
                    ForEach(store.categories) { category in
                        Button(category.name) {
                            store.bulkSetCategory(selection, category.id)
                            selection = []
                        }
                    }
                } label: { Label(l10n.t("bulk.category"), systemImage: "folder") }
                Menu {
                    ForEach([Priority.high, .medium, .low], id: \.self) { priority in
                        Button(l10n.t("priority.\(priority.rawValue)")) {
                            store.bulkSetPriority(selection, priority)
                            selection = []
                        }
                    }
                } label: { Label(l10n.t("bulk.priority"), systemImage: "flag") }
                Button { bulkDate = true } label: { Label(l10n.t("bulk.dueDate"), systemImage: "calendar") }
                Spacer()
                Button(role: .destructive) { confirmBulkDelete = true } label: { Label(l10n.t("bulk.delete"), systemImage: "trash") }
                    .tint(Theme.danger)
            }
            .labelStyle(.iconOnly)
            .font(.title3)
            .disabled(disabled)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l10n.t("bulk.toolbar"))
    }
}

/// One task of the List as a separate card (clear separation between tasks), with swipe actions
/// and its context menu. A view of its own, so the row's modifiers are only built for the rows
/// the list actually shows (built inline, they were made for every task on every update).
struct ListTaskRow: View {
    @Environment(AppStore.self) private var store
    let task: TaskItem
    let selecting: Bool
    var onEdit: (String) -> Void
    var onDelete: (String) -> Void

    var body: some View {
        let l10n = store.l10n
        TaskRow(task: task, selecting: selecting)
            .contentShape(Rectangle())
            // While selecting, a tap selects the row: the gesture is masked off then, not removed -
            // a conditional modifier would make the list build every row instead of the visible
            // ones (it cannot tell how many views a conditional row produces without building it).
            .gesture(TapGesture().onEnded { onEdit(task.id) }, including: selecting ? .subviews : .all)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .swipeActions(edge: .leading) {
                if task.status != .done {
                    Button { store.setStatus(task.id, .done) } label: { Label(l10n.t("ios.complete"), systemImage: "checkmark") }
                        .tint(Theme.accentStrong)
                } else {
                    Button { store.setStatus(task.id, .todo) } label: { Label(l10n.t("ios.reopen"), systemImage: "arrow.uturn.backward") }
                        .tint(Theme.info)
                }
            }
            .swipeActions(edge: .trailing) {
                Button(role: .destructive) { onDelete(task.id) } label: { Label(l10n.t("actions.delete"), systemImage: "trash") }
                    .tint(Theme.danger)
            }
            .contextMenu {
                TaskContextMenu(task: task, onEdit: { onEdit(task.id) }, onDelete: { onDelete(task.id) })
            }
    }
}

struct TaskRow: View {
    @Environment(AppStore.self) private var store
    let task: TaskItem
    /// While selecting, the list draws its own selection circle; the status button is hidden.
    var selecting = false

    var body: some View {
        let l10n = store.l10n
        HStack(alignment: .top, spacing: 12) {
            if !selecting {
                Button {
                    store.setStatus(task.id, task.status == .done ? .todo : .done)
                } label: {
                    Image(systemName: task.status == .done ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(task.status == .done ? Theme.accent : Theme.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(l10n.t("list.changeStatus", ["title": task.title]))
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(task.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(task.status == .done ? Theme.textMuted : Theme.textPrimary)
                    .strikethrough(task.status == .done, color: Theme.textMuted)
                FlowLayout(spacing: 6) {
                    Menu {
                        ForEach(TaskStatus.allCases, id: \.self) { status in
                            Button(l10n.t("columns.\(status.rawValue)")) { store.setStatus(task.id, status) }
                        }
                    } label: {
                        Text(l10n.t("columns.\(task.status.rawValue)")).chip(Theme.status(task.status))
                    }
                    SubtaskProgressView(task: task, l10n: l10n)
                    if store.showCategory {
                        IconText(store.categoryName(of: task), systemImage: "folder")
                            .font(.caption)
                            .foregroundStyle(Theme.textMuted)
                    }
                    LabelChips(labels: task.labels)
                    if let planned = DueText.planned(task, l: l10n) {
                        IconText(planned, systemImage: "clock").font(.caption).foregroundStyle(Theme.info)
                    }
                    DueBadge(task: task, l10n: l10n, now: store.now, list: true)
                }
            }
            Spacer(minLength: 0)
            if !selecting { PriorityFlagMenu(task: task) }
        }
        .padding(.vertical, 12)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Priority on the card's edge.
        .cardSurface(stripe: Theme.priority(task.priority).opacity(task.status == .done ? 0.35 : 1))
        .opacity(task.status == .done ? 0.75 : 1)
    }
}

/// The flag on a row: shows the priority and changes it in one tap (as in Todoery).
struct PriorityFlagMenu: View {
    @Environment(AppStore.self) private var store
    let task: TaskItem

    var body: some View {
        let l10n = store.l10n
        Menu {
            Picker(l10n.t("priority.label"), selection: Binding(get: { task.priority }, set: { store.setPriority(task.id, $0) })) {
                ForEach([Priority.high, .medium, .low], id: \.self) { priority in
                    Label(l10n.t("priority.\(priority.rawValue)"), systemImage: priority == .high ? "flag.fill" : "flag").tag(priority)
                }
            }
        } label: {
            Image(systemName: task.priority == .low ? "flag" : "flag.fill")
                .font(.subheadline)
                .foregroundStyle(Theme.priority(task.priority))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("\(l10n.t("priority.label")): \(l10n.t("priority.\(task.priority.rawValue)"))")
    }
}

/// Due date for the selected tasks: quick choices, a calendar, or no due date.
struct BulkDueDateSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    var onPick: (String?) -> Void
    @LocalState private var date = Date()

    var body: some View {
        let l10n = store.l10n
        NavigationStack {
            Form {
                QuickDatesRow(onPick: { key in
                    onPick(key)
                    dismiss()
                })
                DatePicker(l10n.t("datePicker.choose"), selection: $date, displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .tint(Theme.accent)
                    .environment(\.locale, store.locale)
                Button(l10n.t("datePicker.clear"), role: .destructive) {
                    onPick(nil)
                    dismiss()
                }
            }
            .navigationTitle(l10n.t("bulk.dueDate"))
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(l10n.t("actions.cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(l10n.t("actions.save")) {
                        onPick(Schedule.localDateKey(date))
                        dismiss()
                    }
                }
            }
        }
        .sheetDetents()
    }
}

/// Quick due-date choices shared by every date picker: today, tomorrow, in 7 days, next week
/// (the first day of the next calendar week: Monday in Russian, Sunday in English).
struct QuickDatesRow: View {
    @Environment(AppStore.self) private var store
    var onPick: (String) -> Void

    static func keys(today: String, weekStart: Int) -> [(String, String)] {
        let weekday = Schedule.weekdayOf(today)
        let offset = (weekday - weekStart + 7) % 7
        return [
            ("today", today),
            ("tomorrow", Schedule.addDaysToKey(today, 1)),
            ("in7Days", Schedule.addDaysToKey(today, 7)),
            ("nextWeek", Schedule.addDaysToKey(today, 7 - offset)),
        ]
    }

    var body: some View {
        let l10n = store.l10n
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(Self.keys(today: store.todayKey, weekStart: store.settings.language.weekStart), id: \.0) { name, key in
                    Button {
                        onPick(key)
                    } label: {
                        VStack(spacing: 2) {
                            Text(l10n.t("datePicker.\(name)")).font(.footnote.weight(.semibold))
                            Text(l10n.formatDate(key)).font(.caption2).foregroundStyle(Theme.textMuted)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(l10n.t("datePicker.quickOption", ["name": l10n.t("datePicker.\(name)"), "date": l10n.formatDate(key)]))
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}
