import Foundation

enum Log {
    private static let queue = DispatchQueue(label: "app.agentbar.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    static var url: URL { Paths.root.appendingPathComponent("agentbar.log") }
    private static var rotatedURL: URL { Paths.root.appendingPathComponent("agentbar.1.log") }

    /// 日志超过这个大小就轮转一次，免得常年开着长成几十兆
    private static let maxBytes: UInt64 = 512 * 1024
    private static var writesSinceCheck = 0

    static func write(_ message: String) {
        let line = "\(stamp.string(from: Date()))  \(message)\n"
        queue.async {
            Paths.ensure()
            guard let data = line.data(using: .utf8) else { return }
            rotateIfNeeded()
            if let fh = try? FileHandle(forWritingTo: url) {
                fh.seekToEndOfFile()
                fh.write(data)
                try? fh.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    /// 同步写：进程要立刻退出时用（异步队列里的内容会丢）
    static func writeSync(_ message: String) {
        let line = "\(stamp.string(from: Date()))  \(message)\n"
        Paths.ensure()
        guard let data = line.data(using: .utf8) else { return }
        if let fh = try? FileHandle(forWritingTo: url) {
            fh.seekToEndOfFile()
            fh.write(data)
            try? fh.close()
        } else {
            try? data.write(to: url)
        }
    }

    private static func rotateIfNeeded() {
        writesSinceCheck += 1
        guard writesSinceCheck >= 50 else { return }
        writesSinceCheck = 0
        guard FileStamp.read(url).size > maxBytes else { return }
        try? FileManager.default.removeItem(at: rotatedURL)
        try? FileManager.default.moveItem(at: url, to: rotatedURL)
    }
}
