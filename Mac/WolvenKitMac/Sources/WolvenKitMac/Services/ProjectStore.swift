import Foundation
import Combine

@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var projects: [WolvenProject] = []
    @Published private(set) var activeProjectID: URL?
    @Published private(set) var projectFiles: [ProjectFile] = []

    private let fileManager: FileManager
    private let recentProjectsKey = "WolvenKitMac.recentProjectPaths"
    private let maximumRecentProjects = 20

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    var activeProject: WolvenProject? {
        guard let activeProjectID else { return nil }
        return projects.first { $0.id == activeProjectID }
    }

    func restoreRecentProjects() async {
        let paths = UserDefaults.standard.stringArray(forKey: recentProjectsKey) ?? []
        var loaded: [WolvenProject] = []

        for path in paths {
            let url = URL(fileURLWithPath: path)
            if let project = try? readProject(at: url) {
                loaded.append(project)
            }
        }

        projects = loaded
        if let first = loaded.first {
            activeProjectID = first.id
            await reloadProjectFiles()
        }
    }

    func createProject(
        name proposedName: String,
        modName proposedModName: String,
        in parentDirectory: URL,
        author: String,
        email: String,
        version: String
    ) async throws -> WolvenProject {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let modName = proposedModName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidProjectName(name), Self.isValidProjectName(modName) else {
            throw ProjectStoreError.invalidName
        }
        guard fileManager.fileExists(atPath: parentDirectory.path, isDirectory: nil) else {
            throw ProjectStoreError.projectLocationUnavailable
        }

        let projectDirectory = parentDirectory.appendingPathComponent(name, isDirectory: true)
        guard !fileManager.fileExists(atPath: projectDirectory.path) else {
            throw ProjectStoreError.projectAlreadyExists(projectDirectory)
        }

        let projectFileURL = projectDirectory.appendingPathComponent(name + ".cpmodproj")
        let project = WolvenProject(
            name: name,
            modName: modName,
            projectFileURL: projectFileURL,
            author: author.nilIfBlank,
            email: email.nilIfBlank,
            version: version.nilIfBlank
        )

        do {
            try fileManager.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
            for directory in [project.archiveDirectory, project.rawDirectory, project.resourcesDirectory, project.backupDirectory] {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try writeProject(project)
        } catch {
            try? fileManager.removeItem(at: projectDirectory)
            throw error
        }

        register(project)
        await reloadProjectFiles()
        return project
    }

    func openProject(at url: URL) async throws -> WolvenProject {
        let project = try readProject(at: url)
        register(project)
        await reloadProjectFiles()
        return project
    }

    func activateProject(_ project: WolvenProject) async {
        activeProjectID = project.id
        await reloadProjectFiles()
    }

    func saveActiveProject() throws {
        guard let project = activeProject else { return }
        try writeProject(project)
    }

    func importFiles(at sourceURLs: [URL]) async throws -> Int {
        guard let project = activeProject else { return 0 }
        let destination = project.rawDirectory
        let importedCount = try await Task.detached(priority: .userInitiated) {
            try Self.copyFiles(sourceURLs, into: destination)
        }.value
        await reloadProjectFiles()
        return importedCount
    }

    func reloadProjectFiles() async {
        guard let project = activeProject else {
            projectFiles = []
            return
        }

        let root = project.projectDirectory
        let fileManager = self.fileManager
        let files = await Task.detached(priority: .utility) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                return [ProjectFile]()
            }

            var results: [ProjectFile] = []
            for case let url as URL in enumerator {
                if url.pathComponents.contains("_backups") { continue }
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), values.isRegularFile == true else {
                    continue
                }
                let relative = String(url.path.dropFirst(root.path.count + 1))
                results.append(ProjectFile(url: url, relativePath: relative, byteCount: Int64(values.fileSize ?? 0)))
            }
            return results.sorted { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        }.value

        projectFiles = files
    }

    private func readProject(at url: URL) throws -> WolvenProject {
        guard url.pathExtension.lowercased() == "cpmodproj",
              let data = try? Data(contentsOf: url),
              let document = try? XMLDocument(data: data, options: [.nodePreserveAll]),
              let root = document.rootElement(), root.name == "CP77Mod" else {
            throw ProjectStoreError.invalidProjectFile
        }

        func value(_ key: String) -> String? {
            root.elements(forName: key).first?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let name = value("Name"), !name.isEmpty else {
            throw ProjectStoreError.projectNameMissing
        }

        let openFiles = root.elements(forName: "OpenProjectFiles").first?
            .elements(forName: "string")
            .compactMap { $0.stringValue }
            ?? []

        let parsedModIoId = value("ModIoId").flatMap(Int.init) ?? -1
        return WolvenProject(
            name: name,
            modName: value("ModName")?.nilIfBlank ?? name,
            projectFileURL: url,
            author: value("Author").nilIfBlank,
            email: value("Email").nilIfBlank,
            description: value("Description").nilIfBlank,
            version: value("Version").nilIfBlank,
            openProjectFiles: openFiles,
            modIoId: parsedModIoId,
            modIoLogo: value("ModIoLogo").nilIfBlank
        )
    }

    private func writeProject(_ project: WolvenProject) throws {
        let root = XMLElement(name: "CP77Mod")
        root.addNamespace(XMLNode.namespace(withName: "xsi", stringValue: "http://www.w3.org/2001/XMLSchema-instance") as! XMLNode)
        root.addNamespace(XMLNode.namespace(withName: "xsd", stringValue: "http://www.w3.org/2001/XMLSchema") as! XMLNode)

        func add(_ name: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            root.addChild(XMLElement(name: name, stringValue: value))
        }

        add("Name", project.name)
        add("ModName", project.modName)
        add("Author", project.author)
        add("Email", project.email)
        add("Description", project.description)
        add("Version", project.version)
        add("ModIoId", String(project.modIoId))
        add("ModIoLogo", project.modIoLogo)

        let openFiles = XMLElement(name: "OpenProjectFiles")
        for file in Array(Set(project.openProjectFiles)).sorted() {
            openFiles.addChild(XMLElement(name: "string", stringValue: file))
        }
        root.addChild(openFiles)

        let document = XMLDocument(rootElement: root)
        document.characterEncoding = "UTF-8"
        document.version = "1.0"
        try document.xmlData(options: [.nodePrettyPrint]).write(to: project.projectFileURL, options: .atomic)
    }

    private func register(_ project: WolvenProject) {
        projects.removeAll { $0.id == project.id }
        projects.insert(project, at: 0)
        projects = Array(projects.prefix(maximumRecentProjects))
        activeProjectID = project.id
        UserDefaults.standard.set(projects.map { $0.projectFileURL.path }, forKey: recentProjectsKey)
    }

    private static func isValidProjectName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        return name.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar) && scalar != "/" && scalar != ":"
        }
    }

    private nonisolated static func copyFiles(_ sourceURLs: [URL], into destination: URL) throws -> Int {
        guard !sourceURLs.isEmpty else { return 0 }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

        let staging = destination.appendingPathComponent(".incoming-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)

        var stagedFiles: [(temporary: URL, name: String)] = []
        var installedFiles: [URL] = []

        do {
            for source in sourceURLs {
                let values = try source.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                let name = source.lastPathComponent
                guard !name.isEmpty, name != ".", name != ".." else { continue }
                let temporary = staging.appendingPathComponent(UUID().uuidString)
                try fileManager.copyItem(at: source, to: temporary)
                stagedFiles.append((temporary, name))
            }

            for staged in stagedFiles {
                let target = uniqueDestination(for: staged.name, in: destination, fileManager: fileManager)
                try fileManager.moveItem(at: staged.temporary, to: target)
                installedFiles.append(target)
            }

            try fileManager.removeItem(at: staging)
            return installedFiles.count
        } catch {
            for url in installedFiles {
                try? fileManager.removeItem(at: url)
            }
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    private nonisolated static func uniqueDestination(for name: String, in directory: URL, fileManager: FileManager) -> URL {
        let original = URL(fileURLWithPath: name)
        let baseName = original.deletingPathExtension().lastPathComponent
        let ext = original.pathExtension
        var index = 1

        while true {
            let suffix = index == 1 ? "" : " \(index)"
            let candidateName = ext.isEmpty ? "\(baseName)\(suffix)" : "\(baseName)\(suffix).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
            index += 1
        }
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
