// Settings - AppSettingsDialog.jsx and LanguageSwitcher.jsx on iPhone, plus the iPhone-only data
// section: export of the Windows-compatible taskflow-data.json, import (checked, confirmed, with
// copies of the current data and of the imported file kept first), and where backups live.
import SwiftUI
import TaskflowCore
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(AssistantModel.self) private var assistant
    @Environment(\.dismiss) private var dismiss
    @LocalState private var remindersOn = true
    @LocalState private var allDayTime = Date()
    @LocalState private var planOn = false
    @LocalState private var from = Date()
    @LocalState private var until = Date()
    @LocalState private var availabilityError = false
    @LocalState private var exporting = false
    @LocalState private var importing = false
    @LocalState private var pendingImport: (DocumentCodec.Result, Data)?
    @LocalState private var importError: String?
    @LocalState private var permission: NotificationPermission = .unknown

    static func time(_ key: String) -> Date { Schedule.localInstant("2001-01-01", key) }
    static func key(_ date: Date) -> String { Schedule.localTimeKey(date) }

    var body: some View {
        let l10n = store.l10n
        NavigationStack {
            Form {
                Section(l10n.t("ios.language")) {
                    Picker(l10n.t("language.label"), selection: Binding(get: { store.settings.language }, set: { store.setLanguage($0) })) {
                        ForEach(Language.allCases, id: \.self) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .listRowBackground(Theme.bgCard)

                Section {
                    Toggle(l10n.t("appSettings.remindersEnabled"), isOn: $remindersOn)
                        .onChange(of: remindersOn) { saveReminders() }
                    DatePicker(l10n.t("appSettings.allDayTime"), selection: $allDayTime, displayedComponents: .hourAndMinute)
                        .disabled(!remindersOn)
                        .onChange(of: allDayTime) { saveReminders() }
                    if permission == .denied && remindersOn {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(l10n.t("appSettings.notificationsDenied")).font(.footnote).foregroundStyle(Theme.warning)
                            Button(l10n.t("appSettings.openSystemSettings")) { SystemSettings.open() }.font(.footnote)
                        }
                    }
                } header: {
                    Text(l10n.t("appSettings.reminders"))
                } footer: {
                    Text(l10n.t("appSettings.remindersHint"))
                }
                .listRowBackground(Theme.bgCard)

                Section {
                    Toggle(l10n.t("appSettings.availability"), isOn: $planOn)
                        .onChange(of: planOn) { saveAvailability() }
                    if planOn {
                        DatePicker(l10n.t("appSettings.availableFrom"), selection: $from, displayedComponents: .hourAndMinute)
                            .onChange(of: from) { saveAvailability() }
                        DatePicker(l10n.t("appSettings.availableUntil"), selection: $until, displayedComponents: .hourAndMinute)
                            .onChange(of: until) { saveAvailability() }
                        if availabilityError {
                            Text(l10n.t("appSettings.errors.availabilityInvalid")).font(.footnote).foregroundStyle(Theme.danger)
                        }
                    }
                } footer: {
                    Text(l10n.t("appSettings.availabilityHint"))
                }
                .listRowBackground(Theme.bgCard)

                Section {
                    NavigationLink {
                        AISettingsView()
                    } label: {
                        HStack {
                            Label(l10n.t("ai.settings"), systemImage: "sparkles")
                            Spacer()
                            Text(l10n.t("ai.connection.\(assistant.connectionStatus.rawValue)"))
                                .font(.footnote)
                                .foregroundStyle(assistant.connectionStatus == .connected ? Theme.accent : Theme.textMuted)
                        }
                    }
                }
                .listRowBackground(Theme.bgCard)

                Section {
                    Button { exporting = true } label: { Label(l10n.t("ios.export"), systemImage: "square.and.arrow.up") }
                    Button { importing = true } label: { Label(l10n.t("ios.import"), systemImage: "square.and.arrow.down") }
                } header: {
                    Text(l10n.t("ios.data"))
                } footer: {
                    Text([l10n.t("ios.exportHint"), l10n.t("ios.importHint"), l10n.t("ios.backupsHint")].joined(separator: "\n\n"))
                }
                .listRowBackground(Theme.bgCard)

                Section(l10n.t("ios.about")) {
                    LabeledContent(l10n.t("app.name"), value: l10n.t("ios.version", ["version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"]))
                    Text(l10n.t("app.offline")).font(.footnote).foregroundStyle(Theme.textMuted)
                }
                .listRowBackground(Theme.bgCard)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bgApp)
            .navigationTitle(l10n.t("appSettings.title"))
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(l10n.t("ios.done")) { dismiss() }.fontWeight(.semibold) }
            }
            .fileExporter(isPresented: $exporting, document: TaskflowFile(data: store.exportData()), contentType: .json, defaultFilename: "taskflow-data") { _ in }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
                handleImport(result)
            }
            .alert(l10n.t("ios.importConfirmTitle"), isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } })) {
                Button(l10n.t("ios.importConfirm"), role: .destructive) {
                    if let (checked, data) = pendingImport { store.applyImport(checked, original: data) }
                    pendingImport = nil
                    load()
                }
                Button(l10n.t("actions.cancel"), role: .cancel) { pendingImport = nil }
            } message: {
                if let (checked, _) = pendingImport {
                    Text(l10n.t("ios.importConfirmMessage", ["tasks": checked.document.tasks.count, "categories": checked.document.categories.count, "file": "taskflow-data.before-import-….json"]))
                }
            }
            .alert(importError ?? "", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) {}
            }
            .onAppear(perform: load)
            .task {
                if let notifier = store.notifier { permission = await notifier.refreshPermission() }
            }
        }
        .tint(Theme.accent)
    }

    func load() {
        let settings = store.settings
        remindersOn = settings.reminders.enabled
        allDayTime = Self.time(settings.reminders.allDayTime)
        planOn = settings.availability != nil
        from = Self.time(settings.availability?.start ?? "09:00")
        until = Self.time(settings.availability?.end ?? "18:00")
    }

    func saveReminders() {
        store.setReminders(ReminderSettings(enabled: remindersOn, allDayTime: Self.key(allDayTime)))
    }

    func saveAvailability() {
        guard planOn else {
            availabilityError = false
            store.setAvailability(nil)
            return
        }
        if let availability = DocumentCodec.sanitizeAvailability(["start": .string(Self.key(from)), "end": .string(Self.key(until))]) {
            availabilityError = false
            store.setAvailability(availability)
        } else {
            availabilityError = true
        }
    }

    func handleImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            importError = store.l10n.t("ios.importReadFailed")
            return
        }
        switch store.checkImport(data) {
        case .ready(let checked, let original): pendingImport = (checked, original)
        case .failed(let message): importError = message
        }
    }
}

