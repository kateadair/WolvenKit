import Foundation
import Combine

@MainActor
final class WorkspaceViewModel: ObservableObject {
    @Published private(set) var projects: [WolvenProject] = []
    @Published private(set) var activeProject: WolvenProject?
    @Published private(set) var projectFiles: [ProjectFile] = []
    @Published private(set) var archiveCatalog: ArchiveCatalog?
    @Published private(set) var scriptRunResult: ScriptRunResult?
    @Published private(set) var isRunningScript = false
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    @Published var isPresentingNewProject = false
    @Published var isPresentingOpenProject = false
    @Published var isPresentingArchiveBuilder = false

    private let store: ProjectStore
    private let archiveReader: ArchiveIndexReader
    private let archivePayloadService: ArchivePayloadService
    private let archiveBuilderService: ArchiveBuilderService
    private let scriptRunnerService: ScriptRunnerService
    private var archiveAccessURL: URL?
    private var archiveAccessActive = false

    init(
        store: ProjectStore = ProjectStore(),
        archiveReader: ArchiveIndexReader = ArchiveIndexReader(),
        archivePayloadService: ArchivePayloadService = ArchivePayloadService(),
        archiveBuilderService: ArchiveBuilderService = ArchiveBuilderService(),
        scriptRunnerService: ScriptRunnerService = ScriptRunnerService()
    ) {
        self.store = store
        self.archiveReader = archiveReader
        self.archivePayloadService = archivePayloadService
        self.archiveBuilderService = archiveBuilderService
        self.scriptRunnerService = scriptRunnerService
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

    func importFiles(at urls: [URL]) async {
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await store.importFiles(at: urls)
            synchronizeFromStore()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func openArchive(at url: URL) async {
        isBusy = true
        defer { isBusy = false }
        let hasAccess = url.startAccessingSecurityScopedResource()
        do {
            let catalog = try await archiveReader.readArchive(at: url)
            stopArchiveAccessIfNeeded()
            archiveCatalog = catalog
            archiveAccessURL = url
            archiveAccessActive = hasAccess
            errorMessage = nil
        } catch {
            if hasAccess { url.stopAccessingSecurityScopedResource() }
            errorMessage = error.localizedDescription
        }
    }

    func closeArchive() {
        archiveCatalog = nil
        stopArchiveAccessIfNeeded()
    }

    func exportArchiveEntry(_ entry: ArchiveEntry, to destination: URL) async {
        guard let archiveCatalog else { return }
        isBusy = true
        defer { isBusy = false }
        do {
            try await archivePayloadService.export(entry, from: archiveCatalog, to: destination)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func buildArchive(from sources: [URL], to destination: URL) async -> Int? {
        isBusy = true
        defer { isBusy = false }
        do {
            let count = try await archiveBuilderService.buildArchive(from: sources, to: destination)
            errorMessage = nil
            return count
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func runScript(_ source: String) async {
        guard let activeProject else {
            errorMessage = "Open a project before running a script."
            return
        }
        isRunningScript = true
        defer { isRunningScript = false }
        do {
            scriptRunResult = try await scriptRunnerService.run(source, in: activeProject, files: projectFiles)
            errorMessage = nil
        } catch {
            scriptRunResult = nil
            errorMessage = error.localizedDescription
        }
    }

    func clearScriptResult() {
        scriptRunResult = nil
    }

    func applyScriptEdits() async {
        guard let activeProject, let scriptRunResult else { return }
        isRunningScript = true
        defer { isRunningScript = false }
        do {
            try await scriptRunnerService.apply(scriptRunResult.edits, to: activeProject)
            self.scriptRunResult = nil
            await store.reloadProjectFiles()
            synchronizeFromStore()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func synchronizeFromStore() {
        projects = store.projects
        activeProject = store.activeProject
        projectFiles = store.projectFiles
    }

    private func stopArchiveAccessIfNeeded() {
        if archiveAccessActive, let archiveAccessURL {
            archiveAccessURL.stopAccessingSecurityScopedResource()
        }
        archiveAccessURL = nil
        archiveAccessActive = false
    }
}
