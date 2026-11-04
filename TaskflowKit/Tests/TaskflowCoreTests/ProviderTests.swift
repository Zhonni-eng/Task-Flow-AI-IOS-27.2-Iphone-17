// Provider adapters, key detection, the connection and the chat service with simulated services -
// ports of tests/unit/{providerAdapters,anthropicAdapter,aiConnection,chatService}.test.js. No
// request ever leaves the machine.
import Foundation
import Testing
@testable import TaskflowCore

/// A simulated HTTP service: records requests and answers from a script.
final class FakeTransport: HTTPTransport, @unchecked Sendable {
    var responses: [Result<HTTPResponse, TransportError>]
    private(set) var requests: [HTTPRequest] = []
    private let lock = NSLock()

    init(_ responses: [Result<HTTPResponse, TransportError>]) {
        self.responses = responses
    }

    static func json(_ text: String, status: Int = 200) -> Result<HTTPResponse, TransportError> {
        .success(HTTPResponse(status: status, body: Data(text.utf8)))
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let next: Result<HTTPResponse, TransportError> = lock.withLock {
            requests.append(request)
            return responses.isEmpty ? .failure(.network) : responses.removeFirst()
        }
        return try next.get()
    }

    var bodies: [JSONValue] { requests.compactMap { $0.body.flatMap { try? JSONValue.parse($0) } } }
}

final class MemorySecrets: SecretStore, @unchecked Sendable {
    var items: [String: String] = [:]
    var isAvailable = true
    func read(account: String) throws -> String? { items[account] }
    func write(account: String, value: String) throws { items[account] = value }
    func delete(account: String) { items[account] = nil }
}

let validPlanText = #"{"reply":"Готово","question":"","actions":[{"type":"create","taskId":"","subtaskId":"","toTaskId":"","title":"Купить молоко","newTitle":"","description":"","status":"unset","priority":"unset","dueDate":"2026-10-26","dueTime":"","categoryId":"","newCategory":"","subtasks":[],"labels":[],"removeLabels":[],"label":"","newLabel":"","reminders":[],"recurrence":{"freq":"unset","interval":0,"weekdays":[],"monthDay":0},"estimateMinutes":0,"done":"unset","clear":[],"filter":{"status":"unset","categoryId":"","priority":"unset","due":"unset","completedOlderThanDays":0,"titleContains":"","scope":"unset"},"operation":"unset","date":"","items":[]}]}"#

func quoted(_ text: String) -> String { JSONValue.string(text).serializedString() }

@Suite("Wire format")
struct WirePlanTests {
    @Test func strictActionBecomesPlan() throws {
        let plan = try WirePlan.planFromText(validPlanText).get()
        #expect(plan["actions"] == json(#"[{"type":"create","title":"Купить молоко","dueDate":"2026-10-26"}]"#))
        let validation = ActionPlan.validate(plan, context: ValidationContext(tasks: [], categories: [], now: local(2026, 10, 25), timeZone: berlin))
        #expect(validation.ok)
    }

    @Test func renameOnlyWithNewTitle() throws {
        let raw = #"{"reply":"","question":"","actions":[{"type":"update","taskId":"t1","title":"Old title","newTitle":"","status":"done","clear":["dueTime"],"labels":["a"],"removeLabels":[],"recurrence":{"freq":"unset","interval":0,"weekdays":[],"monthDay":0},"estimateMinutes":0,"reminders":[]}]}"#
        let plan = try WirePlan.planFromText(raw).get()
        #expect(plan["actions"]?.arrayValue?[0] == json(#"{"type":"update","taskId":"t1","changes":{"status":"done","dueTime":null,"addLabels":["a"]}}"#))
    }

    @Test func bulkFilterAndSubtaskDone() throws {
        let raw = #"{"reply":"","question":"","actions":[{"type":"bulk","operation":"delete","filter":{"status":"done","categoryId":"","priority":"unset","due":"unset","completedOlderThanDays":30,"titleContains":"","scope":"unset"}},{"type":"updateSubtask","taskId":"t","subtaskId":"s","newTitle":"","done":"true"}]}"#
        let actions = try WirePlan.planFromText(raw).get()["actions"]!.arrayValue!
        #expect(actions[0] == json(#"{"type":"bulk","operation":"delete","filter":{"status":"done","completedOlderThanDays":30},"changes":{}}"#))
        #expect(actions[1] == json(#"{"type":"updateSubtask","taskId":"t","subtaskId":"s","done":true}"#))
    }

