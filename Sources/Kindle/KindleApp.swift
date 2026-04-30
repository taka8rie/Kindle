import SwiftUI

@main
struct KindleApp: App {
    @StateObject private var viewModel = KindleViewModel()

    var body: some Scene {
        WindowGroup("Kindle 导书助手") {
            ContentView(viewModel: viewModel)
                .frame(minWidth: 860, minHeight: 620)
        }
        .windowResizability(.contentSize)
    }
}
