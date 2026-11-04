// SwiftData schema of Taskflow for iPhone. The records hold exactly the fields of the Windows
// app's schema v4 (taskflow-data.json); everything read from them goes through the same
// normalization as an imported file (DocumentCodec), so the store can never hold anything the
// task model would not accept.
//
// Future changes go into a new VersionedSchema with a stage in TaskflowMigrationPlan - never by
// editing V1 in place - so existing stores are migrated, not discarded.
//
// Ready for sync later (e.g. CloudKit): no unique constraints, every property has a default, ids
// and updatedAt are kept on every record.
import Foundation
import SwiftData

enum TaskflowSchemaV1: VersionedSchema {
    static let versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [TaskRecord.self, CategoryRecord.self, SettingsRecord.self]
    }

    @Model
    final class TaskRecord {
        var id: String = ""
        var title: String = ""
        var details: String = ""
        var priority: String = "medium"
        var dueDate: String?
        var dueTime: String?
        var reminders: [Int] = []
        /// The recurrence rule as JSON ({ freq, interval, weekdays?, monthDay? }), or nil.
        var recurrenceJSON: Data?
        var estimateMinutes: Int?
        var plannedDate: String?
        var plannedTime: String?
        var labels: [String] = []
        var status: String = "todo"
        var order: Double = 0
        var categoryId: String?
        /// The subtasks as JSON ([{ id, title, done }]) - order matters, one level only.
        var subtasksJSON: Data = Data("[]".utf8)
        var completedAt: String?
        var createdAt: String = ""
        var updatedAt: String = ""

        init(id: String) {
            self.id = id
        }
    }

    @Model
    final class CategoryRecord {
        var id: String = ""
        var name: String = ""
        var order: Double = 0
        var createdAt: String = ""

        init(id: String) {
            self.id = id
        }
    }

    /// The document's settings ({ language, lastView, reminders, availability }) as JSON.
    @Model
    final class SettingsRecord {
        var key: String = "settings"
        var json: Data = Data()
        var savedAt: String = ""

        init(key: String = "settings") {
            self.key = key
        }
    }
}

enum TaskflowMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [TaskflowSchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}

typealias TaskRecord = TaskflowSchemaV1.TaskRecord
typealias CategoryRecord = TaskflowSchemaV1.CategoryRecord
typealias SettingsRecord = TaskflowSchemaV1.SettingsRecord