    @Test func rejectsMalformed() {
        #expect(throws: AICode.malformed) { try WirePlan.planFromText("not json").get() }
        #expect(throws: AICode.malformed) { try WirePlan.planFromText(#"{"reply":1,"question":"","actions":[]}"#).get() }
        #expect(throws: AICode.malformed) { try WirePlan.planFromText(#"{"reply":"","question":"","actions":[{"type":"hack"}]}"#).get() }
        #expect(throws: AICode.malformed) { try WirePlan.planFromText("").get() }
    }

    @Test func emptyActionsBecomeNone() throws {
        #expect(try WirePlan.planFromText(#"{"reply":"Просрочено 2","question":"","actions":[]}"#).get()["actions"] == json(#"[{"type":"none"}]"#))
    }

    @Test func legacyFormat() throws {
        let plan = try WirePlan.planFromText(#"{"reply":"","question":"","tasks":[{"title":"A","dueDate":""}],"statusChanges":[{"taskId":"t","status":"done"}]}"#).get()
        #expect(plan["actions"] == json(#"[{"type":"create","title":"A"},{"type":"update","taskId":"t","changes":{"status":"done"}}]"#))
    }

    @Test func statusCodes() {
        #expect(WirePlan.code(forStatus: 401) == .auth)
        #expect(WirePlan.code(forStatus: 403) == .permission)
        #expect(WirePlan.code(forStatus: 404) == .modelUnavailable)
        #expect(WirePlan.code(forStatus: 429) == .rateLimit)
        #expect(WirePlan.code(forStatus: 529) == .overloaded)
        #expect(WirePlan.code(forStatus: 500) == .providerError)
        #expect(WirePlan.code(forStatus: 422) == .badRequest)
    }

    @Test func schemaIsStrict() {
        let schema = WirePlan.responseSchema
        #expect(schema["additionalProperties"] == false)
        #expect(schema["required"] == .from(["reply", "question", "actions"]))
        let action = schema["properties"]!["actions"]!["items"]!
        #expect(action["required"]?.arrayValue?.count == action["properties"]?.objectValue?.count)
        let gemini = WirePlan.geminiSchema(schema)
        #expect(gemini["type"] == "OBJECT")
        #expect(gemini["additionalProperties"] == nil)
        #expect(gemini["propertyOrdering"] == .from(["reply", "question", "actions"]))
    }
}

@Suite("Providers and keys")
struct ProviderRegistryTests {
    @Test func detection() throws {
        #expect(try Providers.detect("sk-ant-" + String(repeating: "a", count: 40)).get().id == .anthropic)
        #expect(try Providers.detect("sk-proj-" + String(repeating: "b", count: 40)).get().id == .openai)
        #expect(try Providers.detect("AIza" + String(repeating: "c", count: 35)).get().id == .gemini)
        #expect(throws: AICode.unidentifiedKey) { try Providers.detect("xyz-123456789012345678901").get() }
        #expect(throws: AICode.invalidKey) { try Providers.detect("sk-ant-short").get() }
        #expect(throws: AICode.invalidKey) { try Providers.detect("").get() }
    }

    @Test func baseUrls() {
        #expect(Providers.normalizeBaseUrl("https://api.example.com/v1/") == "https://api.example.com/v1")
        #expect(Providers.normalizeBaseUrl("http://localhost:11434/v1") == "http://localhost:11434/v1")
        #expect(Providers.normalizeBaseUrl("http://example.com/v1") == nil)
        #expect(Providers.normalizeBaseUrl("https://user:pass@example.com/v1") == nil)
        #expect(Providers.normalizeBaseUrl("https://example.com/v1?x=1") == nil)
        #expect(Providers.normalizeBaseUrl("ftp://example.com") == nil)
        #expect(Providers.normalizeModelId(" llama3.1:8b ") == "llama3.1:8b")
        #expect(Providers.normalizeModelId("bad model") == nil)
    }

