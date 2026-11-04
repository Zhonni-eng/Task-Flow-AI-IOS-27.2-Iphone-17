// AI settings and API keys - a port of electron/ai/aiSettings.cjs. The non-secret settings live in
// their own small JSON file (separate from the task data):
//
//   taskflow-ai.json = { version: 1, enabled, provider, verifiedAt, compatible: { baseUrl, model } | null,
//                        models: { '<provider id>': '<model id>' } }
//
// API keys are stored only in the iOS Keychain (one item per provider, this device only, after
// the device was unlocked once) - never in the settings file, task data, logs or source code. A key
// is stored only after it passed a connection test, and AI can only be enabled with such a key.
// Keys never leave this module except through apiKey() for provider calls.
import Foundation

/// Secure storage for secrets (the Keychain on iOS; an in-memory fake in tests).
public protocol SecretStore: Sendable {
    var isAvailable: Bool { get }
    /// nil when there is no item; throws when an item exists but cannot be read.
    func read(account: String) throws -> String?
    func write(account: String, value: String) throws
    func delete(account: String)
}

public enum KeyState: String, Sendable { case none, stored, unreadable }

public struct AIPublicState: Equatable, Sendable {
    public var enabled: Bool
    public var key: KeyState
    public var verifiedAt: String?
    public var secureStorageAvailable: Bool
    public var writable: Bool
    /// For the advanced settings only: the service of the stored key (an id, never a key).
    public var provider: ProviderID?
    public var model: String?
    public var compatible: CompatibleConfig?
}

public struct CompatibleConfig: Equatable, Sendable, Codable {
    public var baseUrl: String
    public var model: String
}

public struct ConnectionTarget: Equatable, Sendable {
    public var providerId: ProviderID
    public var model: String?
    public var baseUrl: String?
}

public final class AISettings: @unchecked Sendable {
    public static let fileName = "taskflow-ai.json"
    static let version = 1
    public static let maxKeyLength = 1024
    static let keychainPrefix = "ai-key."

    struct Stored: Equatable {
        var enabled = false
        var provider = Providers.defaultProvider
        var verifiedAt: String?
        var compatible: CompatibleConfig?
        var models: [String: String] = [:]

        var json: JSONValue {
            [
                "version": .number(Double(AISettings.version)),
                "enabled": .bool(enabled),
                "provider": .string(provider.rawValue),
                "verifiedAt": .from(verifiedAt),
                "compatible": compatible.map { ["baseUrl": .string($0.baseUrl), "model": .string($0.model)] } ?? .null,
                "models": .object(models.mapValues(JSONValue.string)),
            ]
        }
    }

    private let file: URL
    private let secrets: SecretStore
    private let lock = NSLock()
    private var settings = Stored()
    private var loaded = false
    private(set) public var writable = true

    public init(directory: URL, secrets: SecretStore) {
        self.file = directory.appendingPathComponent(Self.fileName)
        self.secrets = secrets
    }

