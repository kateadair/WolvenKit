import SwiftUI

@main
struct WolvenKitMacApp: App {
    @StateObject private var workspace = WorkspaceViewModel()

    var body: some Scene {
        WindowGroup("WolvenKit") {
            ProjectWorkspaceView(viewModel: workspace)
                .frame(minWidth: 900, minHeight: 620)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project…") {
                    workspace.isPresentingNewProject = true
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("Open Project…") {
                    workspace.isPresentingOpenProject = true
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
