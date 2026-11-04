// Voice input for the assistant: speech is recognized by iOS (on the device when the language model
// is available), the text is inserted into the message box after any text already there - exactly
// as if typed - and nothing is sent automatically. Recordings stop by themselves after 2 minutes;
// the microphone is released after each one. (The Windows app uses OpenAI transcription; on iPhone
// the system recognizer needs no key and sends no audio to a third party.)
import Foundation
import Observation
import TaskflowCore
#if canImport(Speech)
import AVFoundation
import Speech
#endif

@MainActor
@Observable
public final class SpeechInput {
    public enum Phase: Equatable { case idle, recording(started: Date), finishing }
    public private(set) var phase: Phase = .idle
    public private(set) var errorCode: String?
    /// Text recognized so far in the current recording.
    public private(set) var transcript = ""

    static let maxDuration: TimeInterval = 120

    #if canImport(Speech)
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let engine = AVAudioEngine()
    #endif
    private var stopTimer: Task<Void, Never>?
    private var onFinish: ((String) -> Void)?

    public init() {}

    public var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    public func toggle(language: Language, onFinish: @escaping (String) -> Void) {
        if isRecording { stop() } else { Task { await start(language: language, onFinish: onFinish) } }
    }

    public func start(language: Language, onFinish: @escaping (String) -> Void) async {
        errorCode = nil
        transcript = ""
        self.onFinish = onFinish
        #if canImport(Speech)
        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        guard speechStatus == .authorized else {
            errorCode = "MIC_DENIED"
            return
        }
        #if os(iOS)
        guard await AVAudioApplication.requestRecordPermission() else {
            errorCode = "MIC_DENIED"
            return
        }
        #endif
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: language == .en ? "en-US" : "ru-RU")), recognizer.isAvailable else {
            errorCode = "UNSUPPORTED"
            return
        }
        self.recognizer = recognizer
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        self.request = request
        do {
            #if os(iOS)
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            #endif
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0 else {
                errorCode = "NO_MIC"
                return
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
        } catch {
            errorCode = "MIC_BUSY"
            cleanUp()
            return
        }
        phase = .recording(started: Date())
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal ?? false
            Task { @MainActor in
                guard let self else { return }
                if let text { self.transcript = text }
                if final || error != nil { self.finish() }
            }
        }
        stopTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.maxDuration * 1_000_000_000))
            self?.stop()
        }
        #else
        errorCode = "UNSUPPORTED"
        #endif
    }

    public func stop() {
        guard isRecording else { return }
        phase = .finishing
        #if canImport(Speech)
        request?.endAudio()
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        #endif
        // The recognizer delivers the final result shortly after the audio ends.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            self?.finish()
        }
    }

    private func finish() {
        guard phase != .idle else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { errorCode = errorCode ?? "EMPTY_TRANSCRIPT" } else { onFinish?(text) }
        cleanUp()
    }

    private func cleanUp() {
        stopTimer?.cancel()
        stopTimer = nil
        #if canImport(Speech)
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        task?.cancel()
        task = nil
        request = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
        #endif
        onFinish = nil
        phase = .idle
    }
}
