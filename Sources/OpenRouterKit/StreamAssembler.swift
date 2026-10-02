// Reassembles a streamed chat completion. OpenRouter sends deltas: text a
// fragment at a time, and tool calls whose name and arguments arrive in
// pieces, indexed. This gathers them into whole tokens and, at the end,
// one assistant message with its text and tool calls — or throws, when
// the stream says it failed or ends before the completion does.

import Foundation

struct StreamAssembler {
    private var text = ""
    private var calls: [Int: ORToolCall] = [:]
    private var finishReason: String?

    /// Feeds one SSE data object, yielding token events as text arrives.
    /// Tool calls are held until `finish`, when they are whole. Throws
    /// when the object is not one (`malformed`) or carries an error
    /// (`failed`): a provider that fails part-way says so in the stream,
    /// the HTTP status having long been sent as 200.
    mutating func ingest(_ data: Data) throws -> [ORStreamEvent] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ORStreamError.malformed(String(decoding: data.prefix(200), as: UTF8.self))
        }
        if let error = root["error"] as? [String: Any] {
            let code = (error["code"] as? String) ?? (error["code"] as? Int).map(String.init)
            throw ORStreamError.failed(code: code, message: error["message"] as? String ?? "no message")
        }
        var events: [ORStreamEvent] = []
        if let usage = root["usage"] as? [String: Any] {
            let prompt = usage["prompt_tokens"] as? Int ?? 0
            let completion = usage["completion_tokens"] as? Int ?? 0
            if prompt > 0 || completion > 0 { events.append(.usage(prompt: prompt, completion: completion)) }
        }
        guard let choices = root["choices"] as? [[String: Any]], let choice = choices.first else { return events }
        if let reason = choice["finish_reason"] as? String { finishReason = reason }
        guard let delta = choice["delta"] as? [String: Any] else { return events }
        if let piece = delta["content"] as? String, !piece.isEmpty {
            text += piece
            events.append(.token(piece))
        }
        if let toolDeltas = delta["tool_calls"] as? [[String: Any]] {
            for toolDelta in toolDeltas {
                let index = toolDelta["index"] as? Int ?? 0
                var call = calls[index] ?? ORToolCall(id: "", function: .init(name: "", arguments: ""))
                if let id = toolDelta["id"] as? String, !id.isEmpty { call.id = id }
                if let function = toolDelta["function"] as? [String: Any] {
                    if let name = function["name"] as? String, !name.isEmpty { call.function.name = name }
                    if let args = function["arguments"] as? String { call.function.arguments += args }
                }
                calls[index] = call
            }
        }
        return events
    }

    /// The stream is over: the finished assistant message, with its tool
    /// calls assembled, and why the model stopped. Throws `incomplete`
    /// when nothing said the completion was: no finish reason, and no
    /// `[DONE]` (`sawDone`) — the connection ended first.
    func finish(sawDone: Bool) throws -> ORStreamEvent {
        guard finishReason != nil || sawDone else { throw ORStreamError.incomplete }
        if finishReason == "error" { throw ORStreamError.failed(code: nil, message: "the provider ended the reply with an error") }
        let toolCalls = calls.keys.sorted().compactMap { calls[$0] }.filter { !$0.id.isEmpty || !$0.function.name.isEmpty }
        let message = ORMessage(role: .assistant,
                                content: text.isEmpty ? nil : text,
                                toolCalls: toolCalls.isEmpty ? nil : toolCalls)
        return .finished(reason: finishReason, message: message)
    }
}
