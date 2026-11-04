// Interface text in Russian (default) and English - the Windows app's translations.js (converted
// to translations.json unchanged) with its lookup, interpolation and plural rules, plus iOS
// overrides for the few texts that describe Windows, and keys for the iPhone-only screens.
import Foundation

public struct L10n: Sendable {
    public let language: Language

    static let dictionaries: [String: JSONValue] = {
        guard let url = Bundle.module.url(forResource: "translations", withExtension: "json"),
              let data = try? Data(contentsOf: url), let json = try? JSONValue.parse(data) else { return [:] }
        return json.objectValue ?? [:]
    }()

    public init(_ language: Language) {
        self.language = language
    }

    public var locale: Locale { language.locale }

    static func lookup(_ node: JSONValue?, _ key: String) -> JSONValue? {
        key.split(separator: ".").reduce(node) { current, part in current?[String(part)] }
    }

    /// Intl.PluralRules categories for integers: ru one/few/many, en one/other.
    public static func pluralCategory(_ count: Int, language: Language) -> String {
        let n = abs(count)
        switch language {
        case .en:
            return n == 1 ? "one" : "other"
        case .ru:
            let mod10 = n % 10, mod100 = n % 100
            if mod10 == 1 && mod100 != 11 { return "one" }
            if (2...4).contains(mod10) && !(12...14).contains(mod100) { return "few" }
            return "many"
        }
    }

    func value(_ key: String) -> JSONValue? {
        if let override = IOSTexts.value(key, language) { return override }
        if let found = Self.lookup(Self.dictionaries[language.rawValue], key) { return found }
        if let override = IOSTexts.value(key, .ru) { return override }
        return Self.lookup(Self.dictionaries[Language.default.rawValue], key)
    }

    public func has(_ key: String) -> Bool { value(key) != nil }

    /// t(key, params): "{name}" placeholders; a "count" parameter picks the plural form.
    public func t(_ key: String, _ params: [String: CustomStringConvertible] = [:]) -> String {
        guard var value = value(key) else { return key }
        if value.isPlainObject, let count = params["count"] as? Int {
            value = value[Self.pluralCategory(count, language: language)] ?? value["other"] ?? value
        }
        guard let template = value.stringValue else { return key }
        return Self.interpolate(template, params)
    }

    static func interpolate(_ template: String, _ params: [String: CustomStringConvertible]) -> String {
        guard !params.isEmpty, template.contains("{") else { return template }
        var result = ""
        var index = template.startIndex
        while index < template.endIndex {
            if template[index] == "{", let close = template[index...].firstIndex(of: "}") {
                let name = String(template[template.index(after: index)..<close])
                if !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), let param = params[name] {
                    result += param.description
                    index = template.index(after: close)
                    continue
                }
            }
            result.append(template[index])
            index = template.index(after: index)
        }
        return result
    }

    // MARK: Dates

    /// Intl.DateTimeFormat(locale, options).format(date) for the option sets the app uses.
    public enum DateStyle: Sendable {
        /// { day: numeric, month: short } - "30 окт." / "Oct 30"
        case short
        /// { day: numeric, month: short, year: numeric }
        case shortWithYear
        /// { weekday: short, day: numeric, month: long } - "чт, 22 октября" / "Thu, October 22"
        case weekdayLong
        /// { day: numeric, month: long, year: numeric }
        case long
        /// { weekday: long, day: numeric, month: long }
        case weekdayFull
    }

    public func formatDate(_ dateKey: String, _ style: DateStyle = .short) -> String {
        guard Schedule.isDateKey(dateKey) else { return dateKey }
        let utc = Self.utc
        let formatter = Formatters.date("formatDate|\(locale.identifier)|\(style)") {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = utc
            // Intl writes weekday and month names in their in-sentence form ("чт, 22 октября").
            formatter.formattingContext = .middleOfSentence
            switch style {
            case .short: formatter.setLocalizedDateFormatFromTemplate("dMMM")
            case .shortWithYear: formatter.setLocalizedDateFormatFromTemplate("dMMMy")
            case .weekdayLong: formatter.setLocalizedDateFormatFromTemplate("EEEdMMMM")
            case .long: formatter.setLocalizedDateFormatFromTemplate("dMMMMy")
            case .weekdayFull: formatter.setLocalizedDateFormatFromTemplate("EEEEdMMMM")
            }
            formatter.dateFormat = Self.formatSymbols(formatter.dateFormat)
            return formatter
        }
        return formatter.string(from: Schedule.localInstant(dateKey, timeZone: utc))
    }

    static let utc = TimeZone(identifier: "UTC")!

    /// Standalone weekday/month symbols (c, L) as their in-format forms (E, M), outside quotes.
    static func formatSymbols(_ pattern: String) -> String {
        var inQuote = false
        return String(pattern.map { char -> Character in
            if char == "'" { inQuote.toggle() }
            if inQuote { return char }
            return char == "c" ? "E" : char == "L" ? "M" : char
        })
    }

    public func formatTimestamp(_ iso: String?) -> String? {
        guard let date = ISOTime.date(iso) else { return nil }
        let timeZone = TimeZone.current
        let formatter = Formatters.date("timestamp|\(locale.identifier)|\(timeZone.identifier)") {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.timeZone = timeZone
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
            return formatter
        }
        return formatter.string(from: date)
    }
}

