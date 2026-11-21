import Foundation

/// 一次 stat 的结果。判断「文件变了没有」全靠它，比 URLResourceValues 便宜得多。
struct FileStamp: Equatable {
    var size: UInt64
    var mtime: Double

    static let zero = FileStamp(size: 0, mtime: 0)

    static func read(_ url: URL) -> FileStamp {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return .zero }
        let m = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return FileStamp(size: UInt64(max(0, info.st_size)), mtime: m)
    }
}

/// 追加式读取某个文件的新行。
///
/// 原来每个刷新周期都把整个尾部（最多 2 MB）重读重解析一遍，
/// 819 个会话文件里只要有几个是新的，一秒就是几十 MB 的 JSON 解析。
/// 现在第一次读尾部，之后只读 offset 之后的新增字节。
final class TailFollower {
    private var offset: UInt64 = 0
    private var carry = Data()

    var position: UInt64 { offset }

    func reset(to end: UInt64) {
        offset = end
        carry.removeAll(keepingCapacity: true)
    }

    /// 返回新增的完整行。第二个返回值表示文件被截断/替换，调用方要整段重来。
    func read(url: URL, size: UInt64) -> (lines: [Data], truncated: Bool) {
        if size < offset {
            reset(to: 0)
            return ([], true)
        }
        guard size > offset else { return ([], false) }
        guard let fh = try? FileHandle(forReadingFrom: url) else { return ([], false) }
        defer { try? fh.close() }
        do {
            try fh.seek(toOffset: offset)
            guard let chunk = try fh.readToEnd(), !chunk.isEmpty else { return ([], false) }
            offset = size

            var buf = carry
            buf.append(chunk)
            var lines: [Data] = []
            var start = buf.startIndex
            var i = buf.startIndex
            while i < buf.endIndex {
                if buf[i] == UInt8(ascii: "\n") {
                    if i > start { lines.append(Data(buf[start..<i])) }
                    start = i + 1
                }
                i += 1
            }
            carry = start < buf.endIndex ? Data(buf[start..<buf.endIndex]) : Data()
            // 一行长到 4 MB 还没换行，基本是坏数据，别攒着
            if carry.count > 4 * 1024 * 1024 { carry.removeAll(keepingCapacity: false) }
            return (lines, false)
        } catch {
            return ([], false)
        }
    }
}

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
            if let obj = parseLine(line) { out.append(obj) }
        }
        return out
    }

    static func parseLine(_ line: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: line) as? [String: Any]
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
                if let obj = parseLine(line),
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
        let stamp = FileStamp.read(url)
        return stamp.mtime > 0 ? Date(timeIntervalSince1970: stamp.mtime) : .distantPast
    }

    static func stamp(_ url: URL) -> FileStamp { FileStamp.read(url) }

    static func files(in dir: URL, matching ext: String) -> [URL] {
        guard let list = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return list.filter { $0.pathExtension == ext }
    }

    /// 带 stat 的文件列表：一次目录读取 + 一次批量取属性，不逐个 stat
    static func stampedFiles(in dir: URL, matching ext: String) -> [(url: URL, stamp: FileStamp)] {
        guard let list = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [(URL, FileStamp)] = []
        out.reserveCapacity(list.count)
        for url in list where url.pathExtension == ext {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let mtime = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            let size = UInt64(max(0, values?.fileSize ?? 0))
            out.append((url, FileStamp(size: size, mtime: mtime)))
        }
        return out
    }

    static func subdirs(in dir: URL) -> [URL] {
        guard let list = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return [] }
        return list.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }
}

/// 目录列表缓存：项目目录几百个，每 8 秒全量重列一遍纯属浪费。
/// 目录 mtime 没变就不重新列（追加内容不会改目录 mtime）。
final class DirLister {
    static let shared = DirLister()

    private struct Entry {
        var dirStamp: FileStamp
        var listedAt: TimeInterval
        var files: [(url: URL, stamp: FileStamp)]
    }

    private var cache: [String: Entry] = [:]
    private let lock = NSLock()

    /// TTL 内直接复用；目录 mtime 变了才重新列。
    /// verify = true 时逐个刷新文件 stamp（扫描要这个），false 就直接用缓存里的
    /// （统计今日总量这种「晚一两秒无所谓」的场景，能省掉几百次 stat）。
    func files(in dir: URL, ext: String, ttl: TimeInterval = 3,
               verify: Bool = true) -> [(url: URL, stamp: FileStamp)] {
        let key = dir.path
        let dirStamp = FileStamp.read(dir)
        let now = Date().timeIntervalSince1970

        lock.lock()
        let cached = cache[key]
        lock.unlock()

        if let cached, cached.dirStamp == dirStamp, now - cached.listedAt < ttl {
            guard verify else { return cached.files }
            // 命中：只把「哪些文件变了」重新算一遍
            var out: [(URL, FileStamp)] = []
            out.reserveCapacity(cached.files.count)
            for item in cached.files {
                let s = FileStamp.read(item.url)
                out.append((item.url, s.size == 0 && s.mtime == 0 ? item.stamp : s))
            }
            return out
        }

        let listed = FileUtil.stampedFiles(in: dir, matching: ext)
        lock.lock()
        cache[key] = Entry(dirStamp: dirStamp, listedAt: now, files: listed)
        if cache.count > 512 { cache.removeAll(keepingCapacity: true) }
        lock.unlock()
        return listed
    }

    func removeAll() {
        lock.lock(); cache.removeAll(keepingCapacity: true); subdirCache.removeAll(keepingCapacity: true); lock.unlock()
    }

    // MARK: - 子目录

    private var subdirCache: [String: (dirStamp: FileStamp, at: TimeInterval, dirs: [URL])] = [:]

    /// 项目目录有几百个，`contentsOfDirectory` + 逐个 isDirectory 一次就是十几毫秒。
    /// 目录本身没变就复用。
    func subdirs(in dir: URL, ttl: TimeInterval = 10) -> [URL] {
        let key = dir.path
        let dirStamp = FileStamp.read(dir)
        let now = Date().timeIntervalSince1970

        lock.lock()
        if let hit = subdirCache[key], hit.dirStamp == dirStamp, now - hit.at < ttl {
            lock.unlock()
            return hit.dirs
        }
        lock.unlock()

        let dirs = FileUtil.subdirs(in: dir)
        lock.lock()
        subdirCache[key] = (dirStamp, now, dirs)
        if subdirCache.count > 64 { subdirCache.removeAll(keepingCapacity: true) }
        lock.unlock()
        return dirs
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
