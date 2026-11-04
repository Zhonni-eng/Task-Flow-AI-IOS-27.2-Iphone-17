// The app's main screen - App.jsx's layout on iPhone: the sidebar (All tasks, Uncategorized,
// categories, settings) and the board or list of the selected destination, with search, filters
// and sorting, statistics, the storage notice, toasts, the task editor, the assistant and settings.
import SwiftUI
import TaskflowCore

public struct TaskflowRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    let store: AppStore
    let assistant: AssistantModel
    @LocalState private var sidebarSelection: Destination?
    @LocalState private var columnVisibility = NavigationSplitViewVisibility.automatic
    // On iPhone the board opens first; the sidebar is one tap back.
    @LocalState private var compactColumn = NavigationSplitViewColumn.detail

    public init(store: AppStore, assistant: AssistantModel) {
        self.store = store
        self.assistant = assistant
    }

    public var body: some View {
        @Bindable var store = store
        NavigationSplitView(columnVisibility: $columnVisibility, preferredCompactColumn: $compactColumn) {
            SidebarView(selection: $sidebarSelection, onSettings: { store.settingsOpen = true })
                .darkNavigationBar()
        } detail: {
            NavigationStack {
                MainScreen()
                    .darkNavigationBar()
            }
        }
        .sheet(isPresented: $store.settingsOpen) {
            SettingsView().environment(store).environment(assistant)
        }
        .environment(store)
        .environment(assistant)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
        .onAppear { sidebarSelection = store.activeDestination }
        .onChange(of: sidebarSelection) {
            if let selection = sidebarSelection { store.destination = selection }
        }
        .onChange(of: store.destination) { sidebarSelection = store.destination }
        .onChange(of: scenePhase) {
            switch scenePhase {
            case .background, .inactive:
                store.flush()
            case .active:
                store.refreshTime()
                Task { await assistant.refreshStatus() }
            @unknown default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in store.refreshTime() }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemClockDidChange)) { _ in store.refreshTime() }
    }
}

struct MainScreen: View {
    @Environment(AppStore.self) private var store
    @Environment(AssistantModel.self) private var assistant
    @LocalState private var editor: EditorRequest?
    @LocalState private var pendingDelete: String?
    @LocalState private var filtersOpen = false
    @LocalState private var assistantOpen = false
    @LocalState private var selecting = false
    @LocalState private var statsOpen = false

    var body: some View {
        @Bindable var store = store
        let l10n = store.l10n
        VStack(spacing: 0) {
            StorageNoticeView()
            CategoryChipsBar()
            StatsBar()
            ViewStatusBar()
            content
        }
        .background(Theme.bgApp.ignoresSafeArea())
        .navigationTitle(store.destinationTitle)
        .searchable(text: $store.view.query, prompt: Text(l10n.t("toolbar.searchPlaceholder")))
        .toolbar { toolbar }
        .overlay(alignment: .top) { ToastsView() }
        .sheet(item: $editor) { request in
            TaskEditorView(taskId: request.taskId, task: request.taskId.flatMap(store.task), defaultCategoryId: store.selectedCategory?.id, defaultDueDate: request.dueDate) { id in
                editor = nil
                pendingDelete = id
            }
            .environment(store)
        }
        .sheet(isPresented: $filtersOpen) { FilterSortSheet().environment(store) }
        .sheet(isPresented: $statsOpen) { ProgressSheet().environment(store) }
        .sheet(isPresented: $assistantOpen) {
            AssistantView().environment(store).environment(assistant)
        }
        .alert(l10n.t("confirmDelete.title"), isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button(l10n.t("confirmDelete.confirm"), role: .destructive) {
                if let id = pendingDelete { store.deleteTask(id) }
                pendingDelete = nil
            }
            Button(l10n.t("actions.cancel"), role: .cancel) { pendingDelete = nil }
        } message: {
            Text(l10n.t("confirmDelete.message", ["title": pendingDelete.flatMap(store.task)?.title ?? ""]))
        }
        .onChange(of: store.taskToOpen) {
            if let id = store.taskToOpen, store.task(id) != nil {
                editor = EditorRequest(taskId: id)
            }
            store.taskToOpen = nil
        }
        .onChange(of: store.layout) { selecting = false }
        .onChange(of: store.showCalendar) { selecting = false }
    }

    @ViewBuilder
    var content: some View {
        let l10n = store.l10n
        let board = store.visibleCount
        if store.filtering && board.shown == 0 && board.total > 0 {
            ContentUnavailableView {
                Label(l10n.t("view.noMatches"), systemImage: "magnifyingglass")
            } description: {
                Text(l10n.t("view.noMatchesHint"))
            } actions: {
                Button(l10n.t("view.resetAll")) { store.resetView() }
            }
            .frame(maxHeight: .infinity)
        } else if board.total == 0 {
            ContentUnavailableView {
                Label(l10n.t("ios.empty"), systemImage: "tray")
            } description: {
                Text(store.activeDestination == .all ? l10n.t("view.noTasksYet") : l10n.t("view.categoryEmpty"))
            } actions: {
                Button(l10n.t("actions.newTask")) { editor = EditorRequest(taskId: nil) }
            }
            .frame(maxHeight: .infinity)
        } else if store.showCalendar {
            CalendarScreen(onEdit: { editor = EditorRequest(taskId: $0) }, onDelete: { pendingDelete = $0 }, onNew: { key in editor = EditorRequest(taskId: nil, dueDate: key) })
        } else if store.layout == .list {
            TaskListView(onEdit: { editor = EditorRequest(taskId: $0) }, onDelete: { pendingDelete = $0 }, selecting: $selecting)
        } else {
            BoardScreen(onEdit: { editor = EditorRequest(taskId: $0) }, onDelete: { pendingDelete = $0 })
        }
    }

