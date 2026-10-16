#if os(macOS)
import Foundation
import Network
import RoamPrintCore

@main
struct RoamPrintService {
    static func main() throws {
        // Filled by the local IPP adapter; all platform traffic stays in the UI process.
        try LocalIPPService.run()
    }
}
#else
import Foundation
@main
struct RoamPrintService {
    static func main() { print("本地打印服务需要 macOS Network.framework。") }
}
#endif
