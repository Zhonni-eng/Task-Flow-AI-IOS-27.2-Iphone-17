// The app's state and its operations - the iPhone counterpart of App.jsx: tasks and categories
// (through the ported reducers), settings, navigation (destination, layout, search, filters, sort),
// toasts, saving with a visible failure state and Retry, reminders, and import/export of the
// Windows data file.
//
// Persistence is local-first behind TaskRepository (SwiftData in the app; a JSON file as fallback).
// After every successful save a copy in the Windows format is written to the backup folder
// (taskflow-data.json + .bak), so the data can always be recovered or moved to Windows.
import Foundation
import Observation
import SwiftUI
import TaskflowCore

/// Where the board is stored. Saving is synchronous and atomic; `load` reports what happened.
@MainActor
public protocol TaskRepository: AnyObject {
    func load() -> LoadResult
    /// Stores the document, which the caller already normalized (DocumentCodec.normalizedForSave).
    func save(_ document: TaskflowDocument) throws
    /// Replaces everything (import); the default is a normal save.
    func replaceAll(with document: TaskflowDocument) throws
}

public extension TaskRepository {
    func replaceAll(with document: TaskflowDocument) throws { try save(document) }
}

/// The JSON-file repository (also the format of the backup copy and of exports).
@MainActor
public final class FileTaskRepository: TaskRepository {
    let store: DocumentFileStore
    public init(store: DocumentFileStore) { self.store = store }
    public func load() -> LoadResult { store.load() }
    public func save(_ document: TaskflowDocument) throws { try store.save(document, normalized: true) }
}

public struct Toast: Identifiable, Equatable {
    public let id = UUID()
    public var message: String
    public var isError: Bool
}

/// The notice shown after loading (storage.* texts) - with the name of a preserved copy, if any.
public struct LoadNotice: Equatable {
    public var key: String
    public var copyName: String?
}

public enum ImportCheck {
    case ready(DocumentCodec.Result, Data)
    case failed(String)
}

@MainActor
@Observable
public final class AppStore {
    public private(set) var tasks: [TaskItem] = [] {
        didSet { tasksRevision &+= 1 }
    }
    /// Changes with every change of `tasks`; the cheap key for derived values (comparing the
    /// task arrays themselves would cost as much as recomputing).
    public private(set) var tasksRevision = 0
    public private(set) var categories: [TaskCategory] = []
    public private(set) var settings = AppSettings()
    /// On iPhone the tasks are sorted by due date unless the user picks another order (remembered
    /// on this device; the Windows data file has no place for it).
    public static let defaultView = ViewState(sort: .dueDate)
    public var view = AppStore.restoredView() {
        didSet { if oldValue.sort != view.sort { UserDefaults.standard.set(view.sort.rawValue, forKey: Self.sortKey) } }
    }
    /// The calendar replaces the board or list while on (remembered on this device; the data file's
    /// layout stays board or list).
    public var showCalendar = UserDefaults.standard.bool(forKey: AppStore.calendarKey) {
        didSet { UserDefaults.standard.set(showCalendar, forKey: Self.calendarKey) }
    }
    static let sortKey = "taskflow.sort"
    static let calendarKey = "taskflow.calendar"

    static func restoredView() -> ViewState {
        let sort = UserDefaults.standard.string(forKey: sortKey).flatMap(SortMode.init(rawValue:)) ?? defaultView.sort
        return ViewState(sort: sort)
    }

    /// Search, filters or a non-default sort are active.
    public var viewChanged: Bool { filtering || view.sort != Self.defaultView.sort }

    public func resetView() { view = Self.defaultView }
    public var destination: Destination = .all {
        didSet { if oldValue != destination { rememberView() } }
    }
    public var layout: BoardLayout = .board {
        didSet { if oldValue != layout { rememberView() } }
    }
    public var toasts: [Toast] = []
    public private(set) var saveFailed = false
    public private(set) var writable = true
    public var loadNotice: LoadNotice?
    /// Current time, refreshed every minute and at midnight (overdue/today states follow it).
    public private(set) var now = Date()
    /// A task to open (from a tapped reminder).
    public var taskToOpen: String?
    public var settingsOpen = false