    @ToolbarContentBuilder
    var toolbar: some ToolbarContent {
        let l10n = store.l10n
        if !selecting {
            ToolbarItem(placement: .trailingBar) {
                Button { editor = EditorRequest(taskId: nil) } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel(l10n.t("actions.newTask"))
            }
        }
        ToolbarItem(placement: .trailingBar) {
            Button { assistantOpen = true } label: {
                Image(systemName: "sparkles")
            }
            .accessibilityLabel(l10n.t("assistant.open"))
        }
        ToolbarItem(placement: .trailingBar) {
            Menu {
                Picker(l10n.t("layout.label"), selection: Binding(get: { store.showCalendar ? nil : store.layout }, set: { layout in
                    store.showCalendar = layout == nil
                    if let layout { store.layout = layout }
                })) {
                    Label(l10n.t("layout.board"), systemImage: "rectangle.split.3x1").tag(BoardLayout?.some(.board))
                    Label(l10n.t("layout.list"), systemImage: "list.bullet").tag(BoardLayout?.some(.list))
                    Label(l10n.t("ios.calendar"), systemImage: "calendar").tag(BoardLayout?.none)
                }
                Button { statsOpen = true } label: { Label(l10n.t("ios.progress"), systemImage: "chart.bar") }
                Button { filtersOpen = true } label: { Label(l10n.t("ios.sortAndFilter"), systemImage: "line.3.horizontal.decrease.circle") }
                if store.layout == .list && !store.showCalendar {
                    Button { selecting.toggle() } label: { Label(selecting ? l10n.t("ios.done") : l10n.t("ios.select"), systemImage: "checkmark.circle") }
                }
                if let category = store.selectedCategory {
                    Divider()
                    Text(category.name)
                }
                Divider()
                Button { store.settingsOpen = true } label: { Label(l10n.t("appSettings.open"), systemImage: "gearshape") }
            } label: {
                Image(systemName: store.viewChanged ? "line.3.horizontal.decrease.circle.fill" : "ellipsis.circle")
            }
            .accessibilityLabel(l10n.t("ios.more"))
        }
        if selecting {
            ToolbarItem(placement: .leadingBar) {
                Button(l10n.t("ios.done")) { selecting = false }
            }
        }
    }
}

struct EditorRequest: Identifiable {
    let id = UUID()
    let taskId: String?
    /// A new task's due date (from the calendar).
    var dueDate: String? = nil
}

/// Save failures (with Retry) and what happened when the data was loaded.
struct StorageNoticeView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        let l10n = store.l10n
        if store.saveFailed {
            banner(
                title: l10n.t("storage.saveFailed"),
                detail: store.writable ? l10n.t("storage.saveFailedDetail") : nil,
                color: Theme.danger
            ) {
                if store.writable { Button(l10n.t("storage.retry")) { store.retrySave() }.font(.footnote.weight(.semibold)) }
            }
        } else if let notice = store.loadNotice {
            banner(
                title: l10n.t(notice.key),
                detail: notice.copyName.map { l10n.t("storage.copySaved", ["file": $0]) },
                color: notice.key == "storage.repaired" ? Theme.warning : Theme.danger
            ) {
                Button(l10n.t("storage.dismiss")) { store.loadNotice = nil }.font(.footnote.weight(.semibold))
            }
        }
    }

    func banner(title: String, detail: String?, color: Color, @ViewBuilder actions: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.footnote.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                if let detail { Text(detail).font(.caption).foregroundStyle(Theme.textSecondary) }
            }
            Spacer()
            actions()
        }
        .padding(12)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.radiusMd))
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
    }
}

struct ToastsView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 6) {
            ForEach(store.toasts) { toast in
                HStack(spacing: 8) {
                    Image(systemName: toast.isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .foregroundStyle(toast.isError ? Theme.danger : Theme.accent)
                    Text(toast.message).font(.footnote).foregroundStyle(Theme.textPrimary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.bgElevated, in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.borderStrong))
                .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                .onTapGesture { store.dismissToast(toast) }
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityAddTraits(.isStaticText)
            }
        }
        .padding(.top, 4)
        .animation(Theme.standard, value: store.toasts)
        .allowsHitTesting(!store.toasts.isEmpty)
    }
}

// MARK: - Composition

public enum TaskflowApp {
    /// Folders: the app's private Application Support folder for the store, AI settings and reminder
    /// records; the Documents folder (visible in the Files app) for the Windows-format backup copies.
    public static var supportDirectory: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Taskflow", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static var backupDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// `backup`: where the Windows-format copy is written after every save (nil when the repository
    /// itself is that file).
    @MainActor
    public static func makeModels(repository: TaskRepository, backup: DocumentFileStore?) -> (AppStore, AssistantModel) {
        let notifier = ReminderNotifier(directory: supportDirectory)
        let store = AppStore(repository: repository, backup: backup, notifier: notifier)
        let settings = AISettings(directory: supportDirectory, secrets: KeychainSecretStore())
        let assistant = AssistantModel(settings: settings, transport: URLSessionTransport(), store: store)
        return (store, assistant)
    }
}
