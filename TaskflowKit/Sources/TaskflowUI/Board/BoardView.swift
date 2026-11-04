// The Kanban board on iPhone: the three columns side by side in a horizontally paging scroll view
// (the next column peeks in), with a column switcher that is also a drop target. Tasks are moved by
// touch-and-hold drag between and within columns - within columns only on the complete board in
// manual order, as on Windows - or from the context menu.
import SwiftUI
import TaskflowCore

struct BoardScreen: View {
    @Environment(AppStore.self) private var store
    var onEdit: (String) -> Void
    var onDelete: (String) -> Void
    @LocalState private var visibleColumn: TaskStatus? = .todo
    @LocalState private var targetedColumn: TaskStatus?
    @LocalState private var targetedTask: String?

    var columns: [TaskStatus] {
        store.view.statuses.isEmpty ? TaskStatus.allCases : TaskStatus.allCases.filter { store.view.statuses.contains($0) }
    }

    var body: some View {
        let board = store.boardView
        VStack(spacing: 0) {
            ColumnSwitcher(columns: columns, board: board, selected: $visibleColumn, targeted: $targetedColumn, onDrop: drop)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            // One full-width page per column (with its own margin), so paging and the column
            // switcher always land exactly on a column.
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 0) {
                    ForEach(columns, id: \.self) { status in
                        column(status, board: board)
                            .padding(.horizontal, 16)
                            .containerRelativeFrame(.horizontal)
                            .id(status)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $visibleColumn)
            .scrollIndicators(.hidden)
        }
    }

    func drop(_ ids: [String], on status: TaskStatus, before taskId: String?) -> Bool {
        guard let id = ids.first, store.task(id) != nil else { return false }
        Haptics.tap()
        if !store.dragAllowed {
            // Sorted or filtered: tasks can change columns but not their order.
            if store.task(id)?.status != status { store.move(id, to: status, visibleIndex: nil) }
            return true
        }
        let visible = (store.boardView.columns[status] ?? []).map(\.id).filter { $0 != id }
        let index = taskId.flatMap { visible.firstIndex(of: $0) } ?? visible.count
        store.move(id, to: status, visibleIndex: index)
        return true
    }

    @ViewBuilder
    func column(_ status: TaskStatus, board: TaskflowCore.BoardView) -> some View {
        let l10n = store.l10n
        let tasks = board.columns[status] ?? []
        let total = board.totals[status] ?? 0
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Circle().fill(Theme.status(status)).frame(width: 8, height: 8)
                Text(l10n.t("columns.\(status.rawValue)"))
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(store.filtering ? l10n.t("board.columnCountFiltered", ["shown": tasks.count, "total": total]) : "\(total)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Theme.bgElevated, in: Capsule())
                    .accessibilityLabel(l10n.t("board.columnTaskCount", ["count": total]))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            ScrollView(.vertical) {
                LazyVStack(spacing: 10) {
                    ForEach(tasks) { task in
                        TaskCardView(task: task, highlighted: targetedTask == task.id)
                            .onTapGesture { onEdit(task.id) }
                            .draggable(task.id) {
                                TaskCardView(task: task).frame(width: 260).environment(store)
                            }
                            .dropDestination(for: String.self) { ids, _ in
                                drop(ids, on: status, before: task.id)
                            } isTargeted: { targetedTask = $0 ? task.id : (targetedTask == task.id ? nil : targetedTask) }
                            .contextMenu {
                                TaskContextMenu(task: task, onEdit: { onEdit(task.id) }, onDelete: { onDelete(task.id) }, onMove: store.dragAllowed ? { offset in reorder(task, status: status, by: offset) } : nil)
                            }
                    }
                    if tasks.isEmpty {
                        Text(store.filtering && total > 0 ? l10n.t("board.columnNoMatches") : l10n.t("board.columnEmpty"))
                            .font(.footnote)
                            .foregroundStyle(Theme.textMuted)
                            .frame(maxWidth: .infinity, minHeight: 90)
                            .overlay(RoundedRectangle(cornerRadius: Theme.radiusMd).strokeBorder(Theme.borderDefault, style: StrokeStyle(lineWidth: 1, dash: [5])))
                    }
                    Color.clear.frame(height: 80)
                }
                .padding(.horizontal, 10)
            }
            .scrollIndicators(.hidden)
        }
        .background(targetedColumn == status ? Theme.accentSoft : Theme.bgColumn, in: RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusLg, style: .continuous).strokeBorder(targetedColumn == status ? Theme.accent.opacity(0.5) : Theme.borderSubtle))
        .dropDestination(for: String.self) { ids, _ in
            drop(ids, on: status, before: nil)
        } isTargeted: { targetedColumn = $0 ? status : (targetedColumn == status ? nil : targetedColumn) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(l10n.t("columns.\(status.rawValue)"))
    }

    /// "Move up / down" from the context menu (keyboard-free reordering).
    func reorder(_ task: TaskItem, status: TaskStatus, by offset: Int) {
        let visible = (store.boardView.columns[status] ?? []).map(\.id)
        guard let index = visible.firstIndex(of: task.id) else { return }
        let target = max(0, min(visible.count - 1, index + offset))
        guard target != index else { return }
        store.move(task.id, to: status, visibleIndex: target)
    }
}

/// Segmented column chips: tap to scroll to a column; drop a task on one to move it there.
struct ColumnSwitcher: View {
    @Environment(AppStore.self) private var store
    let columns: [TaskStatus]
    let board: TaskflowCore.BoardView
    @Binding var selected: TaskStatus?
    @Binding var targeted: TaskStatus?
    var onDrop: ([String], TaskStatus, String?) -> Bool

    var body: some View {
        HStack(spacing: 6) {
            ForEach(columns, id: \.self) { status in
                let isSelected = selected == status
                Button {
                    withAnimation(Theme.standard) { selected = status }
                } label: {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.status(status)).frame(width: 6, height: 6)
                        Text(store.l10n.t("columns.\(status.rawValue)"))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                        Text("\(board.columns[status]?.count ?? 0)")
                            .monospacedDigit()
                            .foregroundStyle(Theme.textMuted)
                    }
                    .font(.footnote.weight(.semibold))
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(isSelected ? Theme.textPrimary : Theme.textSecondary)
                    .background(targeted == status ? Theme.accentSoft : (isSelected ? Theme.bgElevated : Color.clear), in: RoundedRectangle(cornerRadius: Theme.radiusSm))
                }
                .buttonStyle(.plain)
                .dropDestination(for: String.self) { ids, _ in onDrop(ids, status, nil) } isTargeted: { targeted = $0 ? status : (targeted == status ? nil : targeted) }
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.bgSurface, in: RoundedRectangle(cornerRadius: Theme.radiusSm + 3))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSm + 3).strokeBorder(Theme.borderSubtle))
    }
}