    let repository: TaskRepository
    let backup: DocumentFileStore?
    /// The Windows-format copy is prepared and written here, in order, off the main thread: it is
    /// a second copy (the repository has already stored the data when it is written).
    private let backupQueue = DispatchQueue(label: "taskflow.backup", qos: .utility)
    let notifier: ReminderNotifier?
    private var saveTask: Task<Void, Never>?
    private var clockTask: Task<Void, Never>?
    private var pendingSave = false
    private var loading = false

    public var l10n: L10n { L10n(settings.language) }
    public var locale: Locale { settings.language.locale }
    public var todayKey: String { Schedule.localDateKey(now) }

    public init(repository: TaskRepository, backup: DocumentFileStore?, notifier: ReminderNotifier?) {
        self.repository = repository
        self.backup = backup
        self.notifier = notifier
        if let backup {
            // Reading the copy decides whether it may be written (never over a newer version's
            // file); queued first, so it happens before any write.
            backupQueue.async { _ = backup.load() }
        }
        load()
        notifier?.onOpenTask = { [weak self] id in self?.taskToOpen = id }
        startClock()
    }

    // MARK: Loading

    func load() {
        loading = true
        defer { loading = false }
        let result = repository.load()
        writable = result.writable
        var document = result.document ?? TaskflowDocument.empty()
        let firstLaunch = result.status == .new
        if firstLaunch {
            // Demo tasks in the language active at startup; afterwards ordinary user content.
            document.tasks = SampleTasks.create(L10n(document.settings.language))
        }
        let known = Set(document.categories.map(\.id))
        categories = CategoryModel.restore(document.categories.map(\.json))
        tasks = Tasks.restore(document.tasks.map(\.json)).map { task in
            guard let categoryId = task.categoryId, !known.contains(categoryId) else { return task }
            var copy = task
            copy.categoryId = nil
            return copy
        }
        settings = document.settings
        destination = Destination(storageKey: settings.lastView.destination)
        if case .category(let id) = destination, !known.contains(id) { destination = .all }
        layout = settings.lastView.layout
        let copyName = (result.preservedCopy ?? result.preservedBackup)?.lastPathComponent
        switch result.status {
        case .recovered: loadNotice = LoadNotice(key: "storage.recovered", copyName: copyName)
        case .unreadable: loadNotice = LoadNotice(key: "storage.unreadable", copyName: copyName)
        case .repaired: loadNotice = LoadNotice(key: "storage.repaired", copyName: copyName)
        case .newerVersion: loadNotice = LoadNotice(key: "storage.newerVersion", copyName: nil)
        case .readError: loadNotice = LoadNotice(key: "storage.readError", copyName: nil)
        case .new, .loaded, .migrated: loadNotice = nil
        }
        // A first launch stores the demo tasks; data recovered from the backup copy is stored at
        // once too - otherwise the repository stayed empty until the next edit and every launch
        // recovered (and reported it) again.
        if firstLaunch || result.status == .recovered { scheduleSave(immediately: true) } else { syncReminders() }
    }

    public var document: TaskflowDocument {
        var current = settings
        current.lastView = LastView(destination: destination.storageKey, layout: layout)
        return TaskflowDocument(settings: current, categories: categories, tasks: tasks)
    }

    // MARK: Saving

