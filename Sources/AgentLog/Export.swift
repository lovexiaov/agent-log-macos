import Foundation

/// Agent 获取日志的入口：导出 JSONL 副本 + 程序化读取全部条目。
public struct AgentLogExporter {
    public let sourceFile: URL

    public init(sourceFile: URL) { self.sourceFile = sourceFile }

    /// 导出当前 JSONL 副本到指定目录（默认桌面），供 Agent 抓取或人工分析。
    public func exportCopy(to destination: URL? = nil) throws -> URL {
        let dest = destination
            ?? FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("agent-log-\(Session.id).jsonl")
        if FileManager.default.fileExists(atPath: sourceFile.path) {
            try FileManager.default.copyItem(at: sourceFile, to: dest)
        }
        return dest
    }

    /// 读取并解析全部结构化条目（Agent 可程序化消费，无需解析二进制 SQLite）。
    public func loadEntries() throws -> [AgentLogEntry] {
        guard FileManager.default.fileExists(atPath: sourceFile.path),
              let data = try? String(contentsOf: sourceFile, encoding: .utf8) else { return [] }
        return data.split(whereSeparator: \.isNewline).compactMap { line in
            guard !line.isEmpty else { return nil }
            return try? JSONDecoder().decode(AgentLogEntry.self, from: Data(line.utf8))
        }
    }
}
