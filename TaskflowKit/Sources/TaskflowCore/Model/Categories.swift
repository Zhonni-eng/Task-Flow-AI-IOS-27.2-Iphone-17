// Categories group tasks independently of status and labels - a port of src/data/categoryModel.js,
// src/data/categoryMatch.js and src/state/categoriesReducer.js.
//
// Category = { id, name, order, createdAt }. A task's categoryId of nil means "uncategorized".
import Foundation

public struct TaskCategory: Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var order: Double
    public var createdAt: String

    public init(id: String, name: String, order: Double, createdAt: String) {
        self.id = id
        self.name = name
        self.order = order
        self.createdAt = createdAt
    }

    public var json: JSONValue {
        ["id": .string(id), "name": .string(name), "order": .number(order), "createdAt": .string(createdAt)]
    }
}

public enum CategoryModel {
    public static let nameLimit = 60

    public static func generateId() -> String { "cat-\(UUID().uuidString.lowercased())" }

    public static func normalizeName(_ name: String) -> String {
        JSText.trimEnd(JSText.slice(JSText.trim(JSText.collapseWhitespace(name)), nameLimit))
    }

    public enum NameError: String, Sendable { case required, duplicate }

    /// An error ("required" / "duplicate") or nil when the name is valid.
    public static func validateName(_ name: String, categories: [TaskCategory], excludeId: String? = nil) -> NameError? {
        let normalized = normalizeName(name)
        if normalized.isEmpty { return .required }
        let key = JSText.lower(normalized)
        if categories.contains(where: { $0.id != excludeId && JSText.lower($0.name) == key }) { return .duplicate }
        return nil
    }

    public static func create(_ name: String, order: Int, now: Date = Date()) -> TaskCategory {
        TaskCategory(id: generateId(), name: normalizeName(name), order: Double(order), createdAt: ISOTime.string(now))
    }

    public static func restore(_ raw: [JSONValue]) -> [TaskCategory] {
        let restored: [TaskCategory] = raw.enumerated().compactMap { index, item in
            guard item.isPlainObject, let id = item["id"]?.stringValue else { return nil }
            let name = normalizeName(JSText.string(item["name"]))
            guard !name.isEmpty else { return nil }
            return TaskCategory(
                id: id, name: name,
                order: item["order"]?.finiteNumber ?? Double(index),
                createdAt: item["createdAt"]?.stringValue ?? ISOTime.epoch
            )
        }
        return restored
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.order != rhs.element.order { return lhs.element.order < rhs.element.order }
                if lhs.element.createdAt != rhs.element.createdAt { return lhs.element.createdAt < rhs.element.createdAt }
                return lhs.offset < rhs.offset
            }
            .enumerated()
            .map { index, entry in
                var category = entry.element
                category.order = Double(index)
                return category
            }
    }
}

// MARK: - Matching names (assistant)

/// Matching category names, so the assistant reuses an existing category instead of creating a
/// near-duplicate: same name in another case or word form ("Учёба" / "учеба" / "Учебе"), with
/// extra spaces or punctuation, or a known Russian/English variant ("Work" / "Работа").
/// Deliberately conservative: anything not clearly the same is treated as different.
public enum CategoryMatch {
    static let synonymGroups: [[String]] = [
        ["работа", "work", "job", "office", "офис"],
        ["учеба", "study", "studies", "school", "education", "university", "университет", "школа"],
        ["дом", "home", "household", "хозяйство", "house"],
        ["личное", "личные дела", "personal", "private"],
        ["покупки", "shopping", "магазин", "groceries", "продукты"],
        ["здоровье", "health", "medical", "медицина", "врачи"],
        ["финансы", "finance", "finances", "money", "деньги", "счета", "bills"],
        ["спорт", "sport", "sports", "fitness", "фитнес", "тренировки", "workout"],
        ["семья", "family"],
        ["путешествия", "travel", "trips", "поездки"],
        ["проекты", "projects", "project", "проект"],
    ]

    /// Lower case, ё -> е, letters/digits/spaces only, single spaces.
    public static func fold(_ name: String) -> String {
        let lowered = JSText.lower(name).replacingOccurrences(of: "ё", with: "е")
        var result = ""
        var pendingSpace = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) || scalar.properties.numericType != nil {
                if pendingSpace && !result.isEmpty { result.append(" ") }
                pendingSpace = false
                result.unicodeScalars.append(scalar)
            } else {
                pendingSpace = true
            }
        }
        return result
    }

    /// Same word, or the same stem: the shorter word minus its last letter starts the longer one.
    static func sameWord(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        if short.count < 4 || long.count - short.count > 3 { return false }
        return long.hasPrefix(String(short.dropLast()))
    }

    static func sameName(_ a: String, _ b: String) -> Bool {
        let wordsA = a.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let wordsB = b.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        return wordsA.count == wordsB.count && zip(wordsA, wordsB).allSatisfy { sameWord($0, $1) }
    }

    static func groupOf(_ folded: String) -> Int? {
        synonymGroups.firstIndex { group in group.contains { sameName($0, folded) } }
    }

    /// The existing category that `name` refers to, or nil.
    public static func findMatching(_ name: String, in categories: [TaskCategory]) -> TaskCategory? {
        let folded = fold(name)
        if folded.isEmpty { return nil }
        if let direct = categories.first(where: { sameName(fold($0.name), folded) }) { return direct }
        guard let group = groupOf(folded) else { return nil }
        return categories.first { groupOf(fold($0.name)) == group }
    }
}

// MARK: - Reducer

/// In-memory category list, kept sorted by `order` (contiguous 0..n-1).
public enum CategoryAction: Sendable {
    case create(name: String)
    case rename(id: String, name: String)
    case remove(id: String)
    /// Adds ready-made categories (created for a confirmed assistant plan, with their ids).
    case add([TaskCategory])
    /// Removes categories by id (undo of an assistant plan).
    case removeMany([String])
}

public func categoriesReducer(_ state: [TaskCategory], _ action: CategoryAction, now: Date = Date()) -> [TaskCategory] {
    func renumbered(_ list: [TaskCategory]) -> [TaskCategory] {
        list.enumerated().map { index, category in
            var copy = category
            copy.order = Double(index)
            return copy
        }
    }
    switch action {
    case .create(let name):
        return state + [CategoryModel.create(name, order: state.count, now: now)]
    case .rename(let id, let name):
        return state.map { category in
            guard category.id == id else { return category }
            var copy = category
            copy.name = CategoryModel.normalizeName(name)
            return copy
        }
    case .remove(let id):
        return renumbered(state.filter { $0.id != id })
    case .add(let categories):
        return renumbered(state + categories.filter { category in !state.contains { $0.id == category.id } })
    case .removeMany(let ids):
        let set = Set(ids)
        return renumbered(state.filter { !set.contains($0.id) })
    }
}
