import Foundation

/// 读取文本文件尾部并按行解析成 JSON 对象。
/// 会话日志可能很大，只读最后一段，且丢弃被截断的首行。
enum JSONLTail {
    static func objects(_ url: URL, maxBytes: Int = 512 * 1024) -> [[String: Any]] {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? fh.close() }

        let size = (try? fh.seekToEnd()) ?? 0
        let limit = UInt64(maxBytes)
        let truncated = size > limit
        let offset = truncated ? size - limit : 0
        try? fh.seek(toOffset: offset)
        guard let data = try? fh.readToEnd(), !data.isEmpty else { return [] }

        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if truncated, !lines.isEmpty { lines.removeFirst() }

        var out: [[String: Any]] = []
        out.reserveCapacity(lines.count)
        for line in lines {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line)),
                  let dict = obj as? [String: Any] else { continue }
            out.append(dict)
        }
        return out
    }

    /// 整个文件的全部对象（用于统计今日数据，文件通常不大）
    static func allObjects(_ url: URL, maxBytes: Int = 24 * 1024 * 1024) -> [[String: Any]] {
        objects(url, maxBytes: maxBytes)
    }

    /// 从文件尾往前扫，找最后一条 `type=message, role=user` 的时间戳。
    /// 长会话里用户消息可能在文件开头很远的地方，只读尾部会错过。
    static func lastUserTimestamp(_ url: URL, scanBytes: UInt64 = 16 * 1024 * 1024) -> Double? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }

        let size = (try? fh.seekToEnd()) ?? 0
        guard size > 0 else { return nil }

        let chunk: UInt64 = 128 * 1024
        var end = size
        var scanned: UInt64 = 0
        var carry = Data()

        while end > 0, scanned < scanBytes {
            let start = end > chunk ? end - chunk : 0
            try? fh.seek(toOffset: start)
            guard let part = try? fh.read(upToCount: Int(end - start)), !part.isEmpty else { break }

            var buf = part
            buf.append(carry)
            let lines = buf.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)

            for (index, line) in lines.enumerated().reversed() {
                if start > 0, index == 0 { continue }   // 可能是被截断的半行
                guard line.count < 20_000 else { continue }
                if let obj = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                   (obj["type"] as? String) == "message",
                   (obj["role"] as? String) == "user",
                   let ts = (obj["timestamp"] as? NSNumber)?.doubleValue {
                    return ts
                }
            }

            carry = lines.first.map { Data($0) } ?? Data()
            scanned += end - start
            end = start
        }
        return nil
    }
}

enum FileUtil {
    static func mtime(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    static func files(in dir: URL, matching ext: String) -> [URL] {
        guard let list = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return list.filter { $0.pathExtension == ext }
    }

    static func subdirs(in dir: URL) -> [URL] {
        guard let list = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return list.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }
}

/// 从任意嵌套结构里捞 token 数（不同工具字段名不一）
enum TokenHarvest {
    private static let keys = ["totaltokens", "total_tokens", "outputtokens", "output_tokens",
                               "inputtokens", "input_tokens", "tokens", "tokencount"]

    static func harvest(_ any: Any, depth: Int = 0) -> Int {
        guard depth < 6 else { return 0 }
        if let dict = any as? [String: Any] {
            var sum = 0
            for (k, v) in dict {
                let lower = k.lowercased()
                if keys.contains(lower), let n = v as? NSNumber { sum += n.intValue }
                else { sum += harvest(v, depth: depth + 1) }
            }
            return sum
        }
        if let arr = any as? [Any] {
            return arr.reduce(0) { $0 + harvest($1, depth: depth + 1) }
        }
        return 0
    }
}