    /// Saves soon (several quick changes become one save).
    func scheduleSave(immediately: Bool = false) {
        pendingSave = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            if !immediately { try? await Task.sleep(nanoseconds: 300_000_000) }
            guard !Task.isCancelled else { return }
            _ = self?.saveNow()
        }
    }

    /// Saves at once; true when the data is safely stored. Success of an assistant change is
    /// reported only after this returned true.
    @discardableResult
    public func saveNow() -> Bool {
        saveTask?.cancel()
        pendingSave = false
        guard writable else {
            saveFailed = true
            return false
        }
        let document = DocumentCodec.normalizedForSave(self.document)
        do {
            try repository.save(document)
            saveFailed = false
        } catch {
            saveFailed = true
            return false
        }
        writeBackup(document)
        syncReminders()
        return true
    }

    /// The Windows-format copy; a failure here never loses data (the repository saved it).
    private func writeBackup(_ normalized: TaskflowDocument) {
        guard let backup else { return }
        backupQueue.async { try? backup.save(normalized, normalized: true) }
    }

    /// Waits until queued copies are on disk (before the app is suspended).
    func finishBackups() {
        backupQueue.sync {}
    }

    public func retrySave() { saveNow() }

    /// Saves any pending change now (when the app goes to the background).
    public func flush() {
        if pendingSave { saveNow() }
        finishBackups()
    }

    private func rememberView() {
        guard !loading else { return }
        settings.lastView = LastView(destination: destination.storageKey, layout: layout)
        scheduleSave()
    }

    // MARK: Clock

    private func startClock() {
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                let seconds = 60 - Calendar.current.component(.second, from: Date())
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                guard let self else { return }
                let previousDay = self.todayKey
                self.now = Date()
                if self.todayKey != previousDay { self.syncReminders() }
            }
        }
    }

    /// The app became active again, or the clock / time zone changed.
    public func refreshTime() {
        now = Date()
        syncReminders()
    }

    func syncReminders() {
        guard let notifier else { return }
        let tasks = self.tasks, settings = self.settings
        Task { await notifier.sync(tasks: tasks, settings: settings.reminders, language: settings.language) }
    }

    // MARK: Toasts

    public func notify(_ message: String, error: Bool = false) {
        let toast = Toast(message: message, isError: error)
        toasts.append(toast)
        if toasts.count > 3 { toasts.removeFirst(toasts.count - 3) }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: error ? 6_000_000_000 : 3_500_000_000)
            self?.toasts.removeAll { $0.id == toast.id }
        }
    }

    public func dismissToast(_ toast: Toast) { toasts.removeAll { $0.id == toast.id } }

    // MARK: Tasks

    public func dispatch(_ action: TaskAction) {
        tasks = tasksReducer(tasks, action)
        scheduleSave()
    }

    public func dispatchCategory(_ action: CategoryAction) {
        categories = categoriesReducer(categories, action)
        scheduleSave()
    }

    public func task(_ id: String) -> TaskItem? { tasks.first { $0.id == id } }
    public func category(_ id: String?) -> TaskCategory? { id.flatMap { id in categories.first { $0.id == id } } }

    /// The selected category, if the destination is one.
    public var selectedCategory: TaskCategory? {
        if case .category(let id) = destination { return category(id) }
        return nil
    }

    public var activeDestination: Destination {
        if case .category(let id) = destination, category(id) == nil { return .all }
        return destination
    }

    public var destinationTitle: String {
        switch activeDestination {
        case .all: return l10n.t("nav.allTasks")
        case .uncategorized: return l10n.t("nav.uncategorized")
        case .category: return selectedCategory?.name ?? l10n.t("nav.allTasks")
        }
    }

    // MARK: Derived values
    //
    // Views read these many times per update (the toolbar, status bar, sidebar rows and chips all
    // ask for counts or the board), so each is computed once per change of what it depends on.
    // The key is built from observed properties, so reading a value still registers the view's
    // dependency on them.

    private struct MemoEntry {
        let key: AnyHashable
        let value: Any
    }

    @ObservationIgnored private var memos: [String: MemoEntry] = [:]

    private func memo<Key: Hashable, Value>(_ name: String, _ key: Key, _ make: () -> Value) -> Value {
        let key = AnyHashable(key)
        if let entry = memos[name], entry.key == key, let value = entry.value as? Value { return value }
        let value = make()
        memos[name] = MemoEntry(key: key, value: value)
        return value
    }

    private struct ScopeKey: Hashable {
        let revision: Int
        let destination: Destination
    }

    private struct ViewKey: Hashable {
        let revision: Int
        let destination: Destination
        let view: ViewState
        let language: Language
        let day: String
    }

    private var scopeKey: ScopeKey { ScopeKey(revision: tasksRevision, destination: activeDestination) }
    private var viewKey: ViewKey { ViewKey(revision: tasksRevision, destination: activeDestination, view: view, language: settings.language, day: todayKey) }

    public var scopedTasks: [TaskItem] { memo("scoped", scopeKey) { TaskViews.scope(tasks, activeDestination) } }
    public var counts: [Destination: Int] { memo("counts", tasksRevision) { TaskViews.countByCategory(tasks) } }
    public var boardView: BoardView { memo("board", viewKey) { TaskViews.board(scopedTasks, view, locale: locale, todayKey: todayKey) } }
    /// Sections of the List view. Their order depends on the current time (a task due today at
    /// 16:30 becomes overdue at 16:30), so they follow `now`.
    public var listSections: [(section: TaskViews.Section, tasks: [TaskItem])] {
        memo("sections", [AnyHashable(viewKey), AnyHashable(now)]) { TaskViews.sections(scopedTasks, view, locale: locale, now: now) }
    }
    /// The tasks shown in the List view (for selection and bulk actions).
    public var listTasks: [TaskItem] {
        memo("listTasks", [AnyHashable(viewKey), AnyHashable(now)]) { listSections.flatMap(\.tasks) }
    }
    /// Tasks matching search and filters within the destination, and all tasks there.
    public var visibleCount: (shown: Int, total: Int) {
        memo("visibleCount", viewKey) { (TaskViews.filtered(scopedTasks, view, todayKey: todayKey).count, scopedTasks.count) }
    }
    /// Visible tasks by due date, for the calendar.
    public var tasksByDate: [String: [TaskItem]] {
        memo("byDate", viewKey) { TaskViews.tasksByDate(TaskViews.filtered(scopedTasks, view, todayKey: todayKey)) }
    }
    public var stats: TaskStats { memo("stats", [AnyHashable(scopeKey), AnyHashable(now)]) { TaskViews.stats(scopedTasks, now: now) } }
    public var labelSuggestions: [String] { memo("labels", tasksRevision) { Tasks.collectLabels(tasks) } }
    public var dragAllowed: Bool { TaskViews.isDragAllowed(view) }
    public var filtering: Bool { TaskViews.isFiltering(view) }
    public var showCategory: Bool { activeDestination == .all }

    public func categoryName(of task: TaskItem) -> String {
        category(task.categoryId)?.name ?? l10n.t("nav.uncategorized")
    }

    /// Creates or saves a task from the editor's fields (JSON field names, as the form produces).
    public func submitTask(editing id: String?, fields: [String: JSONValue]) {
        let title = (fields["title"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let id, let task = task(id) {
            var changes = fields
            // A status change from the editor goes through the board rule (recurring tasks move on).
            if let status = fields["status"]?.stringValue.flatMap(TaskStatus.init(rawValue:)), status != task.status {
                changes["status"] = nil
                tasks = tasksReducer(tasks, .update(id: id, changes: changes))
                tasks = tasksReducer(tasks, .move(id: id, status: status, index: Tasks.column(tasks, status).count))
                scheduleSave()
            } else {
                dispatch(.update(id: id, changes: changes))
            }
            notify(l10n.t("toast.taskUpdated", ["title": title]))
        } else {
            dispatch(.create(TaskModel.createTask(fields)))
            notify(l10n.t("toast.taskCreated", ["title": title]))
        }
    }

    public func deleteTask(_ id: String) {
        guard let task = task(id) else { return }
        notify(l10n.t("toast.taskDeleted", ["title": task.title]))
        dispatch(.remove(id: id))
    }

    /// List / menu status change: the task goes to the end of its new column.
    public func setStatus(_ id: String, _ status: TaskStatus) {
        guard let task = task(id), task.status != status else { return }
        dispatch(.move(id: id, status: status, index: Tasks.column(tasks, status).count))
        if status == .done { Haptics.success() }
        notify(l10n.t("toast.statusChanged", ["title": task.title, "status": l10n.t("columns.\(status.rawValue)")]))
    }

    /// A drop on the board. `visibleIndex` nil: a status change from a sorted or filtered board - the
    /// task goes to the end of its new column's manual order. Otherwise the position within the
    /// visible (category-scoped) column is converted to the full column.
    public func move(_ id: String, to status: TaskStatus, visibleIndex: Int?) {
        guard let visibleIndex else {
            dispatch(.move(id: id, status: status, index: Int.max))
            return
        }
        let fullIds = Tasks.column(tasks, status).map(\.id)
        let visibleIds = (boardView.columns[status] ?? []).map(\.id)
        dispatch(.move(id: id, status: status, index: TaskViews.toFullColumnIndex(fullIds: fullIds, visibleIds: visibleIds, taskId: id, visibleIndex: visibleIndex)))
    }

    /// Priority from the flag menu on a row.
    public func setPriority(_ id: String, _ priority: Priority) {
        guard let task = task(id), task.priority != priority else { return }
        dispatch(.update(id: id, changes: ["priority": .string(priority.rawValue)]))
        Haptics.tap()
    }

    // MARK: Bulk actions (List view)

    /// Tasks that still exist among the selected ids; nil (with a notice) when none remain.
    private func selected(_ ids: Set<String>) -> [TaskItem]? {
        let targets = tasks.filter { ids.contains($0.id) }
        if targets.isEmpty {
            notify(l10n.t("toast.bulkUnavailable"), error: true)
            return nil
        }
        return targets
    }

    private func finishBulk(_ changed: Int, _ key: String, _ params: [String: CustomStringConvertible] = [:]) {
        var all = params
        all["count"] = changed
        notify(changed > 0 ? l10n.t(key, all) : l10n.t("toast.bulkNoChange"))
    }

    public func bulkSetStatus(_ ids: Set<String>, _ status: TaskStatus) {
        guard let targets = selected(ids) else { return }
        let changing = targets.filter { $0.status != status }
        if !changing.isEmpty { dispatch(.bulkMove(ids: changing.map(\.id), status: status)) }
        finishBulk(changing.count, status == .done ? "toast.bulkCompleted" : "toast.bulkStatus", ["status": l10n.t("columns.\(status.rawValue)")])
    }

    public func bulkSetPriority(_ ids: Set<String>, _ priority: Priority) {
        guard let targets = selected(ids) else { return }
        let changing = targets.filter { $0.priority != priority }
        if !changing.isEmpty { dispatch(.bulkUpdate(ids: changing.map(\.id), changes: ["priority": .string(priority.rawValue)])) }
        finishBulk(changing.count, "toast.bulkPriority", ["priority": l10n.t("priority.\(priority.rawValue)")])
    }

    public func bulkSetCategory(_ ids: Set<String>, _ categoryId: String?) {
        // Only existing categories (or uncategorized) can be assigned; nothing is created.
        if let categoryId, category(categoryId) == nil {
            notify(l10n.t("toast.bulkUnavailable"), error: true)
            return
        }
        guard let targets = selected(ids) else { return }
        let changing = targets.filter { $0.categoryId != categoryId }
        if !changing.isEmpty { dispatch(.bulkUpdate(ids: changing.map(\.id), changes: ["categoryId": .from(categoryId)])) }
        finishBulk(changing.count, "toast.bulkCategory", ["category": category(categoryId)?.name ?? l10n.t("nav.uncategorized")])
    }

    public func bulkSetDueDate(_ ids: Set<String>, _ dateKey: String?) {
        if let dateKey, !Schedule.isDateKey(dateKey) { return }
        guard let targets = selected(ids) else { return }
        let changing = targets.filter { $0.dueDate != dateKey }
        if !changing.isEmpty { dispatch(.bulkUpdate(ids: changing.map(\.id), changes: ["dueDate": .from(dateKey)])) }
        if let dateKey {
            finishBulk(changing.count, "toast.bulkDueDate", ["date": l10n.formatDate(dateKey, .long)])
        } else {
            finishBulk(changing.count, "toast.bulkDueCleared")
        }
    }

    public func bulkDelete(_ ids: Set<String>) {
        guard let targets = selected(ids) else { return }
        dispatch(.bulkRemove(ids: targets.map(\.id)))
        finishBulk(targets.count, "toast.bulkDeleted")
    }

    // MARK: Categories

    /// Creates or renames; returns the error code to show, or nil on success.
    public func submitCategory(name: String, renaming id: String?) -> CategoryModel.NameError? {
        if let error = CategoryModel.validateName(name, categories: categories, excludeId: id) { return error }
        let clean = CategoryModel.normalizeName(name)
        if let id {
            dispatchCategory(.rename(id: id, name: clean))
            notify(l10n.t("toast.categoryRenamed", ["name": clean]))
        } else {
            dispatchCategory(.create(name: clean))
            notify(l10n.t("toast.categoryCreated", ["name": clean]))
        }
        return nil
    }

    /// Tasks are reassigned before the category disappears; both changes are saved together.
    public func deleteCategory(_ id: String, moveTo targetId: String?) {
        guard let category = category(id) else { return }
        let moved = counts[.category(id)] ?? 0
        let target = targetId.flatMap { self.category($0)?.name } ?? l10n.t("nav.uncategorized")
        tasks = tasksReducer(tasks, .reassignCategory(from: id, to: targetId))
        categories = categoriesReducer(categories, .remove(id: id))
        if destination == .category(id) { destination = .all }
        scheduleSave()
        notify(moved > 0
            ? l10n.t("toast.categoryDeletedMoved", ["name": category.name, "count": moved, "target": target])
            : l10n.t("toast.categoryDeleted", ["name": category.name]))
    }

    // MARK: Settings

    public func setLanguage(_ language: Language) {
        guard settings.language != language else { return }
        settings.language = language
        scheduleSave()
    }

    public func setReminders(_ reminders: ReminderSettings) {
        settings.reminders = reminders
        scheduleSave()
    }

    public func setAvailability(_ availability: Availability?) {
        settings.availability = availability
        scheduleSave()
    }

    // MARK: Assistant changes

    /// Applies a confirmed assistant batch through the normal reducers, then saves at once.
    /// Returns whether the save succeeded (success is reported only then).
    public func applyAssistantChanges(tasks changed: [TaskItem], removeIds: [String], newCategories: [TaskCategory], removeCategoryIds: [String] = []) -> Bool {
        if !newCategories.isEmpty { categories = categoriesReducer(categories, .add(newCategories)) }
        if !changed.isEmpty || !removeIds.isEmpty { tasks = tasksReducer(tasks, .replace(tasks: changed, removeIds: removeIds)) }
        if !removeCategoryIds.isEmpty { categories = categoriesReducer(categories, .removeMany(removeCategoryIds)) }
        return saveNow()
    }

    // MARK: Import / export

    /// The current data as a Windows-compatible taskflow-data.json.
    public func exportData() -> Data {
        DocumentCodec.normalizedForSave(document).fileData()
    }

    /// Reads and checks a file; nothing changes yet.
    public func checkImport(_ data: Data) -> ImportCheck {
        do {
            return .ready(try DocumentCodec.decode(data), data)
        } catch DocumentCodec.Failure.newerVersion {
            return .failed(l10n.t("ios.importNewer"))
        } catch {
            return .failed(l10n.t("ios.importInvalid"))
        }
    }

    /// The name of the copy the current data will be kept as before an import.
    /// Replaces the data with an imported document. The current data and the imported original are
    /// kept as copies first; returns false (and changes nothing) if the current data cannot be kept.
    @discardableResult
    public func applyImport(_ checked: DocumentCodec.Result, original: Data) -> Bool {
        do {
            try backup?.preserve(data: exportData(), reason: "before-import")
            try backup?.preserve(data: original, reason: "imported")
        } catch {
            notify(l10n.t("storage.saveFailed"), error: true)
            return false
        }
        let document = checked.document
        categories = document.categories
        tasks = Tasks.restore(document.tasks.map(\.json))
        settings = document.settings
        destination = Destination(storageKey: settings.lastView.destination)
        layout = settings.lastView.layout
        resetView()
        writable = true
        backup?.markWritable()
        let normalized = DocumentCodec.normalizedForSave(self.document)
        do {
            try repository.replaceAll(with: normalized)
            saveFailed = false
        } catch {
            saveFailed = true
        }
        writeBackup(normalized)
        syncReminders()
        var message = l10n.t("ios.importDone", ["tasks": tasks.count, "categories": categories.count])
        if checked.repaired { message += " " + l10n.t("ios.importRepaired") }
        if checked.migrated { message += " " + l10n.t("ios.importMigrated") }
        notify(message)
        return true
    }
}
