import Foundation

/// 日志层强制脱敏（不依赖调用方自觉），与 Web 端可观测包策略一致。
public struct Redactor: Sendable {
    public static let defaultSensitiveKeys: Set<String> = [
        "password", "passwd", "pwd", "token", "authorization", "auth",
        "cookie", "secret", "apikey", "api_key", "accesstoken", "access_token",
        "refreshtoken", "refresh_token", "credential", "privatekey", "private_key", "ssn"
    ]

    private let sensitiveKeys: Set<String>
    private let mask = "***REDACTED***"
    private let pattern: NSRegularExpression

    public init(sensitiveKeys: Set<String> = Redactor.defaultSensitiveKeys) {
        self.sensitiveKeys = sensitiveKeys
        // 匹配 `key=value` / `key: value` 中的敏感值（不区分大小写）
        self.pattern = try! NSRegularExpression(
            pattern: #"(?i)((?:password|passwd|pwd|token|authorization|auth|cookie|secret|api[_-]?key|access[_-]?token|refresh[_-]?token|bearer)\s*[:=]\s*['"]?)([^'";,\s]+)"#,
            options: [])
    }

    /// 对自由文本做正则脱敏
    public func redact(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return pattern.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "$1\(mask)")
    }

    /// 按 payload 的 key 名脱敏（命中敏感 key 直接整体替换为掩码）
    public func maskSensitiveKeys(_ payload: [String: AgentValue]) -> [String: AgentValue] {
        payload.reduce(into: [String: AgentValue]()) { acc, kv in
            acc[kv.key] = shouldMask(key: kv.key) ? .string(mask) : redactValue(kv.value)
        }
    }

    /// 对 value 递归脱敏（字符串值走正则；对象/数组递归）
    public func redactValue(_ value: AgentValue) -> AgentValue {
        switch value {
        case .string(let s): return .string(redact(s))
        case .object(let dict): return .object(dict.mapValues(redactValue))
        case .array(let arr): return .array(arr.map(redactValue))
        default: return value
        }
    }

    public func shouldMask(key: String) -> Bool {
        let k = key.lowercased().replacingOccurrences(of: "[_-]", with: "", options: .regularExpression)
        return sensitiveKeys.contains(k)
    }
}
