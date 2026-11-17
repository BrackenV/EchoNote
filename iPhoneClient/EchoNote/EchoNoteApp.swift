import SwiftUI

@main
struct EchoNoteApp: App {
    @StateObject private var viewModel = EchoNoteViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
        }
    }
}
