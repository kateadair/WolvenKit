import Foundation

struct WolvenProject: Identifiable, Hashable, Sendable {
    let id: URL
    var name: String
    var modName: String
    var projectFileURL: URL
    var author: String?
    var email: String?
    var description: String?
    var version: String?
    var openProjectFiles: [String]
    var modIoId: Int
    var modIoLogo: String?

    var projectDirectory: URL {
        projectFileURL.deletingLastPathComponent()
    }

    var sourceDirectory: URL {
        projectDirectory.appendingPathComponent("source", isDirectory: true)
    }

    var archiveDirectory: URL {
        sourceDirectory.appendingPathComponent("archive", isDirectory: true)
    }

    var rawDirectory: URL {
        sourceDirectory.appendingPathComponent("raw", isDirectory: true)
    }

    var resourcesDirectory: URL {
        sourceDirectory.appendingPathComponent("resources", isDirectory: true)
    }

    var backupDirectory: URL {
        projectDirectory.appendingPathComponent("_backups", isDirectory: true)
    }

    init(
        name: String,
        modName: String,
        projectFileURL: URL,
        author: String? = nil,
        email: String? = nil,
        description: String? = nil,
        version: String? = nil,
        openProjectFiles: [String] = [],
        modIoId: Int = -1,
        modIoLogo: String? = nil
    ) {
        self.id = projectFileURL.standardizedFileURL
        self.name = name
        self.modName = modName
        self.projectFileURL = projectFileURL.standardizedFileURL
        self.author = author
        self.email = email
        self.description = description
        self.version = version
        self.openProjectFiles = openProjectFiles
        self.modIoId = modIoId
        self.modIoLogo = modIoLogo
    }
}

struct ProjectFile: Identifiable, Hashable, Sendable {
    let url: URL
    let relativePath: String

    var id: String { relativePath }

    var byteCount: Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }
}

enum ProjectStoreError: LocalizedError {
    case invalidName
    case projectAlreadyExists(URL)
    case invalidProjectFile
    case projectNameMissing
    case projectLocationUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidName:
            return "Enter a project name without path separators or control characters."
        case .projectAlreadyExists(let url):
            return "A project already exists at \(url.path)."
        case .invalidProjectFile:
            return "The selected file is not a valid WolvenKit project."
        case .projectNameMissing:
            return "The project file does not contain a project name."
        case .projectLocationUnavailable:
            return "Choose an existing folder for the project."
        }
    }
}
