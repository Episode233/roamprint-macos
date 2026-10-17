#if os(macOS)
import Foundation
import Network
import RoamPrintCore

@main
struct RoamPrintService {
    static func main() throws {
        // Internal CI mode isolates captures and never opens the application.
        let args = Array(CommandLine.arguments.dropFirst())
        if args.count == 2, args[0] == "--test-job-root", args[1].hasPrefix("/") {
            try LocalIPPService.run(testJobRoot: URL(fileURLWithPath: args[1], isDirectory: true))
        } else if args.isEmpty {
            try LocalIPPService.run()
        } else {
            throw PrintError.invalidConfiguration("本地打印服务启动参数无效。")
        }
    }
}
#else
import Foundation
@main
struct RoamPrintService {
    static func main() { print("本地打印服务需要 macOS Network.framework。") }
}
#endif
