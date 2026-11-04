# Taskflow for iPhone

A native SwiftUI + SwiftData version of **Taskflow** (the Windows Electron app,
<https://github.com/Zhonni-eng/Task-Flow-AI>) for iPhone 17 / iOS 27. Russian (default) and
English, dark theme, works offline, optional AI assistant that only *proposes* changes.

The Windows application is not modified; this folder contains only the iOS code. Its behaviour
(task model, schema v4 data file, schedule / recurrence / reminder rules, AI action validation, apply
and undo) is ported from the Windows sources and checked against ports of its tests.

## Layout

| Path | What |
|---|---|
| `Taskflow.xcodeproj` | The iPhone app project (open this in Xcode). |
| `Taskflow/` | App target: entry point, SwiftData schema + repository, icon, permission texts, privacy manifest. |
| `TaskflowKit/Sources/TaskflowCore` | Platform-free business logic (Foundation only) - ports of the Windows modules (table below). |
| `TaskflowKit/Sources/TaskflowUI` | SwiftUI interface, app state, Keychain, notifications, speech. |
| `TaskflowKit/Tests/TaskflowCoreTests` | 184 Swift Testing tests (ports of the Windows Vitest suites). |
| `scripts/test-core.sh` | Runs the tests (with Xcode or with the Command Line Tools only). |
| `CHECKLIST.md` | Implementation checklist and status. |

| Windows source | iOS port |
|---|---|
| `electron/shared/schedule.mjs` | `TaskflowCore/Model/Schedule.swift` |
| `src/data/taskModel.js`, `subtasks.js` | `Model/TaskModel.swift` |
| `src/data/categoryModel.js`, `categoryMatch.js`, `state/categoriesReducer.js` | `Model/Categories.swift` |
| `src/data/dueDates.js` | `Model/DueDates.swift` |
| `src/state/tasksReducer.js` | `State/TasksReducer.swift` |
| `src/state/taskView.js` | `State/TaskView.swift` |
| `electron/storage.cjs` | `Storage/TaskflowDocument.swift` (codec, migrations v0→v4, repair), `Storage/DocumentFileStore.swift` (atomic file + `.bak`) |
| `src/ai/actionPlan.js` | `AI/ActionPlan.swift` |
| `src/ai/applyPlan.js` | `AI/ApplyPlan.swift` |
| `src/ai/useAssistant.js` (rules) | `AI/AssistantEngine.swift`, `TaskflowUI/State/AssistantModel.swift` |
| `electron/ai/prompt.cjs`, `taskContext.cjs` | `AI/Prompt.swift`, `AI/TaskContext.swift` |
| `electron/ai/providers*.cjs`, `providers/*.cjs` | `AI/Providers.swift`, `AI/WirePlan.swift`, `AI/Adapters.swift`, `AI/HTTPTransport.swift` |
| `electron/ai/aiSettings.cjs`, `connection.cjs`, `chatService.cjs` | `AI/AISettings.swift`, `AI/ConnectionAndChat.swift` |
| `electron/reminders.cjs` | `Reminders/ReminderEngine.swift` + `TaskflowUI/Services/ReminderNotifier.swift` |
| `src/i18n/translations.js` | `Resources/translations.json` (converted unchanged) + `I18n/L10n.swift` |
| React components | `TaskflowUI/*` (Board, List, Editor, Navigation, Toolbar, Settings, Assistant) |

## Requirements

- A Mac with **Xcode 27** (installed from the Mac App Store), license accepted:
  `sudo xcodebuild -license accept`.
- iPhone 17 with iOS 27 (the deployment target is iOS 18, built with the iOS 27 SDK).
- An Apple ID added in Xcode (Settings → Accounts). A free account is enough to run on your own
  iPhone (the app then has to be re-installed every 7 days); the Apple Developer Program removes
  that limit and enables TestFlight.

## Build and run

1. Open `Taskflow.xcodeproj` in Xcode. Xcode resolves the local package `TaskflowKit` by itself.
2. Select the **Taskflow** target → *Signing & Capabilities* → choose your **Team**. The bundle
   id is `com.zhanat.taskflow`; if Xcode says it is taken, change it (e.g. `com.<yourname>.taskflow`).
3. Choose a simulator (iPhone 17) or your connected iPhone, then *Product → Run* (⌘R).

On the iPhone the first time: *Settings → Privacy & Security → Developer Mode* → on (restart), and
after installing *Settings → General → VPN & Device Management* → trust your developer certificate.

### Notes from simulator testing

- On a Mac with 8 GB of memory, running Xcode, the Simulator and large apps (e.g. Photoshop) at the
  same time leads to heavy swapping: the app then needs many seconds to show its first screen and
  taps arrive late. With enough free memory it launches in about a second. This does not affect the
  iPhone.
- In the Simulator, switches sometimes ignore a click but react to a short drag; on a device they
  behave normally.

## Tests

```bash
./scripts/test-core.sh
```

Runs every suite on the Mac (no simulator needed). In Xcode: open `TaskflowKit/Package.swift` and
press ⌘U.

Timings of the work repeated on every change (3000 tasks; printed, never failing on time):

```bash
./scripts/test-core.sh -c release -Xswiftc -enable-testing --filter Performance
```

## Data, backups, import and export

- Tasks, categories and settings are stored with **SwiftData** in the app's private
  Application Support folder. Every load goes through the same validation as a data file; invalid
  data is repaired and the original kept as a copy.
- After every save a **Windows-format copy** (`taskflow-data.json` + `.bak`) is written to the
  app's Documents folder - visible in the Files app under *On My iPhone → Taskflow*. If the
  SwiftData store is ever empty or cannot be opened, the app continues from that copy; the store's
  files are never deleted.
- **Export** (Settings → Data) creates `taskflow-data.json` in schema v4 - it opens in Taskflow for
  Windows (`%APPDATA%\Taskflow\taskflow-data.json`).
- **Import** accepts any Windows data file (schema v0-v4; older ones are migrated, invalid entries
  repaired). Before anything is replaced, the current data and the imported file are kept as
  `taskflow-data.before-import-….json` / `taskflow-data.imported-….json`. A file from a newer
  version is refused.

## AI assistant

Same services and rules as on Windows: Anthropic Claude (`claude-opus-5-5`), OpenAI
(`gpt-6-luna`), Google Gemini (`gemini-3.8-flash`) or an OpenAI-compatible API. The key is checked
first and stored only if the check succeeds - in the **iOS Keychain** (this device only, never in
iCloud, never in files or source code). Requests go only to the official API host (or the base URL
you entered); redirects are not followed.

Only your message, the date/time, category names, a summary and the tasks the message is about are
sent (never descriptions). Every proposal is validated against your real data, shown for review
(with conflicts and likely duplicates unticked), validated again right before it is applied, and can
be undone. Bulk changes are resolved by the app, never by the model.

Voice input uses Apple's speech recognition (on the device when available) - no OpenAI key needed.

## Differences from the Windows app

- Reminders are system notifications and also arrive while the app is closed. iOS keeps at most 64
  pending notifications per app; the nearest 60 are scheduled and the rest on the next change or
  launch.
- Voice input uses the iOS recognizer instead of OpenAI `gpt-4o-mini-transcribe`.
- The board shows one column at a time (swipe or tap the column switcher); drag a card by touching
  and holding it, or use its context menu (move to another column, move up/down).
- iPhone additions (inspired by Todoery): the List is grouped into Overdue / Today / Upcoming /
  No due date / Completed; tasks are sorted by due date by default; a flag on each row changes
  priority; category chips above the tasks; a month calendar; a progress sheet with a weekly chart.
  The sort and calendar choice are device settings - the data file keeps the Windows layout (board
  or list), so files stay compatible.
- Russian short weekday names are capitalized as iOS writes them ("Чт", Windows: "чт").
- No desktop installer/portable ZIP; no Windows-only texts.

## Not included yet

- Cloud sync (the SwiftData schema is versioned and CloudKit-ready: no unique constraints, defaults
  for every field), widgets, Siri / App Intents, Live Activities.
