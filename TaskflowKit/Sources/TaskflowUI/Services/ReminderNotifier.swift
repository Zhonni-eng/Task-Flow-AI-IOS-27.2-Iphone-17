// Local reminders through UserNotifications. ReminderEngine (TaskflowCore) decides what to show and
// when; this class hands that to the system: the nearest reminders as calendar notifications in
// local wall-clock time (so a time-zone change keeps "16:30" at 16:30), due ones at once, and the
// handled-records in a small file next to the data (no task data in it).
import Foundation
import TaskflowCore
@preconcurrency import UserNotifications

public enum NotificationPermission: Sendable { case unknown, allowed, denied }

@MainActor
public final class ReminderNotifier: NSObject, UNUserNotificationCenterDelegate {
    public static let stateFileName = "taskflow-reminders.json"
    static let categoryId = "TASK_REMINDER"
    static let openActionId = "OPEN_TASK"

    private let center = UNUserNotificationCenter.current()
    private let stateURL: URL
    private var state: ReminderState
    /// Called with a task id when the user taps a reminder.
    public var onOpenTask: ((String) -> Void)?
    public private(set) var permission: NotificationPermission = .unknown

    public init(directory: URL) {
        stateURL = directory.appendingPathComponent(Self.stateFileName)
        if let data = try? Data(contentsOf: stateURL), let decoded = try? JSONDecoder().decode(ReminderState.self, from: data) {
            state = decoded
        } else {
            // Missing or unreadable: start empty. Worst case a recent reminder is shown again once.
            state = ReminderState()
        }
        super.init()
        center.delegate = self
    }

    public func refreshPermission() async -> NotificationPermission {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: permission = .allowed
        case .denied: permission = .denied
        default: permission = .unknown
        }
        return permission
    }

    /// Asks for permission the first time a reminder is actually needed.
    public func requestPermissionIfNeeded() async {
        if await refreshPermission() == .unknown {
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            _ = await refreshPermission()
        }
    }

    private struct Request {
        let tasks: [TaskItem]
        let settings: ReminderSettings
        let language: Language
    }

    /// What was handed to the system for one pending notification.
    private struct Scheduled: Equatable {
        let title: String
        let body: String
        let taskId: String?
        let fireAt: Date?
    }

    private var syncing = false
    private var queued: Request?
    /// The pending notifications as last handed to the system; nil until the first sync of this
    /// launch (which replaces everything, since earlier launches may have left others).
    private var handedOver: [String: Scheduled]?
    private var categoryLanguage: Language?

    /// Brings the system's notifications in line with the tasks. Calls that arrive while a sync is
    /// running are combined: only the latest state is synced next, so quick edits never run
    /// several overlapping syncs.
    public func sync(tasks: [TaskItem], settings: ReminderSettings, language: Language) async {
        queued = Request(tasks: tasks, settings: settings, language: language)
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        while let request = queued {
            queued = nil
            await perform(request)
        }
    }

    private func perform(_ request: Request) async {
        let result = ReminderEngine.sync(tasks: request.tasks, settings: request.settings, language: request.language, state: state)
        if request.settings.enabled && (!result.pending.isEmpty || !result.immediate.isEmpty) { await requestPermissionIfNeeded() }
        if categoryLanguage != request.language {
            let open = UNNotificationAction(identifier: Self.openActionId, title: L10n(request.language).t("ios.notificationOpen"), options: [.foreground])
            center.setNotificationCategories([UNNotificationCategory(identifier: Self.categoryId, actions: [open], intentIdentifiers: [])])
            categoryLanguage = request.language
        }
        let wanted = Dictionary(result.pending.map { ($0.id, Scheduled(title: $0.title, body: $0.body, taskId: $0.taskId, fireAt: $0.fireAt)) }, uniquingKeysWith: { first, _ in first })
        var toAdd = result.pending
        if let previous = handedOver {
            // Only what changed: removed reminders go, new or changed ones are (re)added.
            let removed = previous.keys.filter { wanted[$0] == nil }
            if !removed.isEmpty { center.removePendingNotificationRequests(withIdentifiers: removed) }
            toAdd = result.pending.filter { previous[$0.id] != wanted[$0.id] }
        } else {
            center.removeAllPendingNotificationRequests()
        }
        var scheduled = handedOver.map { previous in Set(previous.keys.filter { wanted[$0] != nil }) } ?? []
        var handed = wanted
        for note in toAdd + result.immediate {
            do {
                try await center.add(Self.request(note))
                if note.fireAt != nil { scheduled.insert(note.id) }
            } catch {
                // Not delivered: it stays unrecorded as pending and is shown as missed if it passes.
                if note.fireAt != nil { handed[note.id] = nil }
            }
        }
        handedOver = handed
        let next = ReminderState(fired: result.state.fired, scheduled: scheduled)
        if next != state {
            state = next
            persist()
        }
    }

    private static func request(_ note: ReminderNotification) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.body = note.body
        content.sound = .default
        content.categoryIdentifier = categoryId
        content.threadIdentifier = "taskflow"
        if let taskId = note.taskId { content.userInfo = ["taskId": taskId] }
        var trigger: UNNotificationTrigger?
        if let fireAt = note.fireAt {
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fireAt)
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        }
        return UNNotificationRequest(identifier: note.id, content: content, trigger: trigger)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: stateURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: UNUserNotificationCenterDelegate

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let taskId = response.notification.request.content.userInfo["taskId"] as? String else { return }
        await MainActor.run { self.onOpenTask?(taskId) }
    }
}
