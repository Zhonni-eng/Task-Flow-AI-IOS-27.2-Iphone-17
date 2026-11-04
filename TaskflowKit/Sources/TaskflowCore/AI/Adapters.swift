// Provider adapters - ports of electron/ai/providers/{anthropic,openai,gemini,openaiCompatible}.cjs.
// All provider-specific request building, response parsing and error mapping lives here; the app
// only sees app-level results. `turn` is the provider's own history entry pair, stored opaquely
// and passed back unchanged, so history is only ever appended to.
import Foundation

let requestTimeout: TimeInterval = 60
let testTimeout: TimeInterval = 15

// MARK: - Anthropic (Messages API, structured output)

struct AnthropicAdapter: ProviderAdapter {
    let transport: HTTPTransport
    let providerId = ProviderID.anthropic
    static let baseURL = "https://api.anthropic.com"
    static let maxOutputTokens = 16_000
    static let maxRetries = 2
    static let testRetries = 1

    func headers(_ apiKey: String) -> [String: String] {
        ["x-api-key": apiKey, "anthropic-version": "2023-06-01"]
    }

    /// Retries what the official SDK retries: connection errors, timeouts, 408, 409, 429 and 5xx.
    func withRetries(_ retries: Int, _ call: () async -> Swift.Result<JSONValue, AICode>) async -> Swift.Result<JSONValue, AICode> {
        var attempt = 0
        while true {
            let result = await call()
            guard case .failure(let code) = result, attempt < retries, [.network, .timeout, .rateLimit, .overloaded, .providerError].contains(code) else { return result }
            attempt += 1
            try? await Task.sleep(nanoseconds: UInt64(500_000_000 * Double(1 << (attempt - 1))))
        }
    }

    func testConnection(apiKey: String, model: String, baseUrl: String?) async -> Swift.Result<Void, AICode> {
        guard let url = HTTPJSON.url("\(Self.baseURL)/v1/models/\(HTTPJSON.pathComponent(model))") else { return .failure(.malformed) }
        let result = await withRetries(Self.testRetries) { await HTTPJSON.request(transport, url: url, headers: headers(apiKey), timeout: testTimeout) }
        switch result {
        case .failure(let code): return .failure(code)
        case .success(let info):
            // Anything but the model's own description is not a response this app understands.
            guard info["type"] == "model", info["id"]?.stringValue != nil else { return .failure(.malformed) }
            return .success(())
        }
    }

    func proposePlan(apiKey: String, model: String, baseUrl: String?, history: [JSONValue], userContent: String) async -> Swift.Result<PlanReply, AICode> {
        guard let url = HTTPJSON.url("\(Self.baseURL)/v1/messages") else { return .failure(.malformed) }
        let userMessage: JSONValue = ["role": "user", "content": .string(userContent)]
        let body: JSONValue = [
            "model": .string(model),
            "max_tokens": .number(Double(Self.maxOutputTokens)),
            // Stable instructions are cached; per-turn context lives in the messages.
            "system": [["type": "text", "text": .string(Prompt.systemPrompt), "cache_control": ["type": "ephemeral"]]],
            // History is passed back exactly as received (thinking blocks included).
            "messages": .array(history + [userMessage]),
            "output_config": ["effort": "low", "format": ["type": "json_schema", "schema": WirePlan.responseSchema]],
        ]
        let result = await withRetries(Self.maxRetries) {
            await HTTPJSON.request(transport, url: url, method: "POST", headers: headers(apiKey), body: body, timeout: requestTimeout)
        }
        guard case .success(let response) = result else {
            if case .failure(let code) = result { return .failure(code) }
            return .failure(.providerError)
        }
        guard let content = response["content"]?.arrayValue else { return .failure(.malformed) }
        if response["stop_reason"] == "refusal" { return .failure(.refused) }
        if response["stop_reason"] == "max_tokens" { return .failure(.truncated) }
        let text = content.filter { $0["type"] == "text" }.compactMap { $0["text"]?.stringValue }.joined()
        switch WirePlan.planFromText(text) {
        case .failure(let code): return .failure(code)
        case .success(let plan):
            var usage: TokenUsage?
            if let usageInfo = response["usage"], let input = usageInfo["input_tokens"]?.intValue, let output = usageInfo["output_tokens"]?.intValue {
                // Cached and newly cached input count as input.
                usage = TokenUsage(inputTokens: input + (usageInfo["cache_read_input_tokens"]?.intValue ?? 0) + (usageInfo["cache_creation_input_tokens"]?.intValue ?? 0), outputTokens: output)
            }
            return .success(PlanReply(plan: plan, turn: [userMessage, ["role": "assistant", "content": .array(content)]], usage: usage))
        }
    }
}

// MARK: - OpenAI (Responses API, strict JSON schema, store: false)

struct OpenAIAdapter: ProviderAdapter {
    let transport: HTTPTransport
    let providerId = ProviderID.openai
    static let baseURL = "https://api.openai.com/v1"
    // OpenAI recommends reserving at least 25,000 tokens for reasoning and output.
    static let maxOutputTokens = 25_000

