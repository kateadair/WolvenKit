import SwiftUI

struct NewProjectView: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var modName = ""
    @State private var parentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    @State private var author = ""
    @State private var email = ""
    @State private var version = "1.0.0"
    @State private var isSelectingFolder = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Create Project")
                    .font(.title2.weight(.semibold))
                Text("Set up a project folder and its standard asset directories.")
                    .foregroundStyle(.secondary)
            }

            Form {
                TextField("Project Name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: name) { _, value in
                        if modName.isEmpty { modName = value }
                    }
                TextField("Mod Name", text: $modName)
                    .textFieldStyle(.roundedBorder)
                TextField("Author", text: $author)
                    .textFieldStyle(.roundedBorder)
                TextField("Email", text: $email)
                    .textFieldStyle(.roundedBorder)
                TextField("Version", text: $version)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Text(parentDirectory?.path ?? "Choose a parent folder")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(parentDirectory == nil ? .secondary : .primary)
                    Spacer()
                    Button("Choose…") { isSelectingFolder = true }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate || viewModel.isBusy)
            }
        }
        .padding(24)
        .frame(width: 520)
        .fileImporter(isPresented: $isSelectingFolder, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first {
                let hasAccess = url.startAccessingSecurityScopedResource()
                if hasAccess { url.stopAccessingSecurityScopedResource() }
                parentDirectory = url
            }
        }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !modName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && parentDirectory != nil
    }

    private func create() {
        guard let parentDirectory else { return }
        Task {
            await viewModel.createProject(
                name: name,
                modName: modName,
                parentDirectory: parentDirectory,
                author: author,
                email: email,
                version: version
            )
            if viewModel.errorMessage == nil { dismiss() }
        }
    }
}
