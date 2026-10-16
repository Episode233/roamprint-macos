#if os(macOS)
import SwiftUI
import RoamPrintCore

@main
struct RoamPrintApplication: App {
    @StateObject private var model = PrintModel()
    var body: some Scene {
        WindowGroup("ZGCAxZGCI printer") {
            ClientView(model: model).frame(minWidth: 850, minHeight: 540)
        }
        Settings { ConfigurationView(model: model).padding().frame(width: 520) }
    }
}
#else
import Foundation
@main
struct RoamPrintApplication {
    static func main() {
        print("ZGCAxZGCI printer 的原生界面需要 macOS。核心协议与本地 IPP 队列可在此环境测试。")
    }
}
#endif
