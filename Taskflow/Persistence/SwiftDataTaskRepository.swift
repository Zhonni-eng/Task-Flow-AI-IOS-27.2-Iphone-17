// The board in SwiftData. Records are converted to and from the schema v4 JSON form and checked
// by DocumentCodec on every load, exactly like a file: anything invalid is repaired (and reported),
// never silently trusted. Saving replaces the records with the current board in one transaction;
// records of tasks that did not change since they were last read or written are left alone.
import Foundation
import SwiftData
import TaskflowCore
import TaskflowUI

@MainActor
final class SwiftDataTaskRepository: TaskRepository {
    let container: ModelContainer
    var context: ModelContext { container.mainContext }
    /// The Windows-format copy, used to recover when the store is empty but a copy exists.
    let backup: DocumentFileStore
    /// The tasks exactly as their records hold them (after a clean load or a successful save).
    private var stored: [String: TaskItem] = [:]

    init(container: ModelContainer, backup: DocumentFileStore) {
        self.container = container
        self.backup = backup
    }

    /// Opens the store; nil when it cannot be opened (its files are then left untouched).
    static func open(backup: DocumentFileStore) -> SwiftDataTaskRepository? {
        let schema = Schema(versionedSchema: TaskflowSchemaV1.self)
        let url = TaskflowApp.supportDirectory.appendingPathComponent("Taskflow.store")
        let configuration = ModelConfiguration("Taskflow", schema: schema, url: url, cloudKitDatabase: .none)
        guard let container = try? ModelContainer(for: schema, migrationPlan: TaskflowMigrationPlan.self, configurations: [configuration]) else { return nil }
        return SwiftDataTaskRepository(container: container, backup: backup)
    }

    // MARK: Records <-> schema v4 JSON

    static func json(_ record: TaskRecord) -> JSONValue {
        let recurrence = record.recurrenceJSON.flatMap { try? JSONValue.parse($0) } ?? .null
        let subtasks = (try? JSONValue.parse(record.subtasksJSON)) ?? .array([])
        let planned: JSONValue = record.plannedDate.flatMap { date in record.plannedTime.map { ["date": .string(date), "time": .string($0)] } } ?? .null
        return .object([
            "id": .string(record.id),
            "title": .string(record.title),
            "description": .string(record.details),
            "priority": .string(record.priority),
            "dueDate": .from(record.dueDate),
            "dueTime": .from(record.dueTime),
            "reminders": .from(record.reminders),
            "recurrence": recurrence,
            "estimateMinutes": .from(record.estimateMinutes),
            "planned": planned,
            "labels": .from(record.labels),
            "status": .string(record.status),
            "order": .number(record.order),
            "categoryId": .from(record.categoryId),
            "subtasks": subtasks,
            "completedAt": .from(record.completedAt),
            "createdAt": .string(record.createdAt),
            "updatedAt": .string(record.updatedAt),
        ])
    }

    /// Writes only the fields in which `task` differs from `previous` - what the record is known
    /// to hold - without reading the record (reading labels and reminders unarchives them).
    static func update(_ record: TaskRecord, from task: TaskItem, previous: TaskItem) {
        if previous.title != task.title { record.title = task.title }
        if previous.description != task.description { record.details = task.description }
        if previous.priority != task.priority { record.priority = task.priority.rawValue }
        if previous.dueDate != task.dueDate { record.dueDate = task.dueDate }
        if previous.dueTime != task.dueTime { record.dueTime = task.dueTime }
        if previous.reminders != task.reminders { record.reminders = task.reminders }
        if previous.recurrence != task.recurrence { record.recurrenceJSON = task.recurrence.map { $0.json.serialized() } }
        if previous.estimateMinutes != task.estimateMinutes { record.estimateMinutes = task.estimateMinutes }
        if previous.planned != task.planned {
            record.plannedDate = task.planned?.date
            record.plannedTime = task.planned?.time
        }
        if previous.labels != task.labels { record.labels = task.labels }
        if previous.status != task.status { record.status = task.status.rawValue }
        if previous.order != task.order { record.order = task.order }
        if previous.categoryId != task.categoryId { record.categoryId = task.categoryId }
        if previous.subtasks != task.subtasks { record.subtasksJSON = JSONValue.array(task.subtasks.map(\.json)).serialized() }
        if previous.completedAt != task.completedAt { record.completedAt = task.completedAt }
        if previous.createdAt != task.createdAt { record.createdAt = task.createdAt }
        if previous.updatedAt != task.updatedAt { record.updatedAt = task.updatedAt }
    }

    static func fill(_ record: TaskRecord, from task: TaskItem) {
        if record.title != task.title { record.title = task.title }
        if record.details != task.description { record.details = task.description }
        if record.priority != task.priority.rawValue { record.priority = task.priority.rawValue }
        if record.dueDate != task.dueDate { record.dueDate = task.dueDate }
        if record.dueTime != task.dueTime { record.dueTime = task.dueTime }
        if record.reminders != task.reminders { record.reminders = task.reminders }
        let recurrence = task.recurrence.map { $0.json.serialized() }
        if record.recurrenceJSON != recurrence { record.recurrenceJSON = recurrence }
        if record.estimateMinutes != task.estimateMinutes { record.estimateMinutes = task.estimateMinutes }
        if record.plannedDate != task.planned?.date { record.plannedDate = task.planned?.date }
        if record.plannedTime != task.planned?.time { record.plannedTime = task.planned?.time }
        if record.labels != task.labels { record.labels = task.labels }
        if record.status != task.status.rawValue { record.status = task.status.rawValue }
        if record.order != task.order { record.order = task.order }
        if record.categoryId != task.categoryId { record.categoryId = task.categoryId }
        let subtasks = JSONValue.array(task.subtasks.map(\.json)).serialized()
        if record.subtasksJSON != subtasks { record.subtasksJSON = subtasks }
        if record.completedAt != task.completedAt { record.completedAt = task.completedAt }
        if record.createdAt != task.createdAt { record.createdAt = task.createdAt }
        if record.updatedAt != task.updatedAt { record.updatedAt = task.updatedAt }
    }

