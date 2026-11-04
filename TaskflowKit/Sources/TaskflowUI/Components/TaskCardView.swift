// A task card - the hierarchy of TaskCard.jsx: priority on top, then title and description, and a
// footer with subtask progress, category, labels, the planned slot and the due date. Overdue and
// due-today dates differ by icon and wording, not only by color.
import SwiftUI
import TaskflowCore

struct PriorityTag: View {
    let priority: Priority
    let l10n: L10n

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(Theme.priority(priority)).frame(width: 6, height: 6)
            Text(l10n.t("priority.\(priority.rawValue)"))
        }
        .font(.caption2.weight(.semibold))
        .textCase(.uppercase)
        .foregroundStyle(Theme.priority(priority))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(l10n.t("priority.label")): \(l10n.t("priority.\(priority.rawValue)"))")
    }
}

struct DueBadge: View {
    let task: TaskItem
    let l10n: L10n
    let now: Date
    var list = false

    var body: some View {
        if let due = DueText.make(task, l: l10n, list: list, now: now) {
            HStack(spacing: 4) {
                Image(systemName: icon(due.state))
                Text(due.text)
                if due.repeats != nil { Image(systemName: "repeat") }
                if due.reminders != nil { Image(systemName: "bell.fill") }
            }
            .font(.caption.weight(due.state == .overdue || due.state == .today ? .semibold : .regular))
            .foregroundStyle(color(due.state))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(background(due.state), in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([due.description, due.repeats, due.reminders].compactMap { $0 }.joined(separator: ". "))
        }
    }

    func icon(_ state: DueState) -> String {
        switch state {
        case .overdue: return "exclamationmark.triangle.fill"
        case .today: return "clock.fill"
        default: return "calendar"
        }
    }

    func color(_ state: DueState) -> Color {
        switch state {
        case .overdue: return Theme.danger
        case .today: return Theme.warning
        case .tomorrow: return Theme.info
        default: return Theme.textMuted
        }
    }

    func background(_ state: DueState) -> Color {
        switch state {
        case .overdue: return Theme.dangerSoft
        case .today: return Theme.warningSoft
        case .tomorrow: return Theme.infoSoft
        default: return .clear
        }
    }
}

struct SubtaskProgressView: View {
    let task: TaskItem
    let l10n: L10n

    var body: some View {
        if let progress = Subtasks.progress(task) {
            HStack(spacing: 4) {
                Image(systemName: progress.done == progress.total ? "checklist.checked" : "checklist")
                Text("\(progress.done)/\(progress.total)")
                    .monospacedDigit()
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(progress.done == progress.total ? Theme.accent : Theme.textSecondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(l10n.t("subtasks.progress", ["done": progress.done, "total": progress.total]))
        }
    }
}

/// An icon and a text in one line - unlike Label it never takes the list-row layout of a Form or
/// List, so it is safe inside wrapping rows.
struct IconText: View {
    let text: String
    let systemImage: String
    var spacing: CGFloat = 4

    init(_ text: String, systemImage: String, spacing: CGFloat = 4) {
        self.text = text
        self.systemImage = systemImage
        self.spacing = spacing
    }

    var body: some View {
        HStack(spacing: spacing) {
            Image(systemName: systemImage)
            Text(text)
        }
    }
}

struct LabelChips: View {
    let labels: [String]

    var body: some View {
        ForEach(labels, id: \.self) { label in
            Text(label).chip(Theme.label(label))
        }
    }
}

/// A wrapping row (labels and metadata wrap onto several lines on a narrow screen).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        // The proposed width, so that placement wraps exactly as measured here.
        return CGSize(width: proposal.width ?? maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

struct TaskCardView: View {
    @Environment(AppStore.self) private var store
    let task: TaskItem
    var highlighted = false

    var body: some View {
        let l10n = store.l10n
        let done = task.status == .done
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                PriorityTag(priority: task.priority, l10n: l10n)
                Spacer()
                if done {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Theme.accent)
                        .accessibilityLabel(l10n.t("task.completed"))
                }
            }
            Text(task.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(done ? Theme.textMuted : Theme.textPrimary)
                .strikethrough(done, color: Theme.textMuted)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if !task.description.isEmpty {
                Text(task.description)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(2)
            }
            let showCategory = store.showCategory
            if !task.labels.isEmpty || task.dueDate != nil || showCategory || !task.subtasks.isEmpty || task.planned != nil {
                FlowLayout(spacing: 6) {
                    SubtaskProgressView(task: task, l10n: l10n)
                    if showCategory {
                        IconText(store.categoryName(of: task), systemImage: "folder")
                            .font(.caption)
                            .foregroundStyle(Theme.textMuted)
                            .accessibilityLabel("\(l10n.t("taskForm.category")): \(store.categoryName(of: task))")
                    }
                    LabelChips(labels: task.labels)
                    if let planned = DueText.planned(task, l: l10n) {
                        IconText(planned, systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(Theme.info)
                    }
                    DueBadge(task: task, l10n: l10n, now: store.now)
                }
            }
        }
        .padding(EdgeInsets(top: 14, leading: 14, bottom: 12, trailing: 14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(highlighted: highlighted)
        .contentShape(RoundedRectangle(cornerRadius: Theme.radiusMd))
        .accessibilityElement(children: .combine)
    }
}

/// The actions every task offers by long press (no gesture-only features).
struct TaskContextMenu: View {
    @Environment(AppStore.self) private var store
    let task: TaskItem
    var onEdit: () -> Void
    var onDelete: () -> Void
    var onMove: ((Int) -> Void)?

    var body: some View {
        let l10n = store.l10n
        Button(action: onEdit) { Label(l10n.t("actions.edit"), systemImage: "pencil") }
        if task.status != .done {
            Button { store.setStatus(task.id, .done) } label: { Label(l10n.t("ios.complete"), systemImage: "checkmark.circle") }
        } else {
            Button { store.setStatus(task.id, .todo) } label: { Label(l10n.t("ios.reopen"), systemImage: "arrow.uturn.backward.circle") }
        }
        Menu {
            ForEach(TaskStatus.allCases, id: \.self) { status in
                Button(l10n.t("columns.\(status.rawValue)")) { store.setStatus(task.id, status) }
                    .disabled(status == task.status)
            }
        } label: { Label(l10n.t("ios.moveTo"), systemImage: "arrow.left.arrow.right") }
        if let onMove {
            Button { onMove(-1) } label: { Label(l10n.t("ios.moveUp"), systemImage: "arrow.up") }
            Button { onMove(1) } label: { Label(l10n.t("ios.moveDown"), systemImage: "arrow.down") }
        }
        Divider()
        Button(role: .destructive, action: onDelete) { Label(l10n.t("actions.delete"), systemImage: "trash") }
    }
}
