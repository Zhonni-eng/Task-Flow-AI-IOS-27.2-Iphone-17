// Deterministic test data builders - a port of tests/helpers/fixtures.js. Time-zone dependent
// cases run in Europe/Berlin (DST on 29 Mar and 25 Oct 2026), as in the Windows app's tests.
import Foundation
@testable import TaskflowCore

let berlin = TimeZone(identifier: "Europe/Berlin")!

/// new Date(year, month - 1, day, hour, minute) in Berlin.
func local(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
    Schedule.localInstant(year: year, month: month, day: day, hour: hour, minute: minute, timeZone: berlin)
}

nonisolated(unsafe) private var counter = 0

func makeTask(
    id: String? = nil, title: String? = nil, description: String = "", priority: Priority = .medium,
    dueDate: String? = nil, dueTime: String? = nil, reminders: [Int] = [], recurrence: Recurrence? = nil,
    estimateMinutes: Int? = nil, planned: Planned? = nil, labels: [String] = [], status: TaskStatus = .todo,
    order: Double = 0, categoryId: String? = nil, subtasks: [Subtask] = [], completedAt: String? = nil,
    createdAt: String = "2026-10-01T00:00:00.000Z", updatedAt: String = "2026-10-01T00:00:00.000Z"
) -> TaskItem {
    counter += 1
    return TaskItem(
        id: id ?? "task-\(counter)", title: title ?? "Task \(counter)", description: description, priority: priority,
        dueDate: dueDate, dueTime: dueTime, reminders: reminders, recurrence: recurrence, estimateMinutes: estimateMinutes,
        planned: planned, labels: labels, status: status, order: order, categoryId: categoryId, subtasks: subtasks,
        completedAt: completedAt, createdAt: createdAt, updatedAt: updatedAt
    )
}

func makeCategory(id: String? = nil, name: String? = nil, order: Double = 0) -> TaskCategory {
    counter += 1
    return TaskCategory(id: id ?? "cat-\(counter)", name: name ?? "Category \(counter)", order: order, createdAt: "2026-10-01T00:00:00.000Z")
}

func sub(_ id: String, _ title: String, _ done: Bool = false) -> Subtask {
    Subtask(id: id, title: title, done: done)
}

/// Parses a JSON literal written in the tests (keeps JS-style "absent vs null" exactly).
func json(_ text: String) -> JSONValue {
    try! JSONValue.parse(text)
}

func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("taskflow-tests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
