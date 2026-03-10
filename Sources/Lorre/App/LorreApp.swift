import SwiftUI

@main
struct LorreApp: App {
    @StateObject private var viewModel = AppViewModel(dependencies: .live())

    var body: some Scene {
        WindowGroup("Lorre") {
            AppShellView(viewModel: viewModel)
                .frame(minWidth: 1120, minHeight: 760)
                .task {
                    await viewModel.start()
                }
        }
        .windowResizability(.contentMinSize)
    }
}