    // MARK: TaskRepository

    func load() -> LoadResult {
        do {
            let settings = try context.fetch(FetchDescriptor<SettingsRecord>())
            guard let settingsRecord = settings.first else { return firstLoad() }
            let tasks = try context.fetch(FetchDescriptor<TaskRecord>())
            let categories = try context.fetch(FetchDescriptor<CategoryRecord>())
            let document: JSONValue = [
                "schemaVersion": .number(Double(DocumentCodec.schemaVersion)),
                "savedAt": .string(settingsRecord.savedAt),
                "settings": (try? JSONValue.parse(settingsRecord.json)) ?? .null,
                "categories": .array(categories.map { record -> JSONValue in
                    ["id": .string(record.id), "name": .string(record.name), "order": .number(record.order), "createdAt": .string(record.createdAt)]
                }),
                "tasks": .array(tasks.map(Self.json)),
            ]
            let result = try DocumentCodec.toCurrentDocument(document)
            stored = [:]
            if result.repaired {
                // Keep what was stored before anything is rewritten.
                let copy = try? backup.preserve(data: document.serialized(pretty: true), reason: "before-repair")
                return LoadResult(status: .repaired, writable: true, document: result.document, preservedCopy: copy, preservedBackup: nil, dropped: result.dropped)
            }
            // Not repaired: every record holds exactly its task.
            stored = Dictionary(result.document.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            return LoadResult(status: .loaded, writable: true, document: result.document, preservedCopy: nil, preservedBackup: nil, dropped: 0)
        } catch {
            // The store could not be read: never overwrite it in this session.
            return LoadResult(status: .readError, writable: false, document: .empty(), preservedCopy: nil, preservedBackup: nil, dropped: 0)
        }
    }

    /// An empty store: a first launch - or a store that was reset while the backup copy survived.
    private func firstLoad() -> LoadResult {
        let copy = backup.load()
        guard let document = copy.document, copy.status != .new, copy.status != .newerVersion, copy.status != .readError, !document.tasks.isEmpty || !document.categories.isEmpty else {
            if copy.status == .newerVersion {
                return LoadResult(status: .newerVersion, writable: false, document: .empty(), preservedCopy: nil, preservedBackup: nil, dropped: 0)
            }
            return LoadResult(status: .new, writable: true, document: nil, preservedCopy: nil, preservedBackup: nil, dropped: 0)
        }
        return LoadResult(status: .recovered, writable: true, document: document, preservedCopy: copy.preservedCopy, preservedBackup: nil, dropped: copy.dropped)
    }

    func save(_ board: TaskflowDocument) throws {
        let existingTasks = try context.fetch(FetchDescriptor<TaskRecord>())
        var byId: [String: TaskRecord] = [:]
        for record in existingTasks {
            // A duplicate id (never written by this app) keeps one record.
            if byId[record.id] == nil { byId[record.id] = record } else { context.delete(record) }
        }
        let keep = Set(board.tasks.map(\.id))
        for (id, record) in byId where !keep.contains(id) { context.delete(record) }
        for task in board.tasks {
            if let record = byId[task.id] {
                // Known contents: only the differences are written (nothing at all if unchanged).
                if let previous = stored[task.id] {
                    if previous != task { Self.update(record, from: task, previous: previous) }
                } else {
                    Self.fill(record, from: task)
                }
            } else {
                let record = TaskRecord(id: task.id)
                context.insert(record)
                Self.fill(record, from: task)
            }
        }

        let existingCategories = try context.fetch(FetchDescriptor<CategoryRecord>())
        var categoriesById: [String: CategoryRecord] = [:]
        for record in existingCategories {
            if categoriesById[record.id] == nil { categoriesById[record.id] = record } else { context.delete(record) }
        }
        let keepCategories = Set(board.categories.map(\.id))
        for (id, record) in categoriesById where !keepCategories.contains(id) { context.delete(record) }
        for category in board.categories {
            let record: CategoryRecord
            if let existing = categoriesById[category.id] {
                record = existing
            } else {
                record = CategoryRecord(id: category.id)
                context.insert(record)
            }
            if record.name != category.name { record.name = category.name }
            if record.order != category.order { record.order = category.order }
            if record.createdAt != category.createdAt { record.createdAt = category.createdAt }
        }

        let settings = try context.fetch(FetchDescriptor<SettingsRecord>())
        let settingsRecord: SettingsRecord
        if let existing = settings.first {
            settingsRecord = existing
        } else {
            settingsRecord = SettingsRecord()
            context.insert(settingsRecord)
        }
        for extra in settings.dropFirst() { context.delete(extra) }
        settingsRecord.json = board.settings.json.serialized()
        settingsRecord.savedAt = ISOTime.string(Date())

        do {
            try context.save()
            stored = Dictionary(board.tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            context.rollback()
            stored = [:]
            throw error
        }
    }

    func replaceAll(with document: TaskflowDocument) throws {
        try save(document)
    }
}
