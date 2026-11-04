// Taskflow for iPhone - the app entry point. The board is stored in SwiftData; if the store cannot
// be opened, its files are left untouched and the app works from the Windows-format JSON copy in
// the Documents folder instead (and says so), so data is never discarded.
import SwiftUI
import TaskflowCore
import TaskflowUI

@main
struct TaskflowMain: App {
    private let store: AppStore
    private let assistant: AssistantModel

    init() {
        let backup = DocumentFileStore(directory: TaskflowApp.backupDirectory)
        let repository: TaskRepository
        var storeUnavailable = false
        if let swiftData = SwiftDataTaskRepository.open(backup: backup) {
            repository = swiftData
        } else {
            repository = FileTaskRepository(store: backup)
            storeUnavailable = true
        }
        let models = TaskflowApp.makeModels(repository: repository, backup: storeUnavailable ? nil : backup)
        store = models.0
        assistant = models.1
        if storeUnavailable {
            store.notify(store.l10n.t("ios.storageSwiftData"), error: true)
        }
    }

    var body: some Scene {
        WindowGroup {
            TaskflowRootView(store: store, assistant: assistant)
        }
    }
}
