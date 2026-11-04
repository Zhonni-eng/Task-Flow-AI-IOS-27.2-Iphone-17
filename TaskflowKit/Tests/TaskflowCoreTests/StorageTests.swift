// The schema v4 document: migrations, repairs, recovery and write safety - ports of
// tests/storage/{storage,integrity,subtasks-migration}.test.js against DocumentFileStore.
import Foundation
import Testing
@testable import TaskflowCore

private func write(_ text: String, to url: URL) {
    try! Data(text.utf8).write(to: url)
}

private func files(_ dir: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()) ?? []
}

private let v1File = #"""
{"schemaVersion":1,"savedAt":"2026-01-01T00:00:00.000Z","settings":{"language":"en","lastView":{"destination":"__all__","layout":"list"}},
 "tasks":[{"id":"a","title":"First","description":"Desc","priority":"high","dueDate":"2026-01-10","labels":["x","y"],"status":"done","order":0,
           "createdAt":"2026-01-01T00:00:00.000Z","updatedAt":"2026-01-05T00:00:00.000Z"},
          {"id":"b","title":"Second","description":"","priority":"low","dueDate":null,"labels":[],"status":"todo","order":0,
           "createdAt":"2026-01-02T00:00:00.000Z","updatedAt":"2026-01-02T00:00:00.000Z"}]}