    func headers(_ apiKey: String) -> [String: String] { ["authorization": "Bearer \(apiKey)"] }

    func testConnection(apiKey: String, model: String, baseUrl: String?) async -> Swift.Result<Void, AICode> {
        guard let url = HTTPJSON.url("\(Self.baseURL)/models/\(HTTPJSON.pathComponent(model))") else { return .failure(.malformed) }
        switch await HTTPJSON.request(transport, url: url, headers: headers(apiKey), timeout: testTimeout) {
        case .failure(let code): return .failure(code)
        case .success(let info):
            guard info["object"] == "model", info["id"]?.stringValue != nil else { return .failure(.malformed) }
            return .success(())
        }
    }

    func proposePlan(apiKey: String, model: String, baseUrl: String?, history: [JSONValue], userContent: String) async -> Swift.Result<PlanReply, AICode> {
        guard let url = HTTPJSON.url("\(Self.baseURL)/responses") else { return .failure(.malformed) }
        let userMessage: JSONValue = ["role": "user", "content": .string(userContent)]
        let body: JSONValue = [
            "model": .string(model),
            "instructions": .string(Prompt.systemPrompt),
            "input": .array(history + [userMessage]),
            "text": ["format": ["type": "json_schema", "name": "taskflow_plan", "schema": WirePlan.responseSchema, "strict": true]],
            "reasoning": ["effort": "low"],
            "max_output_tokens": .number(Double(Self.maxOutputTokens)),
            "store": false,
        ]
        let response: JSONValue
        switch await HTTPJSON.request(transport, url: url, method: "POST", headers: headers(apiKey), body: body, timeout: requestTimeout) {
        case .failure(let code): return .failure(code)
        case .success(let json): response = json
        }
        guard response.isPlainObject, let output = response["output"]?.arrayValue else { return .failure(.malformed) }
        if response["status"] == "incomplete" {
            let reason = response["incomplete_details"]?["reason"]
            return .failure(reason == "max_output_tokens" ? .truncated : reason == "content_filter" ? .refused : .malformed)
        }
        guard response["status"] == "completed" else { return .failure(.malformed) }
        let parts = output.filter { $0["type"] == "message" && $0["content"]?.arrayValue != nil }.flatMap { $0["content"]!.arrayValue! }
        if parts.contains(where: { $0["type"] == "refusal" }) { return .failure(.refused) }
        let text = parts.filter { $0["type"] == "output_text" }.compactMap { $0["text"]?.stringValue }.joined()
        switch WirePlan.planFromText(text) {
        case .failure(let code): return .failure(code)
        case .success(let plan):
            let usageInfo = response["usage"]
            let usage = usageInfo.flatMap { info in
                info["input_tokens"]?.intValue.flatMap { input in info["output_tokens"]?.intValue.map { TokenUsage(inputTokens: input, outputTokens: $0) } }
            }
            // Every output item (reasoning included) goes back unchanged in later turns.
            return .success(PlanReply(plan: plan, turn: [userMessage] + output, usage: usage))
        }
    }
}

// MARK: - Google Gemini (generateContent with a response schema)

struct GeminiAdapter: ProviderAdapter {
    let transport: HTTPTransport
    let providerId = ProviderID.gemini
    static let baseURL = "https://generativelanguage.googleapis.com/v1beta"
    static let maxOutputTokens = 32_768
    static let blockedFinish: Set<String> = ["SAFETY", "RECITATION", "BLOCKLIST", "PROHIBITED_CONTENT", "SPII", "LANGUAGE"]
    static let schema = WirePlan.geminiSchema(WirePlan.responseSchema)

    // The key goes in the x-goog-api-key header, never in the URL.
    func headers(_ apiKey: String) -> [String: String] { ["x-goog-api-key": apiKey] }
    func modelPath(_ model: String) -> String { "\(Self.baseURL)/models/\(HTTPJSON.pathComponent(model))" }

    func testConnection(apiKey: String, model: String, baseUrl: String?) async -> Swift.Result<Void, AICode> {
        guard let url = HTTPJSON.url(modelPath(model)) else { return .failure(.malformed) }
        switch await HTTPJSON.request(transport, url: url, headers: headers(apiKey), timeout: testTimeout) {
        case .failure(let code):
            // A GET without parameters can only be a bad request because of the key.
            return .failure(code == .badRequest ? .auth : code)
        case .success(let info):
            guard let name = info["name"]?.stringValue, name.hasPrefix("models/") else { return .failure(.malformed) }
            if let methods = info["supportedGenerationMethods"]?.arrayValue, !methods.contains("generateContent") { return .failure(.modelUnavailable) }
            return .success(())
        }
    }

