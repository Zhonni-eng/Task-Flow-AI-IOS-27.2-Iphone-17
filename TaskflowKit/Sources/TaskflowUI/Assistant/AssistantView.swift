// The assistant - AiPanel.jsx on iPhone: the conversation, each proposal as a reviewable list
// (kind, task, "from → to" details, affected tasks, warnings), with checkboxes, Apply / Don't create,
// Undo of the last confirmed batch, token usage, and voice input into the message box.
import SwiftUI
import TaskflowCore

struct AssistantView: View {
    @Environment(AppStore.self) private var store
    @Environment(AssistantModel.self) private var assistant
    @Environment(\.dismiss) private var dismiss
    @LocalState private var text = ""
    @LocalState private var speech = SpeechInput()
    @LocalState private var settingsOpen = false
    @FocusState private var inputFocused: Bool

    var body: some View {
        let l10n = store.l10n
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            notice
                            if assistant.messages.isEmpty { emptyState }
                            ForEach(assistant.messages) { message in
                                MessageView(message: message).id(message.id)
                            }
                            if assistant.sending {
                                HStack(spacing: 8) {
                                    ProgressView()
                                    Text(l10n.t("assistant.thinking")).font(.footnote).foregroundStyle(Theme.textSecondary)
                                }
                                .id("thinking")
                            }
                            if assistant.usage.requests > 0 { usageLine }
                        }
                        .padding(16)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: assistant.messages.count) {
                        withAnimation { proxy.scrollTo(assistant.messages.last?.id, anchor: .bottom) }
                    }
                    .onChange(of: assistant.sending) {
                        if assistant.sending { withAnimation { proxy.scrollTo("thinking", anchor: .bottom) } }
                    }
                }
                inputBar
            }
            .background(Theme.bgApp)
            .navigationTitle(l10n.t("assistant.title"))
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(l10n.t("actions.close")) { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { Task { await assistant.reset() } } label: { Label(l10n.t("assistant.newConversation"), systemImage: "plus.bubble") }
                            .disabled(assistant.messages.isEmpty || assistant.applying)
                        Button { settingsOpen = true } label: { Label(l10n.t("ai.settings"), systemImage: "gearshape") }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .navigationDestination(isPresented: $settingsOpen) { AISettingsView() }
            .darkNavigationBar()
        }
        .tint(Theme.accent)
    }

    @ViewBuilder
    var notice: some View {
        let l10n = store.l10n
        let state = assistant.publicState
        if !(state.enabled && state.key == .stored) {
            VStack(alignment: .leading, spacing: 8) {
                Text(state.key == .none ? l10n.t("assistant.notConfigured") : l10n.t("assistant.disabled"))
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                Button(l10n.t("assistant.openSettings")) { settingsOpen = true }
                    .font(.footnote.weight(.semibold))
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.warningSoft, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
        }
    }

    var emptyState: some View {
        let l10n = store.l10n
        return VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "sparkles").font(.title).foregroundStyle(Theme.accent)
            Text(l10n.t("assistant.empty")).foregroundStyle(Theme.textPrimary)
            Text(l10n.t("assistant.examples")).font(.footnote).foregroundStyle(Theme.textSecondary)
            Text(l10n.t("assistant.privacy")).font(.caption).foregroundStyle(Theme.textMuted)
        }
        .padding(14)
        .cardSurface()
    }

    var usageLine: some View {
        let l10n = store.l10n
        let usage = assistant.usage
        var text = l10n.t("assistant.usage", ["input": usage.inputTokens, "output": usage.outputTokens])
        if let cost = usage.costUsd {
            text += " · " + l10n.t("assistant.usageCost", ["cost": String(format: "%.4f", cost)])
        } else {
            text += " · " + l10n.t("assistant.usageNoCost")
        }
        return Text(text).font(.caption2).foregroundStyle(Theme.textMuted)
    }

    var inputBar: some View {
        let l10n = store.l10n
        let ready = assistant.isReady
        return VStack(alignment: .leading, spacing: 6) {
            if case .recording(let started) = speech.phase {
                TimelineView(.periodic(from: started, by: 1)) { context in
                    let seconds = Int(context.date.timeIntervalSince(started))
                    Text(l10n.t("assistant.voice.recording", ["time": String(format: "%d:%02d", seconds / 60, seconds % 60)]))
                        .font(.caption)
                        .foregroundStyle(Theme.danger)
                }
            } else if speech.phase == .finishing {
                Text(l10n.t("assistant.voice.transcribing")).font(.caption).foregroundStyle(Theme.textSecondary)
            } else if let code = speech.errorCode {
                Text(l10n.t("assistant.voice.errors.\(l10n.has("assistant.voice.errors.\(code)") ? code : "generic")"))
                    .font(.caption)
                    .foregroundStyle(Theme.danger)
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    speech.toggle(language: store.settings.language) { recognized in
                        let joined = text.isEmpty ? recognized : text + (text.hasSuffix(" ") ? "" : " ") + recognized
                        text = String(joined.prefix(ChatService.maxMessageLength))
                    }
                } label: {
                    Image(systemName: speech.isRecording ? "stop.circle.fill" : "mic")
                        .font(.title3)
                        .foregroundStyle(speech.isRecording ? Theme.danger : Theme.textSecondary)
                        .frame(width: 36, height: 36)
                }
                .disabled(!ready || speech.phase == .finishing)
                .accessibilityLabel(speech.isRecording ? l10n.t("assistant.voice.stop") : l10n.t("assistant.voice.start"))
                TextField(ready ? l10n.t("assistant.placeholder") : l10n.t("assistant.placeholderOff"), text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Theme.bgElevated, in: RoundedRectangle(cornerRadius: 18))
                    .disabled(!ready)
                    .onChange(of: text) { if text.count > ChatService.maxMessageLength { text = String(text.prefix(ChatService.maxMessageLength)) } }
                    .accessibilityLabel(l10n.t("assistant.inputLabel"))
                Button {
                    let message = text
                    text = ""
                    Task { await assistant.send(message) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
                .disabled(!ready || assistant.sending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(l10n.t("assistant.send"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.bgSurface)
    }
}

struct MessageView: View {
    @Environment(AppStore.self) private var store
    @Environment(AssistantModel.self) private var assistant
    let message: AssistantMessage

    var body: some View {
        let l10n = store.l10n
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .foregroundStyle(Theme.bgApp)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityLabel("\(l10n.t("assistant.you")): \(message.text)")
            }
        case .error:
            Label(ReviewTexts.errorText(l10n, code: message.code ?? ""), systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(Theme.danger)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.dangerSoft, in: RoundedRectangle(cornerRadius: Theme.radiusMd))
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if let reply = message.reply { Text(reply).foregroundStyle(Theme.textPrimary) }
                if let question = message.question {
                    Label(question, systemImage: "questionmark.bubble").foregroundStyle(Theme.info)
                }
                if let proposal = message.proposal { ProposalView(messageId: message.id, proposal: proposal) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
        }
    }
}

struct ProposalView: View {
    @Environment(AppStore.self) private var store
    @Environment(AssistantModel.self) private var assistant
    let messageId: UUID
    let proposal: Proposal

    var body: some View {
        let l10n = store.l10n
        let selected = proposal.items.filter(\.selected)
        let onlyCreates = selected.allSatisfy { $0.entry.type == "create" }
        let locked = proposal.status != .pending || assistant.applying
        let count = proposal.items.count
        VStack(alignment: .leading, spacing: 10) {
            Text(proposal.items.allSatisfy { $0.entry.type == "create" } ? l10n.t("assistant.reviewTitle", ["count": count]) : l10n.t("assistant.reviewChanges", ["count": count]))
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
            ForEach(proposal.items) { item in
                ProposalItemRow(item: item, locked: locked) { assistant.toggle(messageId, index: item.index) }
            }
            if let result = proposal.result {
                Text(ReviewTexts.resultText(l10n, result))
                    .font(.footnote)
                    .foregroundStyle(isError(result) ? Theme.danger : Theme.accent)
            }
            if proposal.status == .pending {
                HStack {
                    Button {
                        assistant.apply(messageId)
                    } label: {
                        Text(onlyCreates ? l10n.t("assistant.create", ["count": selected.count]) : l10n.t("assistant.applySelected", ["count": selected.count]))
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(selected.isEmpty || assistant.applying)
                    Button(l10n.t("assistant.dismiss")) { assistant.dismiss(messageId) }
                        .buttonStyle(.bordered)
                        .disabled(assistant.applying)
                }
            }
            if proposal.status == .dismissed {
                Text(l10n.t("assistant.dismissed")).font(.footnote).foregroundStyle(Theme.textMuted)
            }
            if assistant.undoBatch?.messageId == messageId {
                Button {
                    assistant.undo()
                } label: {
                    Label(onlyAppliedCreates ? l10n.t("assistant.undo") : l10n.t("assistant.undoAll"), systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(.bordered)
                .disabled(assistant.applying)
            }
        }
    }

    var onlyAppliedCreates: Bool {
        if case .applied(_, let updated, let deleted, _, _)? = proposal.result { return updated == 0 && deleted == 0 }
        return false
    }

    func isError(_ result: ProposalResult) -> Bool {
        switch result {
        case .changed, .conflict: return true
        case .applied(_, _, _, _, let saved), .undone(_, _, _, let saved): return !saved
        }
    }
}

struct ProposalItemRow: View {
    @Environment(AppStore.self) private var store
    let item: ProposalItem
    let locked: Bool
    var onToggle: () -> Void

    var body: some View {
        let l10n = store.l10n
        let text = ReviewTexts.describe(l10n, item: item, categories: store.categories)
        Button(action: onToggle) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.selected ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(item.selectable ? (item.selected ? Theme.accent : Theme.textSecondary) : Theme.borderStrong)
                VStack(alignment: .leading, spacing: 3) {
                    Text(text.kind).font(.caption2.weight(.semibold)).textCase(.uppercase).foregroundStyle(Theme.accent)
                    Text(text.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                    ForEach(Array(text.details.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    ForEach(Array(text.list.enumerated()), id: \.offset) { _, line in
                        Text("• " + line).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    if let invalid = ReviewTexts.invalidText(l10n, item: item) {
                        Text(invalid).font(.caption).foregroundStyle(Theme.danger)
                    }
                    if item.conflict { Text(l10n.t("assistant.conflict")).font(.caption).foregroundStyle(Theme.warning) }
                    ForEach(text.notes, id: \.self) { note in
                        Text(note).font(.caption).foregroundStyle(Theme.warning)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(item.selectable ? Theme.bgElevated : Theme.bgSurface, in: RoundedRectangle(cornerRadius: Theme.radiusSm))
            .opacity(item.selectable ? 1 : 0.75)
        }
        .buttonStyle(.plain)
        .disabled(locked || !item.selectable)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(item.selected ? .isSelected : [])
    }
}