    @Test func costs() {
        #expect(Providers.estimateCost(model: "gpt-6-luna", usage: TokenUsage(inputTokens: 1_000_000, outputTokens: 1_000_000)) == 0.6)
        #expect(Providers.estimateCost(model: "claude-opus-5-5", usage: TokenUsage(inputTokens: 1, outputTokens: 1)) == nil)
    }
}

@Suite("Adapters")
struct AdapterTests {
    @Test func anthropicRequestAndReply() async throws {
        let reply = #"{"type":"message","stop_reason":"end_turn","content":[{"type":"text","text":\#(quoted(validPlanText))}],"usage":{"input_tokens":100,"output_tokens":20,"cache_read_input_tokens":50}}"#
        let transport = FakeTransport([FakeTransport.json(reply)])
        let result = await AnthropicAdapter(transport: transport).proposePlan(apiKey: "sk-ant-key", model: "claude-opus-5-5", baseUrl: nil, history: [], userContent: "hi")
        let plan = try result.get()
        #expect(plan.usage == TokenUsage(inputTokens: 150, outputTokens: 20))
        #expect(plan.turn.count == 2)
        let request = transport.requests[0]
        #expect(request.url.absoluteString == "https://api.anthropic.com/v1/messages")
        #expect(request.headers["x-api-key"] == "sk-ant-key")
        #expect(request.headers["anthropic-version"] == "2023-06-01")
        let body = transport.bodies[0]
        #expect(body["model"] == "claude-opus-5-5")
        #expect(body["output_config"]?["format"]?["type"] == "json_schema")
        #expect(body["system"]?.arrayValue?[0]["cache_control"] == json(#"{"type":"ephemeral"}"#))
        #expect(body["messages"] == json(#"[{"role":"user","content":"hi"}]"#))
    }

