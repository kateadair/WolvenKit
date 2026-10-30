import Foundation
import JavaScriptCore

struct ScriptRunnerService: Sendable {
    func run(_ source: String, in project: WolvenProject, files: [ProjectFile]) async throws -> ScriptRunResult {
        try await Task.detached(priority: .userInitiated) {
            try Self.runSynchronously(source, root: project.projectDirectory, files: files)
        }.value
    }

    func apply(_ edits: [ScriptEdit], to project: WolvenProject) async throws {
        try await Task.detached(priority: .userInitiated) {
            try Self.applySynchronously(edits, root: project.projectDirectory)
        }.value
    }

    private static func runSynchronously(_ source: String, root: URL, files: [ProjectFile]) throws -> ScriptRunResult {
        guard source.utf8.count <= 16 * 1024 * 1024 else { throw ScriptRunnerError.fileTooLarge("script") }
        guard let context = JSContext() else { throw ScriptRunnerError.invalidContext }
        var logs: [String] = []
        var proposedEdits: [String: ScriptEdit] = [:]
        var scriptError: String?
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()

        let logger: @convention(block) (String) -> Void = { value in logs.append(value) }
        context.setObject(logger, forKeyedSubscript: "_appendLog" as NSString)
        context.evaluateScript("globalThis.print = (...values) => _appendLog(values.map(String).join(' ')); globalThis.console = { log: (...values) => _appendLog(values.map(String).join(' ')) }; ")

        let readText: @convention(block) (String) -> String? = { relativePath in
            guard let url = try? safeURL(relativePath, root: resolvedRoot),
                  let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                  data.count <= 16 * 1024 * 1024,
                  let text = String(data: data, encoding: .utf8) else {
                return nil
            }
            return text
        }
        context.setObject(readText, forKeyedSubscript: "readText" as NSString)

        let writeText: @convention(block) (String, String) -> Bool = { relativePath, text in
            do {
                guard isEditableText(relativePath) else { throw ScriptRunnerError.unsupportedFile(relativePath) }
                let url = try safeURL(relativePath, root: resolvedRoot)
                guard let original = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
                    throw ScriptRunnerError.invalidPath(relativePath)
                }
                guard original.count <= 16 * 1024 * 1024, text.utf8.count <= 16 * 1024 * 1024 else {
                    throw ScriptRunnerError.fileTooLarge(relativePath)
                }
                try validateText(text, for: url)
                proposedEdits[relativePath] = ScriptEdit(relativePath: relativePath, text: text, originalData: original)
                return true
            } catch {
                scriptError = error.localizedDescription
                return false
            }
        }
        context.setObject(writeText, forKeyedSubscript: "writeText" as NSString)

        let projectFiles = files.map { file in
            ["path": file.relativePath, "size": file.byteCount, "extension": file.url.pathExtension] as [String: Any]
        }
        context.setObject(projectFiles as NSArray, forKeyedSubscript: "projectFiles" as NSString)
        context.exceptionHandler = { _, exception in
            scriptError = exception?.toString() ?? "Unknown JavaScript exception"
        }
        _ = context.evaluateScript(source)
        if let scriptError { throw ScriptRunnerError.scriptFailed(scriptError) }
        return ScriptRunResult(logs: logs, edits: proposedEdits.values.sorted { $0.relativePath < $1.relativePath })
    }

    private static func applySynchronously(_ edits: [ScriptEdit], root: URL) throws {
        guard !edits.isEmpty else { return }
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        var validated: [(edit: ScriptEdit, target: URL)] = []
        var seen = Set<String>()
        for edit in edits {
            guard seen.insert(edit.relativePath).inserted else { throw ScriptRunnerError.invalidPath(edit.relativePath) }
            guard isEditableText(edit.relativePath) else { throw ScriptRunnerError.unsupportedFile(edit.relativePath) }
            guard edit.text.utf8.count <= 16 * 1024 * 1024, edit.originalData.count <= 16 * 1024 * 1024 else {
                throw ScriptRunnerError.fileTooLarge(edit.relativePath)
            }
            try validateText(edit.text, for: URL(fileURLWithPath: edit.relativePath))
            let target = try safeURL(edit.relativePath, root: resolvedRoot)
            guard let current = try? Data(contentsOf: target, options: [.mappedIfSafe]), current == edit.originalData else {
                throw ScriptRunnerError.fileChanged(edit.relativePath)
            }
            validated.append((edit, target))
        }

        let transactionDirectory = resolvedRoot.appendingPathComponent(".script-transaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: transactionDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: transactionDirectory) }

        var staged: [(target: URL, replacement: URL, backup: URL)] = []
        for (index, item) in validated.enumerated() {
            let replacement = transactionDirectory.appendingPathComponent("replacement-\(index)")
            let backup = transactionDirectory.appendingPathComponent("backup-\(index)")
            try Data(item.edit.text.utf8).write(to: replacement, options: .atomic)
            try item.edit.originalData.write(to: backup, options: .atomic)
            staged.append((item.target, replacement, backup))
        }

        var installed: [(target: URL, backup: URL)] = []
        do {
            for item in staged {
                _ = try FileManager.default.replaceItemAt(item.target, withItemAt: item.replacement)
                installed.append((item.target, item.backup))
            }
        } catch {
            for item in installed.reversed() {
                let restore = transactionDirectory.appendingPathComponent("restore-\(UUID().uuidString)")
                do {
                    try FileManager.default.copyItem(at: item.backup, to: restore)
                    _ = try FileManager.default.replaceItemAt(item.target, withItemAt: restore)
                } catch {
                    throw ScriptRunnerError.scriptFailed("A file could not be restored after a failed batch edit: \(item.target.lastPathComponent)")
                }
            }
            throw error
        }
    }

    private static func safeURL(_ relativePath: String, root: URL) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\"),
              !relativePath.split(separator: "/").contains("..") else {
            throw ScriptRunnerError.invalidPath(relativePath)
        }
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(root.path + "/") else { throw ScriptRunnerError.invalidPath(relativePath) }
        return candidate
    }

    private static func isEditableText(_ path: String) -> Bool {
        ["json", "xml", "yaml", "yml", "txt", "csv", "md", "ini", "toml"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    private static func validateText(_ text: String, for url: URL) throws {
        let data = Data(text.utf8)
        switch url.pathExtension.lowercased() {
        case "json": _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        case "xml": _ = try XMLDocument(data: data, options: [.nodePreserveAll])
        default: break
        }
    }
}
