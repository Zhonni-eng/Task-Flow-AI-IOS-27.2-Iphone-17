// Navigation - Sidebar.jsx, CategoryNameDialog.jsx and CategoryDeleteDialog.jsx on iPhone: All
// tasks, Uncategorized and the categories with their task counts; create, rename and delete
// categories (tasks of a deleted category are never deleted - they move to Uncategorized or
// another category the user picks).
import SwiftUI
import TaskflowCore

struct SidebarView: View {
    @Environment(AppStore.self) private var store
    @Binding var selection: Destination?
    var onSettings: () -> Void
    @LocalState private var naming: CategoryNaming?
    @LocalState private var deleting: TaskCategory?

    var body: some View {
        let l10n = store.l10n
        let counts = store.counts
        List(selection: $selection) {
            // The brand block of the Windows sidebar: logo mark, name and tagline.
            Section {
                HStack(spacing: 12) {
                    LogoMark().frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(l10n.t("app.name")).font(.title2.bold()).foregroundStyle(Theme.textPrimary)
                        Text(l10n.t("app.tagline")).font(.footnote).foregroundStyle(Theme.textMuted)
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
            }
            .listRowBackground(Color.clear)
            Section(l10n.t("nav.sectionTasks")) {
                row(l10n.t("nav.allTasks"), icon: "tray.full", count: counts[.all] ?? 0).tag(Destination.all)
                row(l10n.t("nav.uncategorized"), icon: "tray", count: counts[.uncategorized] ?? 0).tag(Destination.uncategorized)
            }
            .listRowBackground(Theme.bgSidebar)
            Section {
                ForEach(store.categories) { category in
                    row(category.name, icon: "folder", count: counts[.category(category.id)] ?? 0)
                        .tag(Destination.category(category.id))
                        .contextMenu {
                            Button { naming = CategoryNaming(category: category) } label: { Label(l10n.t("categories.rename"), systemImage: "pencil") }
                            Button(role: .destructive) { deleting = category } label: { Label(l10n.t("categories.delete"), systemImage: "trash") }
                        }
                        .swipeActions {
                            Button(role: .destructive) { deleting = category } label: { Label(l10n.t("categories.delete"), systemImage: "trash") }
                                .tint(Theme.danger)
                            Button { naming = CategoryNaming(category: category) } label: { Label(l10n.t("categories.rename"), systemImage: "pencil") }
                                .tint(Theme.info)
                        }
                }
                Button { naming = CategoryNaming(category: nil) } label: {
                    Label(l10n.t("categories.add"), systemImage: "plus.circle").foregroundStyle(Theme.accent)
                }
                if store.categories.isEmpty {
                    Text(l10n.t("categories.emptyHint")).font(.footnote).foregroundStyle(Theme.textMuted)
                }
            } header: {
                Text(l10n.t("nav.sectionCategories"))
            }
            .listRowBackground(Theme.bgSidebar)
            Section {
                Button(action: onSettings) { Label(l10n.t("appSettings.open"), systemImage: "gearshape") }
                    .foregroundStyle(Theme.textPrimary)
            }
            .listRowBackground(Theme.bgSidebar)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bgApp)
        .navigationTitle(l10n.t("app.name"))
        .hiddenNavigationBar()
        .sheet(item: $naming) { item in
            CategoryNameSheet(category: item.category).environment(store)
        }
        .sheet(item: $deleting) { category in
            CategoryDeleteSheet(category: category).environment(store)
        }
    }

    func row(_ title: String, icon: String, count: Int) -> some View {
        HStack {
            Label(title, systemImage: icon)
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            Text("\(count)")
                .font(.footnote.monospacedDigit())
                .foregroundStyle(Theme.textMuted)
                .accessibilityLabel(store.l10n.t("categories.taskCount", ["count": count]))
        }
    }
}

/// Taskflow's logo mark (scripts/icon/render-icon.cjs): three Kanban columns on the mint gradient.
struct LogoMark: View {
    var body: some View {
        GeometryReader { proxy in
            let size = min(proxy.size.width, proxy.size.height)
            let unit = size * 150 / 256 / 24
            let origin = (size - 24 * unit) / 2
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: size * 56 / 256, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.accent, Theme.hex(0x4FD6E6)], startPoint: .topLeading, endPoint: .bottomTrailing))
                ForEach(Array([(3.0, 5.0, 16.0), (10.0, 5.0, 10.0), (17.0, 4.0, 6.0)].enumerated()), id: \.offset) { _, bar in
                    RoundedRectangle(cornerRadius: 1.5 * unit)
                        .stroke(Theme.hex(0x06261E), lineWidth: 2.2 * unit)
                        .frame(width: bar.1 * unit, height: bar.2 * unit)
                        .offset(x: origin + bar.0 * unit, y: origin + 4 * unit)
                }
            }
            .frame(width: size, height: size)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