    private func account(_ provider: ProviderID) -> String { Self.keychainPrefix + provider.rawValue }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: file) else { return }
        guard let raw = try? JSONValue.parse(data), raw.isPlainObject else { return }
        if let version = raw["version"]?.intValue, version > Self.version {
            // Written by a newer Taskflow: use defaults and never overwrite it.
            writable = false
            return
        }
        var stored = Stored()
        stored.enabled = raw["enabled"]?.boolValue ?? false
        stored.provider = raw["provider"]?.stringValue.flatMap(ProviderID.init(rawValue:)) ?? Providers.defaultProvider
        stored.verifiedAt = raw["verifiedAt"]?.stringValue
        if let compatible = raw["compatible"], let baseUrl = compatible["baseUrl"]?.stringValue.flatMap(Providers.normalizeBaseUrl),
           let model = compatible["model"]?.stringValue.flatMap(Providers.normalizeModelId) {
            stored.compatible = CompatibleConfig(baseUrl: baseUrl, model: model)
        }
        for (provider, model) in raw["models"]?.objectValue ?? [:] {
            if ProviderID(rawValue: provider) != nil, let id = model.stringValue.flatMap(Providers.normalizeModelId) { stored.models[provider] = id }
        }
        // The OpenAI-compatible provider cannot be active without its configuration.
        if stored.provider == .openaiCompatible && stored.compatible == nil { stored.provider = Providers.defaultProvider }
        settings = stored
        // AI can only stay enabled with a usable key that passed a connection test.
        if settings.enabled && !(keyState() == .stored && settings.verifiedAt != nil) { settings.enabled = false }
    }

    private func commit(_ next: Stored) -> Swift.Result<Void, AICode> {
        guard writable else { return .failure(.providerError) }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try next.json.serialized(pretty: true).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            settings = next
            return .success(())
        } catch {
            return .failure(.providerError)
        }
    }

    func keyState(_ provider: ProviderID? = nil) -> KeyState {
        let id = provider ?? settings.provider
        guard secrets.isAvailable else { return .unreadable }
        do {
            guard let key = try secrets.read(account: account(id)) else { return .none }
            return key.isEmpty ? .unreadable : .stored
        } catch {
            return .unreadable
        }
    }

    /// Everything the interface may know. Never contains a key or any part of one.
    public func publicState() -> AIPublicState {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        let key = keyState()
        return AIPublicState(
            enabled: settings.enabled,
            key: key,
            verifiedAt: key == .none ? nil : settings.verifiedAt,
            secureStorageAvailable: secrets.isAvailable,
            writable: writable,
            provider: key == .none ? nil : settings.provider,
            model: key == .none ? nil : targetLocked().model,
            compatible: settings.compatible
        )
    }

    /// Switches the assistant on or off (on only with a verified key).
    public func setEnabled(_ enabled: Bool) -> Swift.Result<Void, AIError> {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        var next = settings
        next.enabled = enabled
        if enabled && !(keyState() == .stored && settings.verifiedAt != nil) { return .failure(.notConnected) }
        return commit(next).mapError { _ in .saveFailed }
    }

    public enum AIError: Error, Equatable { case notConnected, saveFailed }

    /// Whether a new key could be stored at all - checked before any connection test is made.
    public func canStoreKey() -> Swift.Result<Void, AICode> {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        if !writable { return .failure(.providerError) }
        if !secrets.isAvailable { return .failure(.secureStorageUnavailable) }
        return .success(())
    }

    /// Stores a key that just passed a connection test, replacing any previous key of that service,
    /// and switches AI on. On any failure the previous key and settings stay as they were.
    public func storeVerifiedKey(_ providerId: ProviderID, key rawKey: String, verifiedAt: String, target: ConnectionTarget) -> Swift.Result<Void, AICode> {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        let provider = Providers.get(providerId)
        var compatible = settings.compatible
        var models = settings.models
        if provider.id != .openaiCompatible {
            // A model other than the provider's default is remembered (it passed the connection test).
            let model = target.model.flatMap(Providers.normalizeModelId)
            if target.model != nil && model == nil { return .failure(.invalidModel) }
            if let model, model != provider.model { models[provider.id.rawValue] = model } else { models[provider.id.rawValue] = nil }
        } else {
            guard let baseUrl = target.baseUrl.flatMap(Providers.normalizeBaseUrl) else { return .failure(.invalidBaseUrl) }
            guard let model = target.model.flatMap(Providers.normalizeModelId) else { return .failure(.invalidModel) }
            compatible = CompatibleConfig(baseUrl: baseUrl, model: model)
        }
        guard rawKey.count <= Self.maxKeyLength else { return .failure(.invalidKey) }
        let key = JSText.trim(rawKey)
        guard !key.isEmpty, provider.isApiKeyFormat(key) else { return .failure(.invalidKey) }
        guard writable else { return .failure(.providerError) }
        guard secrets.isAvailable else { return .failure(.secureStorageUnavailable) }
        let previous = try? secrets.read(account: account(provider.id))
        do {
            try secrets.write(account: account(provider.id), value: key)
            // Never keep something that cannot be read back.
            guard try secrets.read(account: account(provider.id)) == key else { throw AICode.encryptionFailed }
        } catch {
            restore(previous ?? nil, provider: provider.id)
            return .failure(.encryptionFailed)
        }
        var next = settings
        next.enabled = true
        next.provider = provider.id
        next.verifiedAt = verifiedAt
        next.compatible = compatible
        next.models = models
        let result = commit(next)
        if case .failure = result { restore(previous ?? nil, provider: provider.id) }
        return result
    }

    private func restore(_ previous: String?, provider: ProviderID) {
        if let previous { try? secrets.write(account: account(provider), value: previous) } else { secrets.delete(account: account(provider)) }
    }

    /// Records that the stored key passed a connection test again.
    public func markVerified(_ verifiedAt: String) -> Swift.Result<Void, AICode> {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        guard keyState() == .stored else { return .failure(.noKey) }
        var next = settings
        next.verifiedAt = verifiedAt
        return commit(next)
    }

    /// Removes every stored key and the OpenAI-compatible configuration; AI is switched off.
    public func clearApiKeys() -> Swift.Result<Void, AICode> {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        for provider in ProviderID.allCases { secrets.delete(account: account(provider)) }
        return commit(Stored())
    }

    private func targetLocked() -> ConnectionTarget {
        let provider = Providers.get(settings.provider)
        if provider.id == .openaiCompatible {
            return ConnectionTarget(providerId: provider.id, model: settings.compatible?.model, baseUrl: settings.compatible?.baseUrl)
        }
        return ConnectionTarget(providerId: provider.id, model: settings.models[provider.id.rawValue] ?? provider.model, baseUrl: nil)
    }

    /// Where requests of the active connection go.
    public func target() -> ConnectionTarget {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        return targetLocked()
    }

    /// The stored key of the active connection, for provider calls only.
    public func apiKey() -> String? {
        lock.lock()
        defer { lock.unlock() }
        loadIfNeeded()
        guard secrets.isAvailable, let key = try? secrets.read(account: account(settings.provider)), !key.isEmpty else { return nil }
        return key
    }
}
