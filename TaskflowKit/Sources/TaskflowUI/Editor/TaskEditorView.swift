// The task form - TaskDialog.jsx, ScheduleFields.jsx, SubtaskEditor.jsx and LabelInput.jsx on
// iPhone. The form produces the same field set as the Windows app (normalized by the task model on
// save). Closing with unsaved changes asks first; the explicit Cancel discards after confirmation.
import SwiftUI
import TaskflowCore

/// The editable values of a task (toFormValues).
struct TaskForm: Equatable {
    var title = ""
    var description = ""
    var priority = Priority.medium
    var status = TaskStatus.todo
    var dueDate: String?
    var dueTime: String?
    var reminders: [Int] = []
    var recurrence: Recurrence?
    var estimateMinutes: Int?
    var planned: Planned?
    var labels: [String] = []
    var categoryId: String?
    var subtasks: [Subtask] = []

    init(task: TaskItem?, defaultCategoryId: String?, defaultDueDate: String? = nil) {
        guard let task else {
            categoryId = defaultCategoryId
            dueDate = defaultDueDate
            return
        }
        title = task.title
        description = task.description
        priority = task.priority
        status = task.status
        dueDate = task.dueDate
        dueTime = task.dueTime
        reminders = task.reminders
        recurrence = task.recurrence
        estimateMinutes = task.estimateMinutes
        planned = task.planned
        labels = task.labels
        categoryId = task.categoryId
        subtasks = task.subtasks
    }

    var fields: [String: JSONValue] {
        [
            "title": .string(title),
            "description": .string(description),
            "priority": .string(priority.rawValue),
            "status": .string(status.rawValue),
            "dueDate": .from(dueDate),
            "dueTime": .from(dueTime),
            "reminders": .from(reminders),
            "recurrence": recurrence?.json ?? .null,
            "estimateMinutes": .from(estimateMinutes),
            "planned": planned?.json ?? .null,
            "labels": .from(labels),
            "categoryId": .from(categoryId),
            // Empty new subtasks are dropped by normalization; titles are trimmed.
            "subtasks": .array(subtasks.map(\.json)),
        ]
    }
}

