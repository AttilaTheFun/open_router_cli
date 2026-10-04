// What a completion cost, and what the key and the account have left: the
// usage OpenRouter reports at the end of a stream (asked for in every
// request), and its key and credits endpoints.

import Foundation
import Testing
@testable import OpenRouterKit
import TestSupport

@Test func aCompletionsUsageCarriesItsCostAndCachedTokens() async throws {
    let mock = MockTransport(streams: [[
        try sse(["choices": [["delta": ["content": "Hi"], "finish_reason": "stop"]]]),
        try sse(["choices": [[String: Any]](), "usage": ["prompt_tokens": 100, "completion_tokens": 5, "cost": 0.002,
                                                         "prompt_tokens_details": ["cached_tokens": 80]]]),
        "data: [DONE]",
    ]])
    let recorder = Recorder<ORStreamEvent>()
    _ = try await OpenRouterClient(apiKey: "k", transport: mock).complete(ORChatRequest(model: "m", messages: [])) { await recorder.add($0) }
    let usage = await recorder.events.compactMap { event -> ORUsage? in
        if case .usage(let usage) = event { return usage }
        return nil
    }
    #expect(usage == [ORUsage(prompt: 100, cached: 80, completion: 5, cost: 0.002)])
    // Every request asks for it.
    let sent = try #require(await mock.sentBodies.first)
    let body = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
    #expect(body["usage"] as? [String: Bool] == ["include": true])
}

@Test func theKeyAndTheCreditsAreRead() async throws {
    let mock = MockTransport(answers: [
        "/api/v1/key": (200, #"{"data":{"limit":null,"limit_remaining":null,"limit_reset":null,"usage":1.12,"is_free_tier":false,"label":"x"}}"#),
        "/api/v1/credits": (200, #"{"data":{"total_credits":10,"total_usage":1.12}}"#),
    ])
    let client = OpenRouterClient(apiKey: "k", transport: mock)
    #expect(try await client.keyStatus() == ORKeyStatus(usage: 1.12))
    #expect(try await client.credits() == ORCredits(totalCredits: 10, totalUsage: 1.12))
    let refused = OpenRouterClient(apiKey: "k", transport: MockTransport(answers: ["/api/v1/credits": (403, "no")]))
    await #expect(throws: OpenRouterError(status: 403, body: "no")) { _ = try await refused.credits() }
}

@Test func theLinesSayWhatWasUsedAndWhatIsLeft() throws {
    let result = try #require(try JSONSerialization.jsonObject(with: Data(StreamJSON.result(
        .success, text: "ok", sessionID: "s",
        spent: ["a": ORUsage(prompt: 10, cached: 4, completion: 2, cost: 0.5), "b": ORUsage(prompt: 3, completion: 1)]).utf8)) as? [String: Any])
    #expect(result["total_cost_usd"] as? Double == 0.5)
    let models = try #require(result["modelUsage"] as? [String: [String: Double]])
    #expect(models["a"] == ["inputTokens": 6, "cacheReadInputTokens": 4, "cacheCreationInputTokens": 0, "outputTokens": 2, "costUSD": 0.5])
    #expect(models["b"]?["costUSD"] == nil)
    // A run that has used nothing says nothing of it.
    let fresh = try #require(try JSONSerialization.jsonObject(with: Data(StreamJSON.result(.success, text: "ok", sessionID: "s").utf8)) as? [String: Any])
    #expect(fresh["modelUsage"] == nil && fresh["total_cost_usd"] == nil)

    let limits = try #require(try JSONSerialization.jsonObject(with: Data(StreamJSON.usageLimits(key: ORKeyStatus(usage: 1), credits: nil).utf8)) as? [String: Any])
    let key = try #require(limits["key"] as? [String: Any])
    #expect(key["limit"] is NSNull)
    #expect(limits["credits"] == nil)

    let start = try #require(try JSONSerialization.jsonObject(with: Data(StreamJSON.systemInit(sessionID: "s", model: "m", cwd: "/", tools: [],
                                                                                                  apiKeySource: "config").utf8)) as? [String: Any])
    #expect(start["apiKeySource"] as? String == "config")
}