    func proposePlan(apiKey: String, model: String, baseUrl: String?, history: [JSONValue], userContent: String) async -> Swift.Result<PlanReply, AICode> {
        guard let url = HTTPJSON.url("\(modelPath(model)):generateContent") else { return .failure(.malformed) }
        let userTurn: JSONValue = ["role": "user", "parts": [["text": .string(userContent)]]]
        let body: JSONValue = [
            "systemInstruction": ["parts": [["text": .string(Prompt.systemPrompt)]]],
            "contents": .array(history + [userTurn]),
            "generationConfig": ["responseMimeType": "application/json", "responseSchema": Self.schema, "maxOutputTokens": .number(Double(Self.maxOutputTokens))],
        ]
        let response: JSONValue
        switch await HTTPJSON.request(transport, url: url, method: "POST", headers: headers(apiKey), body: body, timeout: requestTimeout) {
        case .failure(let code): return .failure(code)
        case .success(let json): response = json
        }
        guard response.isPlainObject else { return .failure(.malformed) }
        if let reason = response["promptFeedback"]?["blockReason"], reason != .null, reason != "" { return .failure(.refused) }
        guard let candidate = response["candidates"]?.arrayValue?.first, candidate.isPlainObject else { return .failure(.malformed) }
        if candidate["finishReason"] == "MAX_TOKENS" { return .failure(.truncated) }
        if let finish = candidate["finishReason"]?.stringValue, Self.blockedFinish.contains(finish) { return .failure(.refused) }
        guard let parts = candidate["content"]?["parts"]?.arrayValue else { return .failure(.malformed) }
        // Thought parts are not part of the answer.
        let text = parts.filter { $0["thought"] != .bool(true) }.compactMap { $0["text"]?.stringValue }.joined()
        switch WirePlan.planFromText(text) {
        case .failure(let code): return .failure(code)
        case .success(let plan):
            var usage: TokenUsage?
            if let meta = response["usageMetadata"], let prompt = meta["promptTokenCount"]?.intValue {
                // Thinking tokens are billed as output.
                usage = TokenUsage(inputTokens: prompt, outputTokens: (meta["candidatesTokenCount"]?.intValue ?? 0) + (meta["thoughtsTokenCount"]?.intValue ?? 0))
            }
            return .success(PlanReply(plan: plan, turn: [userTurn, ["role": "model", "parts": .array(parts)]], usage: usage))
        }
    }
}

// MARK: - OpenAI-compatible services (advanced settings)

struct OpenAICompatibleAdapter: ProviderAdapter {
    let transport: HTTPTransport
    let providerId = ProviderID.openaiCompatible
    static let requestTimeout: TimeInterval = 120 // local models can be slow
    static let jsonInstruction = "\n\nAnswer with one JSON object only, with exactly these keys: \"reply\" (string), \"question\" (string), \"actions\" (array of action objects, each with every field of the action schema)."

    func headers(_ apiKey: String) -> [String: String] { ["authorization": "Bearer \(apiKey)"] }

    func testConnection(apiKey: String, model: String, baseUrl: String?) async -> Swift.Result<Void, AICode> {
        guard let baseUrl, let url = HTTPJSON.url("\(baseUrl)/models") else { return .failure(.invalidBaseUrl) }
        switch await HTTPJSON.request(transport, url: url, headers: headers(apiKey), timeout: testTimeout) {
        case .failure(let code): return .failure(code == .modelUnavailable ? .endpointNotFound : code)
        case .success(let json):
            guard let list = json["data"]?.arrayValue else { return .failure(.malformed) }
            guard list.contains(where: { $0["id"] == .string(model) }) else { return .failure(.modelUnavailable) }
            return .success(())
        }
    }

    func proposePlan(apiKey: String, model: String, baseUrl: String?, history: [JSONValue], userContent: String) async -> Swift.Result<PlanReply, AICode> {
        guard let baseUrl, let url = HTTPJSON.url("\(baseUrl)/chat/completions") else { return .failure(.invalidBaseUrl) }
        let userMessage: JSONValue = ["role": "user", "content": .string(userContent)]
        let body: JSONValue = [
            "model": .string(model),
            "messages": .array([["role": "system", "content": .string(Prompt.systemPrompt + Self.jsonInstruction)]] + history + [userMessage]),
            "response_format": ["type": "json_schema", "json_schema": ["name": "taskflow_plan", "schema": WirePlan.responseSchema, "strict": true]],
        ]
        let response: JSONValue
        switch await HTTPJSON.request(transport, url: url, method: "POST", headers: headers(apiKey), body: body, timeout: Self.requestTimeout) {
        case .failure(let code): return .failure(code)
        case .success(let json): response = json
        }
        guard let choice = response["choices"]?.arrayValue?.first, choice.isPlainObject, let message = choice["message"], message.isPlainObject else { return .failure(.malformed) }
        if choice["finish_reason"] == "length" { return .failure(.truncated) }
        if choice["finish_reason"] == "content_filter" || (message["refusal"]?.stringValue.map { !$0.isEmpty } ?? false) { return .failure(.refused) }
        let text = message["content"]?.stringValue
        switch WirePlan.planFromText(text) {
        case .failure(let code): return .failure(code)
        case .success(let plan):
            let reported = response["usage"]
            let usage = reported.flatMap { info in
                info["prompt_tokens"]?.intValue.flatMap { input in info["completion_tokens"]?.intValue.map { TokenUsage(inputTokens: input, outputTokens: $0) } }
            }
            return .success(PlanReply(plan: plan, turn: [userMessage, ["role": "assistant", "content": .string(text ?? "")]], usage: usage))
        }
    }
}
