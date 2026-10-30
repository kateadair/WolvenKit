import Foundation

struct ScriptEdit: Hashable, Sendable, Identifiable {
    let relativePath: String
    let text: String
    let originalData: Data

    var id: String { relativePath }
}

struct ScriptRunResult: Sendable {
    let logs: [String]
    let edits: [ScriptEdit]
}

enum ScriptRunnerError: LocalizedError {
    case invalidContext
    case scriptFailed(String)
    case invalidPath(String)
    case fileChanged(String)
    case unsupportedFile(String)
    case fileTooLarge(String)

    var errorDescription: String? {
        switch self {
        case .invalidContext:
            return "The script runtime could not be created."
        case .scriptFailed(let detail):
            return "The script did not finish: \(detail)"
        case .invalidPath(let path):
            return "The script requested a path outside the project or an invalid path: \(path)"
        case .fileChanged(let path):
            return "\(path) changed after the script read it. Run the script again before applying edits."
        case .unsupportedFile(let path):
            return "Scripts can edit supported text files only: \(path)"
        case .fileTooLarge(let path):
            return "Scripts can edit files up to 16 MB only: \(path)"
        }
    }
}
