// AI provider registry - a port of electron/ai/providers.cjs. Everything provider-specific lives
// in a provider descriptor and its adapter; the default interface never names providers.
//
// Detection: a key shape only suggests ONE candidate provider; the key counts as belonging to it
// only after that provider's own test request succeeds. A key that suggests no provider - or
// several - is never guessed and never sent to several services: the user chooses the service in
// the advanced settings instead.
import Foundation

public enum ProviderID: String, CaseIterable, Sendable, Codable, Hashable {
    case anthropic
    case openai
    case gemini
    case openaiCompatible = "openai-compatible"
}

public struct ProviderDescriptor: Sendable {
    public let id: ProviderID
    public let label: String
    /// The default model id (nil: configured by the user).
    public let model: String?
    let keyHint: (@Sendable (String) -> Bool)?
    public let isApiKeyFormat: @Sendable (String) -> Bool

    public func makeAdapter(transport: HTTPTransport) -> ProviderAdapter {
        switch id {
        case .anthropic: return AnthropicAdapter(transport: transport)
        case .openai: return OpenAIAdapter(transport: transport)
        case .gemini: return GeminiAdapter(transport: transport)
        case .openaiCompatible: return OpenAICompatibleAdapter(transport: transport)
        }
    }
}

public enum Providers {
    static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    static let safeKey = "^[A-Za-z0-9._~+/=-]+$"
    static func lengthOk(_ key: String, _ min: Int, _ max: Int) -> Bool { key.count >= min && key.count <= max }

    public static let all: [ProviderDescriptor] = [
        ProviderDescriptor(
            id: .anthropic, label: "Anthropic Claude", model: "claude-opus-5-5",
            keyHint: { $0.hasPrefix("sk-ant-") },
            isApiKeyFormat: { matches("^sk-ant-[A-Za-z0-9_-]{20,250}$", $0) }
        ),
        ProviderDescriptor(
            id: .openai, label: "OpenAI GPT", model: "gpt-6-luna",
            // "sk-..." keys that are not Anthropic's.
            keyHint: { $0.hasPrefix("sk-") && !$0.hasPrefix("sk-ant-") },
            isApiKeyFormat: { matches(safeKey, $0) && lengthOk($0, 20, 300) }
        ),
        ProviderDescriptor(
            id: .gemini, label: "Google Gemini", model: "gemini-3.8-flash",
            // Classic Google API keys; newer key formats are not documented - choose Gemini explicitly.
            keyHint: { $0.hasPrefix("AIza") },
            isApiKeyFormat: { matches(safeKey, $0) && lengthOk($0, 20, 300) }
        ),
        ProviderDescriptor(
            id: .openaiCompatible, label: "OpenAI-compatible API", model: nil,
            keyHint: nil,
            isApiKeyFormat: { matches("^[\\x21-\\x7e]+$", $0) && lengthOk($0, 1, 512) }
        ),
    ]

    public static let defaultProvider = ProviderID.anthropic

    public static func get(_ id: ProviderID) -> ProviderDescriptor {
        all.first { $0.id == id }!
    }

    // API prices in USD per million tokens [input, output], only where read from the provider's
    // own documentation (OpenAI models page, 2026-10-24). Other models have no estimate.
    static let prices: [String: (Double, Double)] = [
        "gpt-6-luna": (0.1, 0.5),
        "gpt-6.1-sol": (2, 10),
        "gpt-6-astra": (10, 50),
    ]

    /// Estimated USD cost of one request, or nil when the model's price is not known.
    public static func estimateCost(model: String, usage: TokenUsage?) -> Double? {
        guard let price = prices[model], let usage else { return nil }
        return (Double(usage.inputTokens) * price.0 + Double(usage.outputTokens) * price.1) / 1_000_000
    }

    /// Suggests the provider of an API key (already trimmed) from its shape.
    public static func detect(_ key: String) -> Swift.Result<ProviderDescriptor, AICode> {
        if key.isEmpty { return .failure(.invalidKey) }
        let candidates = all.filter { $0.keyHint?(key) ?? false }
        if candidates.isEmpty { return .failure(.unidentifiedKey) }
        if candidates.count > 1 { return .failure(.ambiguousKey) }
        return candidates[0].isApiKeyFormat(key) ? .success(candidates[0]) : .failure(.invalidKey)
    }

    static let maxBaseUrlLength = 300
    static let localHosts: Set<String> = ["localhost", "127.0.0.1", "[::1]", "::1"]

    /// Base URL of an OpenAI-compatible API, normalized without a trailing slash, or nil. HTTPS only,
    /// except plain HTTP to this device (local servers). No credentials, query or fragment.
    public static func normalizeBaseUrl(_ value: String) -> String? {
        let trimmed = JSText.trim(value)
        guard !value.isEmpty, value.count <= maxBaseUrlLength, let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        let local = localHosts.contains(host)
        guard scheme == "https" || (scheme == "http" && local) else { return nil }
        guard components.user == nil, components.password == nil, components.query == nil, components.fragment == nil else { return nil }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        let hostText = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        let port = components.port.map { ":\($0)" } ?? ""
        let defaultPort = (scheme == "https" && components.port == 443) || (scheme == "http" && components.port == 80)
        return "\(scheme)://\(hostText)\(defaultPort ? "" : port)\(path)"
    }

    /// A model id for an OpenAI-compatible API (as listed by its /models), or nil.
    public static func normalizeModelId(_ value: String) -> String? {
        let model = JSText.trim(value)
        return matches("^[A-Za-z0-9._:/@+-]{1,200}$", model) ? model : nil
    }
}

public struct TokenUsage: Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
}

public struct PlanReply: Sendable {
    public var plan: JSONValue
    /// This provider's own history entries for the turn; stored opaquely, passed back unchanged.
    public var turn: [JSONValue]
    public var usage: TokenUsage?
}

public protocol ProviderAdapter: Sendable {
    var providerId: ProviderID { get }
    func testConnection(apiKey: String, model: String, baseUrl: String?) async -> Swift.Result<Void, AICode>
    func proposePlan(apiKey: String, model: String, baseUrl: String?, history: [JSONValue], userContent: String) async -> Swift.Result<PlanReply, AICode>
}
