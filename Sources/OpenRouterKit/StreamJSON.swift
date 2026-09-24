// Claude Code's stream-json protocol, as `openrouter -p --input-format
// stream-json --output-format stream-json --include-partial-messages`
// speaks it: one JSON object per line each way. A host that drives
// `claude` this way drives `openrouter` the same, unchanged.
//
// Out (stdout):
//   {"type":"system","subtype":"init","session_id":…,"model":…,"cwd":…}
//   {"type":"stream_event","event":{"type":"message_start","message":{"id":…}}}
//   {"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":…}}}
//   {"type":"assistant","message":{"id":…,"model":…,"usage":{…},"content":[{"type":"text",…},{"type":"tool_use",…}]}}
//   {"type":"user","uuid":…,"message":{"content":[{"type":"tool_result","tool_use_id":…,"content":…}]}}
//   {"type":"result","is_error":false,"result":…}
// In (stdin):
//   {"type":"user","message":{"role":"user","content":[{"type":"text","text":…}]}}   (or "content":"…")
//   {"type":"control_request","request_id":…,"request":{"subtype":"interrupt"}}

import Foundation

public enum StreamJSON {
    // MARK: Out

    public static func systemInit(sessionID: String, model: String, cwd: String, tools: [String]) -> String {
        line(["type": "system", "subtype": "init", "session_id": sessionID, "model": model, "cwd": cwd, "tools": tools])
    }

    public static func messageStart(id: String) -> String {
        line(["type": "stream_event", "event": ["type": "message_start", "message": ["id": id, "role": "assistant"]]])
    }

    public static func textDelta(_ text: String) -> String {
        line(["type": "stream_event", "event": ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": text]]])
    }

    /// The finished assistant message: its text, then a tool_use block per
    /// call (the arguments as a JSON object, or `{"input": <text>}` when
    /// the model's arguments did not parse).
    public static func assistant(id: String, model: String, message: ORMessage, usage: (prompt: Int, completion: Int)?) -> String {
        var content: [[String: Any]] = []
        if let text = message.content, !text.isEmpty { content.append(["type": "text", "text": text]) }
        for call in message.toolCalls ?? [] {
            let input = (try? JSONSerialization.jsonObject(with: Data(call.function.arguments.utf8))) as? [String: Any]
            content.append(["type": "tool_use", "id": call.id, "name": call.function.name, "input": input ?? ["input": call.function.arguments]])
        }
        var body: [String: Any] = ["id": id, "role": "assistant", "model": model, "content": content]
        if let usage { body["usage"] = ["input_tokens": usage.prompt, "output_tokens": usage.completion] }
        return line(["type": "assistant", "message": body])
    }

    public static func toolResult(callID: String, output: String, isError: Bool = false) -> String {
        var block: [String: Any] = ["type": "tool_result", "tool_use_id": callID, "content": output]
        if isError { block["is_error"] = true }
        return line(["type": "user", "uuid": UUID().uuidString.lowercased(), "message": ["role": "user", "content": [block]]])
    }

    public static func result(isError: Bool, text: String, sessionID: String) -> String {
        line(["type": "result", "subtype": isError ? "error_during_execution" : "success", "is_error": isError, "result": text, "session_id": sessionID])
    }

    public static func controlResponse(requestID: String) -> String {
        line(["type": "control_response", "response": ["request_id": requestID, "subtype": "success"]])
    }

    static func line(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: In

    public enum Input: Equatable, Sendable {
        /// A user turn: the text of its content blocks, joined.
        case user(String)
        /// Interrupt the turn in flight.
        case interrupt(requestID: String)
    }

    public static func parse(_ line: String) -> Input? {
        guard let data = line.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        switch type {
        case "user":
            guard let message = object["message"] as? [String: Any] else { return nil }
            if let text = message["content"] as? String { return .user(text) }
            let blocks = (message["content"] as? [[String: Any]]) ?? []
            let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
            return .user(text)
        case "control_request":
            guard (object["request"] as? [String: Any])?["subtype"] as? String == "interrupt" else { return nil }
            return .interrupt(requestID: object["request_id"] as? String ?? "")
        default:
            return nil
        }
    }
}
