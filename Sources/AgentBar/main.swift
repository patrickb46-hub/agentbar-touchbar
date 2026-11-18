import AppKit
import Foundation

let argv = CommandLine.arguments

if argv.count > 1 {
    switch argv[1] {
    case "report": CLI.report(Array(argv.dropFirst(2))); exit(0)
    case "hook":   CLI.hook(); exit(0)
    case "render": CLI.render(Array(argv.dropFirst(2))); exit(0)
    case "dump":   CLI.dump(); exit(0)
    case "probe":  CLI.probe(Array(argv.dropFirst(2))); exit(0)
    case "clean":  CLI.clean(); exit(0)
    case "-h", "--help", "help":
        print(CLI.helpText); exit(0)
    default:
        FileHandle.standardError.write("未知命令：\(argv[1])\n运行 agentbar --help 查看用法\n".data(using: .utf8)!)
        exit(2)
    }
}

AgentBarApp.run()
