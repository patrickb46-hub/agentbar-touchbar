import Foundation

enum Log {
    private static let queue = DispatchQueue(label: "app.agentbar.log")
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    static var url: URL { Paths.root.appendingPathComponent("agentbar.log") }

    static func write(_ message: String) {
        let line = "\(stamp.string(from: Date()))  \(message)\n"
        queue.async {
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
    }
}
