import SwiftUI

@main
struct LorreApp: App {
    #if canImport(AppKit)
    @NSApplicationDelegateAdaptor(LorreAppDelegate.self) private var appDelegate
    #endif
    @StateObject private var viewModel = AppViewModel(dependencies: .live())

    var body: some Scene {
        WindowGroup("Lorre") {
            AppShellView(viewModel: viewModel)
                .frame(minWidth: 1120, minHeight: 760)
                .task {
                    #if canImport(AppKit)
                    appDelegate.viewModel = viewModel
                    #endif
                    await viewModel.start()
                }
        }
        .windowResizability(.contentMinSize)
    }
}
