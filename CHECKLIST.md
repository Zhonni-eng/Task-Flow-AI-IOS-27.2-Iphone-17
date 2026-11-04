# Implementation checklist

Legend: [x] done and verified (tests, a build, or by hand on the iPhone 17 simulator, iOS 27.2) ·
[~] done, compiled, not exercised by hand yet · [ ] not done

## Environment
- [x] Xcode 27.2, iOS 27.2 Simulator runtime, iPhone 17 simulator
- [x] App builds for the simulator and for a real iPhone (Debug and Release, 0 errors, 0 warnings)
- [ ] Signing team selected in Xcode (needs your Apple ID)
- [ ] Run on the real iPhone 17

## Core logic (TaskflowCore) - 169 tests pass (`./scripts/test-core.sh`)
- [x] Task model, subtasks, categories (RU/EN synonym matching), labels, limits
- [x] Deadlines, due time, reminders, recurrence, DST and time-zone rules (JavaScript semantics)
- [x] Reducer: create, update, delete, move/reorder, bulk, replace, category reassignment,
      recurring completion
- [x] Views: search, filters, sorts, board/list, scope, statistics, scoped drag positions
- [x] Storage: schema v4, migrations v0→v4, repair, newer-version read-only, atomic writes, `.bak`
- [x] Import/export of `taskflow-data.json`
- [x] AI: wire format, plan validation, apply/undo, proposal re-validation, prompt, context,
      providers, adapters (simulated services), settings, connection, chat
- [x] Reminders engine, localization, demo tasks

## On the iPhone 17 simulator
- [x] Launch, demo tasks, SwiftData store + Windows-format copy in Documents (`taskflow-data.json`, `.bak`)
- [x] Sidebar with logo header, counts, categories; create category ("Учёба")
- [x] Board: column switcher and paging land exactly on a column; cards show priority, title,
      description, labels, due states (overdue / today / tomorrow)
- [x] List: rows, status circle toggles (recurring task moves to its next date), swipe actions,
      delete confirmation, Select + bulk toolbar (move to category)
- [x] Task editor: priority, status, due date + quick dates, due time, reminders, weekly repeat,
      labels and suggestions, save; new task creation
- [x] Settings: language switch RU ↔ EN (whole UI), reminders, day-plan availability
- [x] Notifications: permission prompt, reminder scheduled for the right time
- [x] AI settings: unrecognized key rejected locally (nothing sent); Advanced → OpenAI-compatible
      shows base URL and model fields; a key connected by you shows "Key saved" (stored in Keychain,
      not in files)
- [x] Assistant screen: intro, examples, privacy text, "assistant is off" state
- [~] Assistant with a live service: proposal review, apply, undo (covered by tests; not run
      against a real service, so no tokens are billed to your key)
- [~] Export / import through the Files sheets
- [~] Voice input (needs a microphone; the simulator has none)
- [~] Drag and drop of cards between columns (needs a real finger; the menu alternative works)

## Todoery-style additions (checked on the simulator)
- [x] Sort by due date by default (same date: timed tasks first, by time); the chosen sort is
      remembered on the device, "Reset all" returns to due date
- [x] List in sections: Overdue, Today, Upcoming, No due date, Completed (at the bottom, most
      recently completed first); tap a header to collapse it (remembered)
- [x] Completing a task in the list moves it to Completed right away
- [x] Each task is a separate card with a priority stripe; flag button changes priority
- [x] Category chips above the tasks (shown when categories exist)
- [x] Calendar: month grid with dots per due task (overdue red, completed grey), tasks of the
      chosen day, "+" creates a task on that day
- [x] Progress: completed today / 7 days, open, overdue, completed-per-day chart, open by priority

## Fixed during simulator testing
- [x] Column paging landed between columns
- [x] Due date spilled out of cards (wrapping layout width)
- [x] Reminder chips rendered as empty tall shapes in the editor
- [x] Floating "+" covered cards and the search bar → moved to the toolbar
- [x] Sidebar had an empty title area → Taskflow logo, name and tagline
- [x] Duplicate circle in List select mode
- [x] Destructive swipe actions were mint instead of red
- [x] Priority stripe stuck out of the card's rounded corner
- [x] The package (tests) did not build for macOS after the section spacing change

## Performance pass (2026-11-04)
Measured with `PerformanceTests` (3000 tasks, release build, per call) and in the simulator with
2000 tasks (Debug build, before → after):

| | Before | After |
|---|---|---|
| List sorted by due date | 9.7 ms | 1.2 ms |
| Search | 26.1 ms | 1.9 ms |
| List sections / board | 11.5 / 11.2 ms | 2.4 / 1.9 ms |
| Due texts for 200 rows / one date format | 23.2 ms / 136 µs | 2.8 ms / 2 µs |
| Statistics | 1.0 ms | 0.5 ms |
| Reminder sync (computation) | 11.8 ms | 5.1 ms |
| Rows built by the List at launch | 6000 (all tasks, 3×) | 25 (visible) |
| Main-thread work before the first frame | 625 ms | 343 ms |
| CPU per completed task (save + UI) | 0.8–1.2 s | ~0.5 s |
| CPU to launch and settle / memory | ~4.9 s / ~320 MB | ~4.2 s / ~290 MB |

- [x] Each save validates once (was twice); the Windows-format copy is prepared and written on a
      background queue, in order (and waited for before the app is suspended)
- [x] SwiftData writes only the fields that changed since the last read or write
- [x] Reminders: overlapping syncs are combined; only added, changed or removed notifications are
      handed to iOS (was: all removed and re-added on every change)
- [x] Derived values (board, sections, counts, statistics, calendar days) computed once per change
- [x] Data restored from the backup copy is stored at once (it was re-recovered, with the notice,
      on every launch until the next edit)
- [x] Removed unused code: preview helpers (`PreviewScreens.swift`), `toggleSubtask`,
      `importBackupName`, `bottomBarPlacement`, `groupedList`, the conditional tap helper,
      `Language.shortLabel`, an unused calendar

## Later
- [ ] Cloud sync
- [ ] Widgets, App Intents / Siri, Live Activities
