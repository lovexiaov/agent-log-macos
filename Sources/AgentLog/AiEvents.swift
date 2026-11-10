import Foundation
import Logging

/// AI 交互事件便捷方法（Schema v1.4，六端统一契约）。
///
/// 契约真源：`docs/logging-framework/INTERFACE.md` §4.4。
/// - 6 个标准 `event_type`，payload 只用 snake_case 标准词表；
/// - 业务**显式埋点**（`agent_auto=false`），框架只准备数据，不 hook 具体 LLM SDK；
/// - level：request / response / tool = info，guardrail = warn，error = error；
/// - OTLP 层只作 log 信号，不产 span（可挂 `spanId` 供下游组 span）；
/// - `request_id` 由调用方在「请求→响应→工具→错误」同一轮内保持一致，用于下游串联。
///
/// `extra` 用于追加标准词表字段（`provider` / `request_id` / `prompt_tokens` / `stack` 等）
/// 或业务键；与显式参数同名的标准键以参数为准。
public extension AgentLog {

    static func aiRequest(model: String, promptText: String,
                          extra: [String: AgentValue]? = nil) {
        shared?.recordAI(level: .info, "ai request initiated", eventType: .aiRequestInitiated,
                         payload: aiPayload(extra, ["model": .string(model),
                                                    "prompt_text": .string(promptText)]))
    }

    static func aiResponse(model: String, totalTokens: Int,
                           extra: [String: AgentValue]? = nil) {
        shared?.recordAI(level: .info, "ai response received", eventType: .aiResponseReceived,
                         payload: aiPayload(extra, ["model": .string(model),
                                                    "total_tokens": .int(totalTokens)]))
    }

    static func aiToolCall(toolName: String, toolArguments: AgentValue,
                           extra: [String: AgentValue]? = nil) {
        shared?.recordAI(level: .info, "ai tool call initiated", eventType: .aiToolCallInitiated,
                         payload: aiPayload(extra, ["tool_name": .string(toolName),
                                                    "tool_arguments": toolArguments]))
    }

    static func aiToolResult(toolName: String, ok: Bool,
                             extra: [String: AgentValue]? = nil) {
        shared?.recordAI(level: .info, "ai tool call completed", eventType: .aiToolCallCompleted,
                         payload: aiPayload(extra, ["tool_name": .string(toolName),
                                                    "ok": .bool(ok)]))
    }

    static func aiGuardrail(guardrailType: String, reason: String,
                            extra: [String: AgentValue]? = nil) {
        shared?.recordAI(level: .warning, "ai guardrail triggered", eventType: .aiGuardrailTriggered,
                         payload: aiPayload(extra, ["guardrail_type": .string(guardrailType),
                                                    "reason": .string(reason)]))
    }

    static func aiError(errorType: String, message: String,
                        extra: [String: AgentValue]? = nil) {
        shared?.recordAI(level: .error, "ai interaction error", eventType: .aiError,
                         payload: aiPayload(extra, ["exception": .string(errorType),
                                                    "exception_message": .string(message),
                                                    "mechanism": "handled"]))
    }
}

/// 合并调用方扩展字段与标准词表字段；标准键以显式参数为准。
private func aiPayload(_ extra: [String: AgentValue]?,
                       _ core: [String: AgentValue]) -> [String: AgentValue] {
    var payload = extra ?? [:]
    for (key, value) in core { payload[key] = value }
    return payload
}
