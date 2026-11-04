// Date formatters are expensive to create (about 0.1 ms each, mostly the localized pattern lookup)
// and are needed for every visible due date, so each configuration is created once and reused.
// Formatting with a shared DateFormatter is thread-safe; the cache itself is guarded by a lock.
import Foundation

public enum Formatters {
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var formatters: [String: DateFormatter] = [:]
    }

    private static let cache = Cache()

    /// The formatter for `key`, made by `make` the first time. The key must name everything the
    /// formatter depends on (locale, pattern, and the time zone if it is not fixed).
    public static func date(_ key: String, make: () -> DateFormatter) -> DateFormatter {
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if let formatter = cache.formatters[key] { return formatter }
        let formatter = make()
        cache.formatters[key] = formatter
        return formatter
    }

    /// A formatter for a localized pattern template ("dMMM", "LLLLy"), in `timeZone`.
    public static func template(_ template: String, locale: Locale, timeZone: TimeZone, context: Formatter.Context = .unknown) -> DateFormatter {
        date("\(template)|\(locale.identifier)|\(timeZone.identifier)|\(context.rawValue)") {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.formattingContext = context
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter
        }
    }
}