    @Test func anthropicStopReasonsAndRetries() async {
        let refused = FakeTransport([FakeTransport.json(#"{"content":[],"stop_reason":"refusal"}"#)])
        #expect(await code(AnthropicAdapter(transport: refused).proposePlan(apiKey: "k", model: "m", baseUrl: nil, history: [], userContent: "x")) == .refused)
        let truncated = FakeTransport([FakeTransport.json(#"{"content":[],"stop_reason":"max_tokens"}"#)])
        #expect(await code(AnthropicAdapter(transport: truncated).proposePlan(apiKey: "k", model: "m", baseUrl: nil, history: [], userContent: "x")) == .truncated)
        let auth = FakeTransport([FakeTransport.json(#"{"error":{"message":"sk-ant-secret is invalid"}}"#, status: 401)])
        #expect(await code(AnthropicAdapter(transport: auth).proposePlan(apiKey: "k", model: "m", baseUrl: nil, history: [], userContent: "x")) == .auth)
        #expect(auth.requests.count == 1) // 401 is not retried
        let flaky = FakeTransport([.failure(.network), FakeTransport.json(#"{"type":"model","id":"m"}"#)])
        #expect(await succeeded(AnthropicAdapter(transport: flaky).testConnection(apiKey: "k", model: "m", baseUrl: nil)))
    }

    @Test func redirectsAreNotFollowed() async {
        let transport = FakeTransport([.success(HTTPResponse(status: 302, body: Data()))])
        #expect(await code(OpenAIAdapter(transport: transport).testConnection(apiKey: "k", model: "m", baseUrl: nil)) == .providerError)
    }

    @Test func openAI() async throws {
        let reply = #"{"status":"completed","output":[{"type":"reasoning","id":"r1"},{"type":"message","content":[{"type":"output_text","text":\#(quoted(validPlanText))}]}],"usage":{"input_tokens":7,"output_tokens":3}}"#
        let transport = FakeTransport([FakeTransport.json(reply)])
        let result = try await OpenAIAdapter(transport: transport).proposePlan(apiKey: "sk-x", model: "gpt-6-luna", baseUrl: nil, history: [], userContent: "hi").get()
        #expect(result.turn.count == 3) // user + every output item, reasoning included
        #expect(transport.requests[0].headers["authorization"] == "Bearer sk-x")
        #expect(transport.bodies[0]["store"] == false)
        #expect(transport.bodies[0]["text"]?["format"]?["strict"] == true)
        let incomplete = FakeTransport([FakeTransport.json(#"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[]}"#)])
        #expect(await code(OpenAIAdapter(transport: incomplete).proposePlan(apiKey: "k", model: "m", baseUrl: nil, history: [], userContent: "x")) == .truncated)
    }

    @Test func gemini() async throws {
        let reply = #"{"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"thinking","thought":true},{"text":\#(quoted(validPlanText))}]}}],"usageMetadata":{"promptTokenCount":5,"candidatesTokenCount":2,"thoughtsTokenCount":3}}"#
        let transport = FakeTransport([FakeTransport.json(reply)])
        let result = try await GeminiAdapter(transport: transport).proposePlan(apiKey: "AIza-key", model: "gemini-3.8-flash", baseUrl: nil, history: [], userContent: "hi").get()
        #expect(result.usage == TokenUsage(inputTokens: 5, outputTokens: 5))
        let request = transport.requests[0]
        #expect(request.headers["x-goog-api-key"] == "AIza-key")
        #expect(!request.url.absoluteString.contains("AIza-key"))
        #expect(request.url.absoluteString.hasSuffix("/models/gemini-3.8-flash:generateContent"))
        let badKey = FakeTransport([FakeTransport.json("{}", status: 400)])
        #expect(await code(GeminiAdapter(transport: badKey).testConnection(apiKey: "k", model: "m", baseUrl: nil)) == .auth)
    }

    @Test func compatible() async throws {
        let models = FakeTransport([FakeTransport.json(#"{"data":[{"id":"llama"}]}"#)])
        #expect(await succeeded(OpenAICompatibleAdapter(transport: models).testConnection(apiKey: "k", model: "llama", baseUrl: "http://localhost:11434/v1")))
        let missing = FakeTransport([FakeTransport.json(#"{"data":[{"id":"other"}]}"#)])
        #expect(await code(OpenAICompatibleAdapter(transport: missing).testConnection(apiKey: "k", model: "llama", baseUrl: "http://localhost:11434/v1")) == .modelUnavailable)
        let notFound = FakeTransport([FakeTransport.json("{}", status: 404)])
        #expect(await code(OpenAICompatibleAdapter(transport: notFound).testConnection(apiKey: "k", model: "llama", baseUrl: "https://x.example/v1")) == .endpointNotFound)
        let chat = FakeTransport([FakeTransport.json(#"{"choices":[{"finish_reason":"stop","message":{"content":\#(quoted(validPlanText))}}]}"#)])
        _ = try await OpenAICompatibleAdapter(transport: chat).proposePlan(apiKey: "k", model: "llama", baseUrl: "http://localhost:11434/v1", history: [], userContent: "hi").get()
        #expect(chat.requests[0].url.absoluteString == "http://localhost:11434/v1/chat/completions")
    }
}

func code<T>(_ result: Result<T, AICode>) -> AICode? {
    if case .failure(let code) = result { return code }
    return nil
}

func succeeded<T>(_ result: Result<T, AICode>) -> Bool {
    if case .success = result { return true }
    return false
}

@Suite("Connection, settings and chat")
struct ConnectionTests {
    let anthropicKey = "sk-ant-" + String(repeating: "k", count: 40)

    @Test func keyIsStoredOnlyAfterSuccessfulTest() async {
        let secrets = MemorySecrets()
        let settings = AISettings(directory: tempDirectory(), secrets: secrets)
        let failing = AIConnection(settings: settings, transport: FakeTransport([FakeTransport.json("{}", status: 401)]))
        #expect(await code(failing.connect(ConnectRequest(key: anthropicKey))) == .auth)
        #expect(secrets.items.isEmpty)
        #expect(!settings.publicState().enabled)

        let working = AIConnection(settings: settings, transport: FakeTransport([FakeTransport.json(#"{"type":"model","id":"claude-opus-5-5"}"#)]))
        #expect(await succeeded(working.connect(ConnectRequest(key: "  \(anthropicKey)  "))))
        #expect(secrets.items.values.contains(anthropicKey))
        let state = settings.publicState()
        #expect(state.enabled && state.key == .stored && state.verifiedAt != nil && state.provider == .anthropic)
        #expect(await working.status() == .connected)
    }

    @Test func failedReconnectKeepsPreviousKey() async {
        let secrets = MemorySecrets()
        let settings = AISettings(directory: tempDirectory(), secrets: secrets)
        _ = await AIConnection(settings: settings, transport: FakeTransport([FakeTransport.json(#"{"type":"model","id":"m"}"#)])).connect(ConnectRequest(key: anthropicKey))
        let other = "sk-ant-" + String(repeating: "z", count: 40)
        _ = await AIConnection(settings: settings, transport: FakeTransport([FakeTransport.json("{}", status: 401)])).connect(ConnectRequest(key: other))
        #expect(settings.apiKey() == anthropicKey)
    }

    @Test func unrecognizedKeyIsNeverSent() async {
        let transport = FakeTransport([])
        let connection = AIConnection(settings: AISettings(directory: tempDirectory(), secrets: MemorySecrets()), transport: transport)
        #expect(await code(connection.connect(ConnectRequest(key: "mystery-key-1234567890"))) == .unidentifiedKey)
        #expect(transport.requests.isEmpty)
    }

    @Test func secureStorageRequired() async {
        let secrets = MemorySecrets()
        secrets.isAvailable = false
        let transport = FakeTransport([])
        let connection = AIConnection(settings: AISettings(directory: tempDirectory(), secrets: secrets), transport: transport)
        #expect(await code(connection.connect(ConnectRequest(key: anthropicKey))) == .secureStorageUnavailable)
        #expect(transport.requests.isEmpty)
    }

    @Test func settingsFileNeverContainsTheKey() async throws {
        let dir = tempDirectory()
        let settings = AISettings(directory: dir, secrets: MemorySecrets())
        _ = await AIConnection(settings: settings, transport: FakeTransport([FakeTransport.json(#"{"type":"model","id":"m"}"#)])).connect(ConnectRequest(key: anthropicKey))
        let text = try String(contentsOf: dir.appendingPathComponent(AISettings.fileName), encoding: .utf8)
        #expect(!text.contains(anthropicKey))
        #expect(text.contains("\"enabled\" : true"))
    }

    @Test func disconnectRemovesEverything() async {
        let secrets = MemorySecrets()
        let settings = AISettings(directory: tempDirectory(), secrets: secrets)
        let connection = AIConnection(settings: settings, transport: FakeTransport([FakeTransport.json(#"{"type":"model","id":"m"}"#)]))
        _ = await connection.connect(ConnectRequest(key: anthropicKey))
        #expect(await succeeded(connection.disconnect()))
        #expect(secrets.items.isEmpty)
        #expect(await connection.status() == .none)
        guard case .failure(.notConnected) = settings.setEnabled(true) else {
            Issue.record("enabling without a key must fail")
            return
        }
    }

    @Test func compatibleConfiguration() async {
        let settings = AISettings(directory: tempDirectory(), secrets: MemorySecrets())
        let connection = AIConnection(settings: settings, transport: FakeTransport([FakeTransport.json(#"{"data":[{"id":"llama"}]}"#)]))
        #expect(await code(connection.connect(ConnectRequest(key: "local", provider: .openaiCompatible, baseUrl: "http://example.com", model: "llama"))) == .invalidBaseUrl)
        #expect(await succeeded(connection.connect(ConnectRequest(key: "local", provider: .openaiCompatible, baseUrl: "http://localhost:11434/v1/", model: "llama"))))
        #expect(settings.target() == ConnectionTarget(providerId: .openaiCompatible, model: "llama", baseUrl: "http://localhost:11434/v1"))
    }

    @Test func chatFlow() async throws {
        let secrets = MemorySecrets()
        let settings = AISettings(directory: tempDirectory(), secrets: secrets)
        _ = await AIConnection(settings: settings, transport: FakeTransport([FakeTransport.json(#"{"type":"model","id":"m"}"#)])).connect(ConnectRequest(key: anthropicKey))
        let reply = #"{"content":[{"type":"text","text":\#(quoted(validPlanText))}],"stop_reason":"end_turn"}"#
        let transport = FakeTransport([FakeTransport.json(reply), FakeTransport.json(reply)])
        let chat = ChatService(settings: settings, transport: transport, now: { local(2026, 10, 25, 12) }, timeZone: { berlin })
        let tasks = [makeTask(id: "milk", title: "Купить молоко", description: "secret")]
        let snapshot = ChatSnapshot(tasks: tasks, categories: [], availability: nil)
        let first = try await chat.send("купить молоко завтра", language: .ru, snapshot: snapshot).get()
        #expect(first.sharedTaskIds == ["milk"])
        _ = try await chat.send("и хлеб", language: .ru, snapshot: snapshot).get()
        // The second request replays the first turn (append-only history) and keeps the shared task pinned.
        let messages = transport.bodies[1]["messages"]!.arrayValue!
        #expect(messages.count == 3)
        #expect(messages[2]["content"]?.stringValue?.contains("id: milk") == true)
        #expect(!(messages[2]["content"]?.stringValue?.contains("secret") ?? true))
        #expect(await chat.turnCount() == 2)
        await chat.reset()
        #expect(await chat.turnCount() == 0)
    }

    @Test func chatRefusesWhenOff() async {
        let chat = ChatService(settings: AISettings(directory: tempDirectory(), secrets: MemorySecrets()), transport: FakeTransport([]))
        let snapshot = ChatSnapshot(tasks: [], categories: [], availability: nil)
        #expect(await code(chat.send("x", language: .ru, snapshot: snapshot)) == .aiDisabled)
        #expect(await code(chat.send("   ", language: .ru, snapshot: snapshot)) == .invalidMessage)
        #expect(await code(chat.send(String(repeating: "x", count: 2001), language: .ru, snapshot: snapshot)) == .invalidMessage)
    }
}