/// Texts that differ on iPhone (they describe Windows or the desktop in translations.js) and the
/// texts of screens that exist only on iPhone.
enum IOSTexts {
    static func value(_ key: String, _ language: Language) -> JSONValue? {
        (language == .ru ? ru : en)[key]
    }

    static let ru: [String: JSONValue] = [
        "appSettings.remindersEnabled": "Показывать напоминания",
        "appSettings.remindersHint": "Напоминания приходят уведомлениями iPhone, даже когда Taskflow закрыт. iOS хранит ограниченное число запланированных уведомлений, поэтому ближайшие планируются заранее, а остальные — при следующем открытии приложения. Пропущенные показываются одним уведомлением, если прошло не больше суток.",
        "appSettings.notificationsDenied": "Уведомления для Taskflow выключены. Включите их в Настройках iPhone → Taskflow → Уведомления.",
        "appSettings.openSystemSettings": "Открыть настройки iPhone",
        "assistant.unavailable": "ИИ-помощник сейчас недоступен.",
        "assistant.voice.start": "Голосовой ввод: начать запись",
        "assistant.voice.recording": "Идёт запись {time}. Нажмите на микрофон ещё раз, чтобы закончить.",
        "assistant.voice.errors.MIC_DENIED": "Нет доступа к микрофону или распознаванию речи. Разрешите их: Настройки iPhone → Taskflow.",
        "assistant.voice.errors.NO_MIC": "Микрофон недоступен.",
        "assistant.voice.errors.MIC_BUSY": "Микрофон занят другим приложением.",
        "assistant.voice.errors.UNSUPPORTED": "Распознавание речи на этом языке недоступно на устройстве.",
        "assistant.errors.UNAVAILABLE": "ИИ-помощник сейчас недоступен.",
        "ai.intro": "ИИ-помощник создаёт и меняет задачи по обычным фразам — вы проверяете и подтверждаете каждое изменение. Для работы нужен API-ключ ИИ-сервиса.",
        "ai.connectedNotice": "Подключено. Ключ сохранён в связке ключей iPhone, помощник включён.",
        "ai.connectionHint.connected": "Ключ проверен в этом сеансе. Он хранится в связке ключей iPhone, посмотреть его нельзя.",
        "ai.connectionHint.unreadable": "Сохранённый ключ не читается на этом устройстве. Введите ключ заново.",
        "ai.connectErrors.SECURE_STORAGE_UNAVAILABLE": "Связка ключей iPhone недоступна, поэтому ключ нельзя сохранить.",
        "ai.connectErrors.ENCRYPTION_FAILED": "Не удалось сохранить ключ в связке ключей.",
        "ai.connectErrors.UNAVAILABLE": "Подключение сейчас недоступно.",
        "ai.secureStorageUnavailable": "Связка ключей iPhone недоступна, поэтому ключ нельзя сохранить. Taskflow не хранит ключи в открытом виде.",
        "ai.voice.title": "Голосовой ввод",
        "ai.voice.onDevice": "Речь распознаётся системой iOS (по возможности на устройстве), ключ не нужен. Распознанный текст появляется в поле сообщения — отправляете его вы сами.",
        "error.message": "В интерфейсе произошла ошибка. Сохранённые задачи не пострадали — перезапустите приложение.",
        "ios.section.overdue": "Просрочено",
        "ios.section.today": "Сегодня",
        "ios.section.future": "Будущие",
        "ios.section.noDate": "Без срока",
        "ios.section.done": "Выполнено",
        "ios.collapsed": "Свёрнуто",
        "ios.expanded": "Развёрнуто",
        "ios.calendar": "Календарь",
        "ios.calendarNoTasks": "На этот день задач нет",
        "ios.calendarToday": "Вернуться к сегодняшнему дню",
        "ios.calendarDayCount": "Задач: {count}",
        "ios.previousMonth": "Предыдущий месяц",
        "ios.nextMonth": "Следующий месяц",
        "ios.progress": "Прогресс",
        "ios.doneToday": "Выполнено сегодня",
        "ios.doneWeek": "Выполнено за 7 дней",
        "ios.openTasks": "Открытых задач",
        "ios.completedPerDay": "Выполнено по дням",
        "ios.day": "День",
        "ios.noCompletions": "За последнюю неделю пока ничего не выполнено.",
        "ios.openByPriority": "Открытые по приоритету",
        "ios.menu": "Меню",
        "ios.more": "Ещё",
        "ios.done": "Готово",
        "ios.select": "Выбрать",
        "ios.selectAll": "Выбрать все",
        "ios.sortAndFilter": "Сортировка и фильтры",
        "ios.showStats": "Статистика",
        "ios.complete": "Выполнить",
        "ios.reopen": "Вернуть в работу",
        "ios.moveTo": "Переместить в",
        "ios.moveUp": "Выше",
        "ios.moveDown": "Ниже",
        "ios.reorderHint": "Удерживайте и перетаскивайте задачи, чтобы менять порядок и колонку.",
        "ios.data": "Данные",
        "ios.export": "Экспорт задач (JSON)",
        "ios.exportHint": "Файл в формате Taskflow для Windows (taskflow-data.json, схема 4).",
        "ios.import": "Импорт из файла…",
        "ios.importHint": "Импорт заменяет текущие задачи, категории и настройки данными из файла. Текущие данные сначала сохраняются копией.",
        "ios.importConfirmTitle": "Заменить данные файлом?",
        "ios.importConfirmMessage": "В файле: задач — {tasks}, категорий — {categories}. Текущие данные будут сохранены копией {file}.",
        "ios.importConfirm": "Импортировать",
        "ios.importDone": "Импортировано: задач — {tasks}, категорий — {categories}.",
        "ios.importRepaired": "Часть данных в файле была некорректной и исправлена.",
        "ios.importMigrated": "Файл более старой версии Taskflow обновлён до текущего формата.",
        "ios.importInvalid": "Это не файл с задачами Taskflow или он повреждён. Ничего не изменено.",
        "ios.importNewer": "Файл создан более новой версией Taskflow. Ничего не изменено.",
        "ios.importReadFailed": "Не удалось прочитать файл. Ничего не изменено.",
        "ios.backups": "Резервные копии",
        "ios.backupsHint": "Копии хранятся в папке Taskflow приложения «Файлы» (На iPhone → Taskflow).",
        "ios.about": "О приложении",
        "ios.version": "Версия {version}",
        "ios.language": "Язык",
        "ios.newCategory": "Новая категория",
        "ios.categoryActions": "Действия с категорией",
        "ios.noCategories": "Категорий пока нет",
        "ios.empty": "Пусто",
        "ios.keyField": "API-ключ",
        "ios.statsTitle": "Статистика",
        "ios.saveAnyway": "Сохранить",
        "ios.discard": "Не сохранять",
        "ios.searchPrompt": "Поиск по задачам",
        "ios.subtaskAddPlaceholder": "Новая подзадача",
        "ios.allDay": "Весь день",
        "ios.hasTime": "Указать время",
        "ios.noEstimate": "Без оценки",
        "ios.minutesShort": "{count} мин",
        "ios.customReminder": "Своё напоминание",
        "ios.notificationOpen": "Открыть",
        "ios.storageSwiftData": "Хранилище iPhone недоступно, задачи хранятся в файле резервной копии.",
    ]