"""#

@Suite("Storage")
struct StorageTests {
    @Test func firstLaunch() {
        let dir = tempDirectory()
        let result = DocumentFileStore(directory: dir).load()
        #expect(result.status == .new)
        #expect(result.document == nil)
        #expect(files(dir).isEmpty)
    }

    @Test func roundTrip() throws {
        let dir = tempDirectory()
        let store = DocumentFileStore(directory: dir)
        _ = store.load()
        let document = TaskflowDocument(
            settings: AppSettings(language: .en, lastView: LastView(destination: "cat-1", layout: .list), reminders: ReminderSettings(enabled: false, allDayTime: "08:15"), availability: Availability(start: "09:00", end: "18:00")),
            categories: [makeCategory(id: "cat-1", name: "Учёба, работа & co")],
            tasks: [makeTask(id: "t", title: "Экзамен", dueDate: "2026-10-30", dueTime: "16:30", reminders: [30, 1440], recurrence: Recurrence(freq: .weekly, interval: 2, weekdays: [1, 4]), estimateMinutes: 90, planned: Planned(date: "2026-10-29", time: "10:00"), labels: ["учёба"], categoryId: "cat-1", subtasks: [sub("s1", "A", true)])]
        )
        try store.save(document)
        let reloaded = DocumentFileStore(directory: dir).load()
        #expect(reloaded.status == .loaded)
        #expect(reloaded.document == document)
        #expect(!files(dir).contains(DocumentCodec.fileName + ".tmp"))
    }

    @Test func backupOfPreviousSave() throws {
        let dir = tempDirectory()
        let store = DocumentFileStore(directory: dir)
        _ = store.load()
        try store.save(TaskflowDocument(tasks: [makeTask(id: "1", title: "One")]))
        try store.save(TaskflowDocument(tasks: [makeTask(id: "2", title: "Two")]))
        let backup = try DocumentCodec.decode(Data(contentsOf: store.backupFile))
        #expect(backup.document.tasks.map(\.id) == ["1"])
    }

    @Test func savedFileMatchesWindowsFormat() throws {
        let dir = tempDirectory()
        let store = DocumentFileStore(directory: dir)
        _ = store.load()
        try store.save(TaskflowDocument(tasks: [makeTask(id: "1", title: "One")]))
        let raw = try JSONValue.parse(Data(contentsOf: store.file))
        #expect(raw["schemaVersion"] == 4)
        #expect(Set(raw.keys) == Set(DocumentCodec.docKeys))
        #expect(Set(raw["tasks"]!.arrayValue![0].keys) == Set(DocumentCodec.taskKeys))
        #expect(raw["settings"] == json(#"{"language":"ru","lastView":{"destination":"__all__","layout":"board"},"reminders":{"enabled":true,"allDayTime":"09:00"},"availability":null}"#))
    }

    @Test func migratesV1KeepingOriginal() throws {
        let dir = tempDirectory()
        write(v1File, to: dir.appendingPathComponent(DocumentCodec.fileName))
        let store = DocumentFileStore(directory: dir)
        let result = store.load()
        #expect(result.status == .migrated)
        let document = result.document!
        #expect(document.settings.language == .en)
        #expect(document.settings.lastView.layout == .list)
        #expect(document.tasks.map(\.id) == ["a", "b"])
        #expect(document.tasks[0].labels == ["x", "y"])
        #expect(document.tasks[0].completedAt == "2026-01-05T00:00:00.000Z") // done: last update
        #expect(document.tasks[1].completedAt == nil)
        #expect(document.tasks.allSatisfy { $0.categoryId == nil && $0.subtasks.isEmpty && $0.reminders.isEmpty })
        let copy = try #require(result.preservedCopy)
        #expect(try String(contentsOf: copy, encoding: .utf8) == v1File)
        // The next save writes the current format; a second launch is clean.
        try store.save(document)
        #expect(DocumentFileStore(directory: dir).load().status == .loaded)
    }

    @Test func migratesUnversionedArray() throws {
        let result = try DocumentCodec.toCurrentDocument(json(#"[{"id":"a","title":"A","status":"todo","priority":"medium","order":0,"labels":[],"description":"","dueDate":null,"createdAt":"x","updatedAt":"x"}]"#))
        #expect(result.migrated)
        #expect(result.document.tasks.map(\.id) == ["a"])
        #expect(result.document.settings.language == .ru)
    }

    @Test func migrationIsRepeatable() throws {
        let raw = json(#"{"schemaVersion":2,"settings":{"language":"ru"},"categories":[{"id":"c","name":"C","order":0,"createdAt":"x"}],"tasks":[{"id":"a","title":"A","categoryId":"c","subtasks":[{"id":"s","title":"S","done":true}]}]}"#)
        let first = try DocumentCodec.toCurrentDocument(raw)
        let second = try DocumentCodec.toCurrentDocument(raw)
        #expect(first.document == second.document)
        #expect(first.document.tasks[0].subtasks == [sub("s", "S", true)])
        #expect(first.document.tasks[0].categoryId == "c")
    }

    @Test func newerVersionIsReadOnly() throws {
        let dir = tempDirectory()
        let text = #"{"schemaVersion":5,"tasks":[]}"#
        write(text, to: dir.appendingPathComponent(DocumentCodec.fileName))
        let store = DocumentFileStore(directory: dir)
        #expect(store.load().status == .newerVersion)
        #expect(throws: DocumentFileStore.WriteError.readOnly) { try store.save(TaskflowDocument()) }
        #expect(try String(contentsOf: store.file, encoding: .utf8) == text)
    }

    @Test func recoversFromBackupKeepingCorruptFile() throws {
        let dir = tempDirectory()
        let store = DocumentFileStore(directory: dir)
        _ = store.load()
        try store.save(TaskflowDocument(tasks: [makeTask(id: "1", title: "One")]))
        try store.save(TaskflowDocument(tasks: [makeTask(id: "2", title: "Two")]))
        write("{ not json", to: store.file)
        let result = DocumentFileStore(directory: dir).load()
        #expect(result.status == .recovered)
        #expect(result.document?.tasks.map(\.id) == ["1"])
        let copy = try #require(result.preservedCopy)
        #expect(try String(contentsOf: copy, encoding: .utf8) == "{ not json")
    }

    @Test func byteOrderMark() throws {
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(#"{"schemaVersion":4,"settings":{"language":"ru"},"categories":[],"tasks":[]}"#.utf8))
        #expect(try DocumentCodec.decode(data).document.tasks.isEmpty)
    }

    @Test func corruptWithoutBackup() {
        let dir = tempDirectory()
        write("garbage", to: dir.appendingPathComponent(DocumentCodec.fileName))
        let result = DocumentFileStore(directory: dir).load()
        #expect(result.status == .unreadable)
        #expect(result.document == TaskflowDocument.empty())
        #expect(result.preservedCopy != nil)
    }

    @Test func missingMainFileUsesBackup() throws {
        let dir = tempDirectory()
        write(#"{"schemaVersion":4,"settings":{"language":"en"},"categories":[],"tasks":[{"id":"a","title":"A"}]}"#, to: dir.appendingPathComponent(DocumentCodec.fileName + ".bak"))
        let result = DocumentFileStore(directory: dir).load()
        #expect(result.status == .recovered)
        #expect(result.document?.tasks.map(\.id) == ["a"])
    }

    @Test func damagedBackupWithoutMainIsReportedAndKept() {
        let dir = tempDirectory()
        write("broken", to: dir.appendingPathComponent(DocumentCodec.fileName + ".bak"))
        let result = DocumentFileStore(directory: dir).load()
        #expect(result.status == .unreadable)
        #expect(files(dir).contains { $0.hasPrefix("taskflow-data.unusable-backup-") })
    }

    @Test func repairsInvalidRecords() throws {
        let raw = json(#"""
        {"schemaVersion":4,"settings":{"language":"de","extra":1},"categories":[{"id":"c1","name":"  Work  "},{"id":"c1","name":"Dup"},{"name":"No id"}],
         "tasks":[{"id":"a","title":"  A  ","priority":"urgent","status":"todo","order":0,"categoryId":"c-missing","labels":["x","X"," "],"dueDate":"2026-02-30",
                   "subtasks":[{"id":"s","title":"S","done":"yes","nested":[]}],"unknown":true},
                  {"id":"a","title":"Duplicate id"},{"title":"No id"},{"id":"b"}]}
        """#)
        let result = try DocumentCodec.toCurrentDocument(raw)
        #expect(result.repaired)
        #expect(result.dropped == 5)
        let task = result.document.tasks[0]
        #expect(task.title == "A" && task.priority == .medium && task.categoryId == nil && task.labels == ["x"] && task.dueDate == nil)
        #expect(task.subtasks == [sub("s", "S", false)])
        #expect(result.document.categories.map(\.name) == ["Work"])
        #expect(result.document.settings.language == .ru)
    }

    @Test func cleanFileStaysClean() throws {
        let document = TaskflowDocument(categories: [makeCategory(id: "c", name: "Учёба")], tasks: [makeTask(id: "a", title: "A", labels: ["s"], categoryId: "c", subtasks: [sub("s1", "Subtask with s")])])
        let result = try DocumentCodec.decode(document.fileData())
        #expect(!result.repaired && !result.migrated)
        #expect(result.document == document)
    }

    @Test func saveDetachesUnknownCategories() {
        let normalized = DocumentCodec.normalizedForSave(TaskflowDocument(settings: AppSettings(lastView: LastView(destination: "gone", layout: .list)), tasks: [makeTask(id: "a", title: "A", categoryId: "gone")]))
        #expect(normalized.tasks[0].categoryId == nil)
        #expect(normalized.settings.lastView == LastView(destination: Destination.allKey, layout: .list))
    }

    @Test func invalidDocuments() {
        #expect(throws: DocumentCodec.Failure.invalid) { try DocumentCodec.decode(Data("[1,2".utf8)) }
        #expect(throws: DocumentCodec.Failure.invalid) { try DocumentCodec.toCurrentDocument(json(#"{"schemaVersion":4,"tasks":"no"}"#)) }
        #expect(throws: DocumentCodec.Failure.newerVersion(9)) { try DocumentCodec.toCurrentDocument(json(#"{"schemaVersion":9,"tasks":[]}"#)) }
    }
}

@Suite("Saving once-normalized documents")
struct NormalizedSaveTests {
    /// A document with things normalization changes: an unknown category, a removed category in
    /// the remembered view, and a duplicate task id.
    static func untidy() -> TaskflowDocument {
        let category = makeCategory(id: "cat-a", name: "Работа")
        var settings = AppSettings()
        settings.lastView = LastView(destination: "cat-gone", layout: .list)
        return TaskflowDocument(settings: settings, categories: [category], tasks: [
            makeTask(id: "t1", title: "Отчёт", categoryId: "cat-a"),
            makeTask(id: "t2", title: "Звонок", categoryId: "cat-missing"),
            makeTask(id: "t1", title: "Дубликат"),
        ])
    }

    @Test func normalizingIsIdempotent() {
        let once = DocumentCodec.normalizedForSave(Self.untidy())
        #expect(DocumentCodec.normalizedForSave(once) == once)
        #expect(once.tasks.map(\.id) == ["t1", "t2"])
        #expect(once.tasks[1].categoryId == nil)
        #expect(once.settings.lastView.destination == Destination.allKey)
    }

    @Test func preNormalizedSaveWritesTheSameFile() throws {
        let saved = Date(timeIntervalSince1970: 1_793_750_400)
        let plainDir = tempDirectory(), preDir = tempDirectory()
        let plain = DocumentFileStore(directory: plainDir, now: { saved })
        let pre = DocumentFileStore(directory: preDir, now: { saved })
        _ = plain.load()
        _ = pre.load()
        try plain.save(Self.untidy())
        try pre.save(DocumentCodec.normalizedForSave(Self.untidy()), normalized: true)
        #expect(try Data(contentsOf: plain.file) == Data(contentsOf: pre.file))
    }
}