struct TaskEditorView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let taskId: String?
    let defaultCategoryId: String?
    var onDelete: (String) -> Void

    @LocalState private var form: TaskForm
    @LocalState private var initial: TaskForm
    @LocalState private var titleError = false
    @LocalState private var confirmDiscard = false
    @LocalState private var labelText = ""
    @LocalState private var newSubtask = ""
    @FocusState private var titleFocused: Bool

    init(taskId: String?, task: TaskItem?, defaultCategoryId: String?, defaultDueDate: String? = nil, onDelete: @escaping (String) -> Void) {
        self.taskId = taskId
        self.defaultCategoryId = defaultCategoryId
        self.onDelete = onDelete
        let form = TaskForm(task: task, defaultCategoryId: defaultCategoryId, defaultDueDate: defaultDueDate)
        _form = LocalState(initialValue: form)
        _initial = LocalState(initialValue: form)
    }

    var isEdit: Bool { taskId != nil }
    var dirty: Bool { form != initial || !labelText.isEmpty || !newSubtask.isEmpty }

    var body: some View {
        let l10n = store.l10n
        NavigationStack {
            Form {
                mainSection(l10n)
                dueSection(l10n)
                scheduleSection(l10n)
                organizeSection(l10n)
                subtasksSection(l10n)
                if let taskId {
                    Section {
                        Button(role: .destructive) { onDelete(taskId) } label: {
                            Label(l10n.t("actions.delete"), systemImage: "trash").frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bgApp)
            .navigationTitle(isEdit ? l10n.t("taskForm.editTitle") : l10n.t("taskForm.createTitle"))
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(l10n.t("actions.cancel")) { dirty ? (confirmDiscard = true) : dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isEdit ? l10n.t("actions.save") : l10n.t("actions.createTask")) { submit() }
                        .fontWeight(.semibold)
                }
            }
            .confirmationDialog(l10n.t("discard.title"), isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button(l10n.t("discard.confirm"), role: .destructive) { dismiss() }
                Button(l10n.t("discard.keepEditing"), role: .cancel) {}
            } message: {
                Text(l10n.t("discard.message"))
            }
            .onAppear { if !isEdit { titleFocused = true } }
        }
        .interactiveDismissDisabled(dirty)
        .tint(Theme.accent)
    }

    func submit() {
        let errors = TaskModel.validateTaskFields(title: form.title)
        guard errors.isEmpty else {
            titleError = true
            titleFocused = true
            return
        }
        commitPendingInput()
        store.submitTask(editing: taskId, fields: form.fields)
        dismiss()
    }

    /// Text typed into the label / subtask fields but not added yet is kept, as if added.
    func commitPendingInput() {
        if !labelText.trimmingCharacters(in: .whitespaces).isEmpty { addLabels() }
        if Subtasks.validateTitle(newSubtask) == nil { addSubtask() }
    }

    // MARK: Sections

    @ViewBuilder
    func mainSection(_ l10n: L10n) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                TextField(l10n.t("taskForm.titlePlaceholder"), text: $form.title, axis: .vertical)
                    .font(.headline)
                    .focused($titleFocused)
                    .sentenceTextEntry()
                    .onChange(of: form.title) {
                        if form.title.count > TaskModel.Limits.title { form.title = String(form.title.prefix(TaskModel.Limits.title)) }
                        if titleError, !form.title.trimmingCharacters(in: .whitespaces).isEmpty { titleError = false }
                    }
                if titleError {
                    Text(l10n.t("validation.titleRequired")).font(.caption).foregroundStyle(Theme.danger)
                }
            }
            TextField(l10n.t("taskForm.descriptionPlaceholder"), text: $form.description, axis: .vertical)
                .lineLimit(2...8)
                .foregroundStyle(Theme.textSecondary)
                .onChange(of: form.description) {
                    if form.description.count > TaskModel.Limits.description { form.description = String(form.description.prefix(TaskModel.Limits.description)) }
                }
            Picker(l10n.t("priority.label"), selection: $form.priority) {
                ForEach([Priority.low, .medium, .high], id: \.self) { priority in
                    Text(l10n.t("priority.\(priority.rawValue)")).tag(priority)
                }
            }
            .pickerStyle(.segmented)
            .listRowBackground(Theme.bgCard)
            if isEdit {
                Picker(l10n.t("list.status"), selection: $form.status) {
                    ForEach(TaskStatus.allCases, id: \.self) { status in
                        Text(l10n.t("columns.\(status.rawValue)")).tag(status)
                    }
                }
            }
        } header: {
            Text(l10n.t("taskForm.title"))
        } footer: {
            if !isEdit { Text(l10n.t("taskForm.createSubtitle", ["column": l10n.t("columns.todo")])) }
        }
        .listRowBackground(Theme.bgCard)
    }

    @ViewBuilder
    func dueSection(_ l10n: L10n) -> some View {
        Section(l10n.t("taskForm.dueDate")) {
            Toggle(l10n.t("taskForm.dueDate"), isOn: Binding(
                get: { form.dueDate != nil },
                set: { on in setDueDate(on ? (form.dueDate ?? store.todayKey) : nil) }
            ))
            if let dueDate = form.dueDate {
                DatePicker(l10n.t("datePicker.choose"), selection: Binding(
                    get: { Schedule.localInstant(dueDate) },
                    set: { setDueDate(Schedule.localDateKey($0)) }
                ), displayedComponents: .date)
                .environment(\.locale, store.locale)
            }
            QuickDatesRow(onPick: setDueDate)
        }
        .listRowBackground(Theme.bgCard)
    }

    /// A new due date keeps the rule's alignment fields valid (as the task model would on save).
    func setDueDate(_ key: String?) {
        form.dueDate = key
        if key == nil {
            form.dueTime = nil
            form.reminders = []
            form.recurrence = nil
        } else {
            form.reminders = Schedule.normalizeReminders(form.reminders, dueDate: key, dueTime: form.dueTime)
        }
    }

    static let timedOffsets = [0, 10, 30, 60, Schedule.dayMinutes]
    static let dayOffsets = [0, Schedule.dayMinutes, 2 * Schedule.dayMinutes, 7 * Schedule.dayMinutes]
    static let weekOrder = [1, 2, 3, 4, 5, 6, 0] // Monday first

    @ViewBuilder
    func scheduleSection(_ l10n: L10n) -> some View {
        let hasDate = form.dueDate != nil
        Section {
            if !hasDate {
                Text(l10n.t("schedule.needsDate")).font(.footnote).foregroundStyle(Theme.textMuted)
            } else {
                Toggle(l10n.t("schedule.dueTime"), isOn: Binding(
                    get: { form.dueTime != nil },
                    set: { on in
                        form.dueTime = on ? (form.dueTime ?? "09:00") : nil
                        // Reminders that need a time are removed with it.
                        form.reminders = Schedule.normalizeReminders(form.reminders, dueDate: form.dueDate, dueTime: form.dueTime)
                    }
                ))
                if let dueTime = form.dueTime {
                    DatePicker(l10n.t("schedule.dueTime"), selection: Binding(
                        get: { Schedule.localInstant(form.dueDate ?? store.todayKey, dueTime) },
                        set: { form.dueTime = Schedule.localTimeKey($0) }
                    ), displayedComponents: .hourAndMinute)
                    .environment(\.locale, store.locale)
                }
                remindersPicker(l10n)
                repeatFields(l10n)
            }
            HStack {
                Text(l10n.t("schedule.estimate"))
                Spacer()
                TextField(l10n.t("ios.noEstimate"), value: Binding(
                    get: { form.estimateMinutes },
                    set: { form.estimateMinutes = Schedule.normalizeEstimate($0) }
                ), format: .number)
                .multilineTextAlignment(.trailing)
                .numberKeyboard()
                .frame(maxWidth: 120)
            }
            if let planned = form.planned {
                VStack(alignment: .leading, spacing: 6) {
                    Text(l10n.t("schedule.plannedInfo", ["date": l10n.formatDate(planned.date), "time": planned.time]))
                        .font(.footnote)
                        .foregroundStyle(Theme.info)
                    Button(l10n.t("schedule.removePlan"), role: .destructive) { form.planned = nil }
                        .font(.footnote)
                }
            }
        } header: {
            Text(l10n.t("schedule.title"))
        } footer: {
            if form.recurrence != nil { Text(l10n.t("schedule.repeatHint")) }
        }
        .listRowBackground(Theme.bgCard)
    }

    @ViewBuilder
    func remindersPicker(_ l10n: L10n) -> some View {
        let timed = form.dueTime != nil
        let offsets = timed ? Self.timedOffsets : Self.dayOffsets
        VStack(alignment: .leading, spacing: 8) {
            Text(l10n.t("schedule.reminders"))
            FlowLayout(spacing: 8) {
                ForEach(offsets, id: \.self) { offset in
                    let on = form.reminders.contains(offset)
                    Button {
                        var list = on ? form.reminders.filter { $0 != offset } : form.reminders + [offset]
                        list = Schedule.normalizeReminders(list.sorted(), dueDate: form.dueDate, dueTime: form.dueTime)
                        form.reminders = list
                    } label: {
                        IconText(ScheduleText.reminderLabel(l10n, offset: offset, timed: timed), systemImage: on ? "bell.fill" : "bell")
                            .font(.footnote)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .foregroundStyle(on ? Theme.bgApp : Theme.textSecondary)
                            .background(on ? Theme.accent : Theme.bgElevated, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            // Reminders set elsewhere (e.g. by the assistant) that are not one of the choices.
            let custom = form.reminders.filter { !offsets.contains($0) }
            if !custom.isEmpty {
                Text(ScheduleText.remindersText(l10n, custom, timed: timed)).font(.caption).foregroundStyle(Theme.textMuted)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    func repeatFields(_ l10n: L10n) -> some View {
        Picker(l10n.t("schedule.repeat"), selection: Binding(
            get: { form.recurrence?.freq },
            set: { setFrequency($0) }
        )) {
            Text(l10n.t("schedule.noRepeat")).tag(Recurrence.Frequency?.none)
            ForEach(Recurrence.Frequency.allCases, id: \.self) { freq in
                Text(l10n.t("schedule.freq.\(freq.rawValue)")).tag(Recurrence.Frequency?.some(freq))
            }
        }
        if let rule = form.recurrence {
            Stepper(value: Binding(
                get: { rule.interval },
                set: { form.recurrence?.interval = max(1, min(Schedule.maxRecurrenceInterval, $0)) }
            ), in: 1...Schedule.maxRecurrenceInterval) {
                Text(rule.interval > 1 ? l10n.t("schedule.every.\(rule.freq.rawValue)N", ["count": rule.interval]) : l10n.t("schedule.every.\(rule.freq.rawValue)"))
            }
            if rule.freq == .weekly {
                VStack(alignment: .leading, spacing: 6) {
                    Text(l10n.t("schedule.weekdaysLabel")).font(.footnote).foregroundStyle(Theme.textMuted)
                    HStack(spacing: 6) {
                        ForEach(Self.weekOrder, id: \.self) { day in
                            let on = rule.weekdays?.contains(day) ?? false
                            Button {
                                var days = rule.weekdays ?? []
                                days = on ? days.filter { $0 != day } : days + [day]
                                // At least one day stays selected.
                                if !days.isEmpty { form.recurrence?.weekdays = days.sorted() }
                            } label: {
                                Text(l10n.t("schedule.weekdays.\(day)"))
                                    .font(.caption.weight(.semibold))
                                    .frame(maxWidth: .infinity, minHeight: 32)
                                    .foregroundStyle(on ? Theme.bgApp : Theme.textSecondary)
                                    .background(on ? Theme.accent : Theme.bgElevated, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                }
            }
            if rule.freq == .monthly {
                Stepper(value: Binding(
                    get: { rule.monthDay ?? 1 },
                    set: { form.recurrence?.monthDay = max(1, min(31, $0)) }
                ), in: 1...31) {
                    Text(l10n.t("schedule.monthlyHint", ["day": rule.monthDay ?? 1]))
                }
            }
            Text(ScheduleText.recurrenceLabel(l10n, rule)).font(.footnote).foregroundStyle(Theme.accent)
        }
    }

    func setFrequency(_ freq: Recurrence.Frequency?) {
        guard let freq, let dueDate = form.dueDate else {
            form.recurrence = nil
            return
        }
        var next = Recurrence(freq: freq, interval: form.recurrence?.interval ?? 1)
        if freq == .weekly { next.weekdays = (form.recurrence?.weekdays?.isEmpty == false) ? form.recurrence?.weekdays : [Schedule.weekdayOf(dueDate)] }
        if freq == .monthly { next.monthDay = form.recurrence?.monthDay ?? Int(dueDate.suffix(2)) }
        form.recurrence = next
    }

    @ViewBuilder
    func organizeSection(_ l10n: L10n) -> some View {
        Section(l10n.t("taskForm.category") + " · " + l10n.t("taskForm.labels")) {
            Picker(l10n.t("taskForm.category"), selection: $form.categoryId) {
                Text(l10n.t("nav.uncategorized")).tag(String?.none)
                ForEach(store.categories) { category in
                    Text(category.name).tag(String?.some(category.id))
                }
            }
            if !form.labels.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(form.labels, id: \.self) { label in
                        Button {
                            form.labels.removeAll { $0 == label }
                        } label: {
                            HStack(spacing: 4) {
                                Text(label)
                                Image(systemName: "xmark")
                            }
                            .chip(Theme.label(label))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(l10n.t("taskForm.removeLabel", ["label": label]))
                    }
                }
            }
            if form.labels.count < TaskModel.Limits.labels {
                TextField(l10n.t("taskForm.labelsPlaceholder"), text: $labelText)
                    .plainTextEntry()
                    .onSubmit(addLabels)
                    .onChange(of: labelText) { if labelText.contains(",") { addLabels() } }
                let suggestions = store.labelSuggestions.filter { suggestion in !form.labels.contains { $0.lowercased() == suggestion.lowercased() } }
                if !suggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(l10n.t("taskForm.labelsSuggestions")).font(.caption).foregroundStyle(Theme.textMuted)
                        FlowLayout(spacing: 6) {
                            ForEach(suggestions.prefix(12), id: \.self) { suggestion in
                                Button { form.labels = TaskModel.normalizeLabels(form.labels + [suggestion]) } label: {
                                    Text("+ " + suggestion).chip(Theme.label(suggestion))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            } else {
                Text(l10n.t("taskForm.labelsLimit", ["count": TaskModel.Limits.labels])).font(.caption).foregroundStyle(Theme.textMuted)
            }
        }
        .listRowBackground(Theme.bgCard)
    }

    func addLabels() {
        form.labels = TaskModel.normalizeLabels(form.labels + TaskModel.splitLabels(labelText))
        labelText = ""
    }

    @ViewBuilder
    func subtasksSection(_ l10n: L10n) -> some View {
        Section {
            ForEach($form.subtasks) { $subtask in
                HStack(spacing: 10) {
                    Button { subtask.done.toggle() } label: {
                        Image(systemName: subtask.done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(subtask.done ? Theme.accent : Theme.textMuted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(l10n.t("subtasks.toggle", ["title": subtask.title]))
                    TextField(l10n.t("subtasks.placeholder"), text: $subtask.title, axis: .vertical)
                        .strikethrough(subtask.done, color: Theme.textMuted)
                        .foregroundStyle(subtask.done ? Theme.textMuted : Theme.textPrimary)
                        .onChange(of: subtask.title) {
                            if subtask.title.count > Subtasks.titleLimit { subtask.title = String(subtask.title.prefix(Subtasks.titleLimit)) }
                        }
                }
            }
            .onDelete { form.subtasks.remove(atOffsets: $0) }
            .onMove { form.subtasks.move(fromOffsets: $0, toOffset: $1) }
            if form.subtasks.count < Subtasks.limit {
                HStack {
                    Image(systemName: "plus.circle").foregroundStyle(Theme.accent)
                    TextField(l10n.t("ios.subtaskAddPlaceholder"), text: $newSubtask)
                        .onSubmit(addSubtask)
                        .submitLabel(.next)
                    if Subtasks.validateTitle(newSubtask) == nil {
                        Button(l10n.t("subtasks.add"), action: addSubtask).font(.footnote.weight(.semibold))
                    }
                }
            } else {
                Text(l10n.t("subtasks.limit", ["count": Subtasks.limit])).font(.caption).foregroundStyle(Theme.textMuted)
            }
        } header: {
            HStack {
                Text(l10n.t("subtasks.title"))
                Spacer()
                if let progress = Subtasks.progress(TaskModel.createTask(["title": "x", "subtasks": .array(form.subtasks.map(\.json))])) {
                    Text("\(progress.done)/\(progress.total)").monospacedDigit()
                }
            }
        }
        .listRowBackground(Theme.bgCard)
    }

    func addSubtask() {
        guard Subtasks.validateTitle(newSubtask) == nil, form.subtasks.count < Subtasks.limit else { return }
        form.subtasks.append(Subtasks.create(newSubtask))
        newSubtask = ""
    }
}