    static let en: [String: JSONValue] = [
        "appSettings.remindersEnabled": "Show reminders",
        "appSettings.remindersHint": "Reminders arrive as iPhone notifications, even when Taskflow is closed. iOS keeps a limited number of scheduled notifications, so the nearest ones are scheduled ahead and the rest the next time you open the app. Missed ones are shown together if they are less than a day old.",
        "appSettings.notificationsDenied": "Notifications for Taskflow are off. Turn them on in iPhone Settings → Taskflow → Notifications.",
        "appSettings.openSystemSettings": "Open iPhone Settings",
        "assistant.unavailable": "The AI assistant is unavailable right now.",
        "assistant.voice.recording": "Recording {time}. Tap the microphone again to finish.",
        "assistant.voice.errors.MIC_DENIED": "No access to the microphone or speech recognition. Allow them in iPhone Settings → Taskflow.",
        "assistant.voice.errors.NO_MIC": "The microphone is unavailable.",
        "assistant.voice.errors.MIC_BUSY": "The microphone is used by another app.",
        "assistant.voice.errors.UNSUPPORTED": "Speech recognition for this language is not available on this device.",
        "assistant.errors.UNAVAILABLE": "The AI assistant is unavailable right now.",
        "ai.intro": "The AI assistant creates and changes tasks from plain sentences - you review and confirm every change. It needs an API key from an AI service.",
        "ai.connectedNotice": "Connected. The key was saved in the iPhone Keychain and the assistant is on.",
        "ai.connectionHint.connected": "The key was checked in this session. It is stored in the iPhone Keychain and cannot be viewed.",
        "ai.connectionHint.unreadable": "The saved key cannot be read on this device. Please enter it again.",
        "ai.connectErrors.SECURE_STORAGE_UNAVAILABLE": "The iPhone Keychain is unavailable, so the key cannot be saved.",
        "ai.connectErrors.ENCRYPTION_FAILED": "The key could not be saved in the Keychain.",
        "ai.connectErrors.UNAVAILABLE": "Connecting is unavailable right now.",
        "ai.secureStorageUnavailable": "The iPhone Keychain is unavailable, so the key cannot be saved. Taskflow never stores keys as plain text.",
        "ai.voice.onDevice": "Speech is recognized by iOS (on the device where possible); no key is needed. The text appears in the message box - you send it yourself.",
        "error.message": "The interface ran into an error. Your saved tasks are safe — restart the app to continue.",
        "ios.section.overdue": "Overdue",
        "ios.section.today": "Today",
        "ios.section.future": "Upcoming",
        "ios.section.noDate": "No due date",
        "ios.section.done": "Completed",
        "ios.collapsed": "Collapsed",
        "ios.expanded": "Expanded",
        "ios.calendar": "Calendar",
        "ios.calendarNoTasks": "No tasks on this day",
        "ios.calendarToday": "Go back to today",
        "ios.calendarDayCount": "Tasks: {count}",
        "ios.previousMonth": "Previous month",
        "ios.nextMonth": "Next month",
        "ios.progress": "Progress",
        "ios.doneToday": "Completed today",
        "ios.doneWeek": "Completed in 7 days",
        "ios.openTasks": "Open tasks",
        "ios.completedPerDay": "Completed per day",
        "ios.day": "Day",
        "ios.noCompletions": "Nothing completed in the last week yet.",
        "ios.openByPriority": "Open by priority",
        "ios.menu": "Menu",
        "ios.more": "More",
        "ios.done": "Done",
        "ios.select": "Select",
        "ios.selectAll": "Select all",
        "ios.sortAndFilter": "Sort and filters",
        "ios.showStats": "Statistics",
        "ios.complete": "Complete",
        "ios.reopen": "Reopen",
        "ios.moveTo": "Move to",
        "ios.moveUp": "Move up",
        "ios.moveDown": "Move down",
        "ios.reorderHint": "Touch and hold a task, then drag it to reorder it or move it to another column.",
        "ios.data": "Data",
        "ios.export": "Export tasks (JSON)",
        "ios.exportHint": "A file in the format of Taskflow for Windows (taskflow-data.json, schema 4).",
        "ios.import": "Import from file…",
        "ios.importHint": "Importing replaces your current tasks, categories and settings with the file's data. The current data is kept as a copy first.",
        "ios.importConfirmTitle": "Replace your data with this file?",
        "ios.importConfirmMessage": "The file has {tasks} tasks and {categories} categories. Your current data will be kept as {file}.",
        "ios.importConfirm": "Import",
        "ios.importDone": "Imported {tasks} tasks and {categories} categories.",
        "ios.importRepaired": "Some data in the file was invalid and has been corrected.",
        "ios.importMigrated": "The file from an older Taskflow version was upgraded to the current format.",
        "ios.importInvalid": "This is not a Taskflow task file, or it is damaged. Nothing was changed.",
        "ios.importNewer": "This file was created by a newer Taskflow. Nothing was changed.",
        "ios.importReadFailed": "The file could not be read. Nothing was changed.",
        "ios.backups": "Backups",
        "ios.backupsHint": "Copies are kept in the Taskflow folder of the Files app (On My iPhone → Taskflow).",
        "ios.about": "About",
        "ios.version": "Version {version}",
        "ios.language": "Language",
        "ios.newCategory": "New category",
        "ios.categoryActions": "Category actions",
        "ios.noCategories": "No categories yet",
        "ios.empty": "Empty",
        "ios.keyField": "API key",
        "ios.statsTitle": "Statistics",
        "ios.saveAnyway": "Save",
        "ios.discard": "Discard",
        "ios.searchPrompt": "Search tasks",
        "ios.subtaskAddPlaceholder": "New subtask",
        "ios.allDay": "All day",
        "ios.hasTime": "Set a time",
        "ios.noEstimate": "No estimate",
        "ios.minutesShort": "{count} min",
        "ios.customReminder": "Custom reminder",
        "ios.notificationOpen": "Open",
        "ios.storageSwiftData": "iPhone storage is unavailable; tasks are kept in the backup file.",
    ]
}