struct CategoryNaming: Identifiable {
    let id = UUID()
    let category: TaskCategory?
}

/// Create or rename a category (required, unique ignoring case and spaces).
struct CategoryNameSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let category: TaskCategory?
    @LocalState private var name = ""
    @LocalState private var error: CategoryModel.NameError?
    @FocusState private var focused: Bool

    var body: some View {
        let l10n = store.l10n
        NavigationStack {
            Form {
                Section {
                    TextField(l10n.t("categories.namePlaceholder"), text: $name)
                        .focused($focused)
                        .onSubmit(submit)
                        .onChange(of: name) {
                            error = nil
                            if name.count > CategoryModel.nameLimit { name = String(name.prefix(CategoryModel.nameLimit)) }
                        }
                } footer: {
                    if let error { Text(l10n.t("categories.errors.\(error.rawValue)")).foregroundStyle(Theme.danger) }
                }
                .listRowBackground(Theme.bgCard)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bgApp)
            .navigationTitle(category == nil ? l10n.t("categories.createTitle") : l10n.t("categories.renameTitle"))
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(l10n.t("actions.cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(category == nil ? l10n.t("categories.create") : l10n.t("categories.rename"), action: submit).fontWeight(.semibold)
                }
            }
            .onAppear {
                name = category?.name ?? ""
                focused = true
            }
        }
        .sheetDetents(large: false)
        .tint(Theme.accent)
    }

    func submit() {
        if let error = store.submitCategory(name: name, renaming: category?.id) {
            self.error = error
        } else {
            dismiss()
        }
    }
}

/// Deleting a category: its tasks are never deleted - choose where they go.
struct CategoryDeleteSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let category: TaskCategory
    @LocalState private var target: String?

    var body: some View {
        let l10n = store.l10n
        let count = store.counts[.category(category.id)] ?? 0
        let others = store.categories.filter { $0.id != category.id }
        NavigationStack {
            Form {
                Section {
                    Text(count == 0 ? l10n.t("categories.deleteEmpty") : l10n.t("categories.deleteHasTasks", ["count": count]))
                        .foregroundStyle(Theme.textSecondary)
                }
                .listRowBackground(Theme.bgCard)
                if count > 0 {
                    Section(l10n.t("categories.deleteChoice")) {
                        Picker(l10n.t("categories.targetCategory"), selection: $target) {
                            Text(l10n.t("categories.moveToUncategorized")).tag(String?.none)
                            ForEach(others) { other in
                                Text(other.name).tag(String?.some(other.id))
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    }
                    .listRowBackground(Theme.bgCard)
                }
                Section {
                    Button(role: .destructive) {
                        store.deleteCategory(category.id, moveTo: target)
                        dismiss()
                    } label: {
                        Text(l10n.t("categories.deleteConfirm")).frame(maxWidth: .infinity)
                    }
                }
                .listRowBackground(Theme.bgCard)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bgApp)
            .navigationTitle(l10n.t("categories.deleteTitle", ["name": category.name]))
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(l10n.t("actions.cancel")) { dismiss() } }
            }
        }
        .sheetDetents(large: false)
        .tint(Theme.accent)
    }
}