/// The exported data file.
struct TaskflowFile: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

// MARK: - AI settings

/// AiSettingsDialog.jsx on iPhone: paste a key, Connect (checked first, stored in the Keychain only
/// if the check worked), status, enable, disconnect; Advanced: the service, a model id, or an
/// OpenAI-compatible API (base URL + model).
struct AISettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(AssistantModel.self) private var assistant
    @LocalState private var key = ""
    @LocalState private var provider: ProviderID?
    @LocalState private var model = ""
    @LocalState private var baseUrl = ""
    @LocalState private var connecting = false
    @LocalState private var message: (text: String, error: Bool)?
    @LocalState private var confirmDisconnect = false

    var body: some View {
        let l10n = store.l10n
        let state = assistant.publicState
        let status = assistant.connectionStatus
        Form {
            Section {
                Text(l10n.t("ai.intro")).font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.bgCard)
            Section {
                HStack {
                    Circle().fill(status == .connected ? Theme.accent : status == .failed || status == .unreadable ? Theme.danger : status == .none ? Theme.textMuted : Theme.warning)
                        .frame(width: 8, height: 8)
                    Text(l10n.t(connecting ? "ai.connection.testing" : "ai.connection.\(status.rawValue)")).fontWeight(.semibold)
                }
                Text(hint(status, state)).font(.footnote).foregroundStyle(Theme.textMuted)
                SecureField(state.key == .none ? l10n.t("ai.keyPlaceholder") : l10n.t("ai.keyReplacePlaceholder"), text: $key)
                    .plainTextEntry()
                    .textContentType(.password)
                Button {
                    Task { await connect() }
                } label: {
                    HStack {
                        if connecting { ProgressView() }
                        Text(connecting ? l10n.t("ai.connecting") : state.key == .none ? l10n.t("ai.connect") : l10n.t("ai.reconnect"))
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(connecting || (state.key == .none && key.trimmingCharacters(in: .whitespaces).isEmpty))
                if state.key != .none {
                    Text(l10n.t("ai.reconnectHint")).font(.caption).foregroundStyle(Theme.textMuted)
                }
                if let message {
                    Text(message.text).font(.footnote).foregroundStyle(message.error ? Theme.danger : Theme.accent)
                }
                if !state.secureStorageAvailable {
                    Text(l10n.t("ai.secureStorageUnavailable")).font(.footnote).foregroundStyle(Theme.danger)
                }
            } header: {
                Text(l10n.t("ai.apiKey"))
            }
            .listRowBackground(Theme.bgCard)
            Section {
                Toggle(l10n.t("ai.enable"), isOn: Binding(get: { state.enabled }, set: { on in
                    Task {
                        if await !assistant.setEnabled(on) { message = (l10n.t(on ? "ai.errors.NOT_CONNECTED" : "ai.errors.generic"), true) }
                    }
                }))
                .disabled(state.key != .stored || state.verifiedAt == nil)
                if state.key != .none {
                    Button(l10n.t("ai.disconnect"), role: .destructive) { confirmDisconnect = true }
                }
            }
            .listRowBackground(Theme.bgCard)
            Section {
                Picker(l10n.t("ai.advanced.service"), selection: $provider) {
                    Text(l10n.t("ai.services.auto")).tag(ProviderID?.none)
                    ForEach(ProviderID.allCases, id: \.self) { id in
                        Text(l10n.t("ai.services.\(id.rawValue)")).tag(ProviderID?.some(id))
                    }
                }
                if provider == .openaiCompatible {
                    TextField(l10n.t("ai.advanced.baseUrl"), text: $baseUrl).plainTextEntry().textContentType(.URL)
                    TextField(l10n.t("ai.advanced.model"), text: $model).plainTextEntry()
                } else {
                    TextField(l10n.t("ai.advanced.modelOptional"), text: $model, prompt: Text(l10n.t("ai.advanced.modelPlaceholder"))).plainTextEntry()
                }
                if let current = state.provider {
                    Text(l10n.t("ai.advanced.current", ["service": l10n.t("ai.services.\(current.rawValue)")])).font(.footnote).foregroundStyle(Theme.textMuted)
                }
            } header: {
                Text(l10n.t("ai.advanced.title"))
            } footer: {
                Text([l10n.t("ai.advanced.detectionHint"), l10n.t("ai.advanced.modelHint"), provider == .openaiCompatible ? l10n.t("ai.advanced.compatibleHint") : nil].compactMap { $0 }.joined(separator: "\n\n"))
            }
            .listRowBackground(Theme.bgCard)
            Section(l10n.t("ai.voice.title")) {
                Text(l10n.t("ai.voice.onDevice")).font(.footnote).foregroundStyle(Theme.textSecondary)
            }
            .listRowBackground(Theme.bgCard)
            Section {
                Text(l10n.t("assistant.privacy")).font(.footnote).foregroundStyle(Theme.textMuted)
            }
            .listRowBackground(Theme.bgCard)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bgApp)
        .navigationTitle(l10n.t("ai.settingsTitle"))
        .inlineTitle()
        .confirmationDialog(l10n.t("ai.disconnect"), isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button(l10n.t("ai.disconnect"), role: .destructive) {
                Task {
                    if await assistant.disconnect() { message = (l10n.t("ai.disconnectedNotice"), false) }
                }
            }
            Button(l10n.t("actions.cancel"), role: .cancel) {}
        }
        .onAppear {
            if let compatible = assistant.publicState.compatible {
                baseUrl = compatible.baseUrl
            }
            Task { await assistant.refreshStatus() }
        }
    }

    func hint(_ status: ConnectionStatus, _ state: AIPublicState) -> String {
        let l10n = store.l10n
        switch status {
        case .saved:
            if let date = l10n.formatTimestamp(state.verifiedAt) { return l10n.t("ai.connectionHint.savedAt", ["date": date]) }
            return l10n.t("ai.connectionHint.saved")
        default:
            return l10n.t("ai.connectionHint.\(status.rawValue)")
        }
    }

    func connect() async {
        let l10n = store.l10n
        connecting = true
        message = nil
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let hadKey = assistant.publicState.key != .none
        let request = trimmed.isEmpty
            ? ConnectRequest()
            : ConnectRequest(key: trimmed, provider: provider, baseUrl: baseUrl.isEmpty ? nil : baseUrl, model: model.isEmpty ? nil : model)
        let code = await assistant.connect(request)
        connecting = false
        if let code {
            let known = l10n.has("ai.connectErrors.\(code.rawValue)")
            var text = l10n.t("ai.connectFailed") + " " + l10n.t(known ? "ai.connectErrors.\(code.rawValue)" : "ai.connectErrors.generic")
            if hadKey && !trimmed.isEmpty { text += " " + l10n.t("ai.previousKeyKept") }
            message = (text, true)
        } else {
            key = ""
            message = (trimmed.isEmpty ? l10n.t("ai.connectionChecked") : l10n.t("ai.connectedNotice"), false)
        }
    }
}
