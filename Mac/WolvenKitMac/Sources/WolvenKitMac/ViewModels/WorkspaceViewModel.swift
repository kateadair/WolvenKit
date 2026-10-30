import Foundation
import Combine

@MainActor
final class WorkspaceViewModel: ObservableObject {
    @Published private(set) var projects: [WolvenProject] = []
    @Published private(set) var activeProject: WolvenProject?
    @Published private(set) var projectFiles: [ProjectFile] = []
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    @Published var isPresentingNewProject = false
    @Published var isPresentingOpenProject = false

    private let store: ProjectStore

    init(store: ProjectStore = ProjectStore()) {
        self.store = store
        Task {
            await store.restoreRecentProjects()
            synchronizeFromStore()
        }
    }

    func createProject(
        name: String,
        modName: String,
        parentDirectory: URL,
        author: String,
        email: String,
        version: String
    ) async {
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await store.createProject(
                name: name,
                modName: modName,
                in: parentDirectory,
                author: author,
                email: email,
                version: version
            )
            synchronizeFromStore()
            isPresentingNewProject = false
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openProject(at url: URL) async {
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await store.openProject(at: url)
            synchronizeFromStore()
            isPresentingOpenProject = false
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectProject(_ project: WolvenProject) {
        Task {
            await store.activateProject(project)
            synchronizeFromStore()
        }
    }

    func refreshFiles() {
        Task {
            await store.reloadProjectFiles()
            synchronizeFromStore()
        }
    }

    private func synchronizeFromStore() {
        projects = store.projects
        activeProject = store.activeProject
        projectFiles = store.projectFiles
    }
}
