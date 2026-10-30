import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ProjectWorkspaceView: View {
    @ObservedObject var viewModel: WorkspaceViewModel
    @State private var selectedProjectID: URL?

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedProjectID) {
                Section("Recent Projects") {
                    ForEach(viewModel.projects) { project in
                        Label(project.name, systemImage: "shippingbox")
                            .tag(project.id as URL?)
                            .contextMenu {
                                Button("Open Project") { viewModel.selectProject(project) }
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([project.projectFileURL]) }
                            }
                    }
                }
            }
            .navigationTitle("Projects")
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        viewModel.isPresentingNewProject = true
                    } label: {
                        Label("New Project", systemImage: "plus")
                    }
                    .help("Create a project")

                    Button {
                        viewModel.isPresentingOpenProject = true
                    } label: {
                        Label("Open Project", systemImage: "folder")
                    }
                    .help("Open a project file")
                }
            }
        } detail: {
            detailView
        }
        .onChange(of: selectedProjectID) { _, newValue in
            guard let newValue, let project = viewModel.projects.first(where: { $0.id == newValue }) else { return }
            viewModel.selectProject(project)
        }
        .fileImporter(
            isPresented: $viewModel.isPresentingOpenProject,
            allowedContentTypes: [UTType(filenameExtension: "cpmodproj") ?? .xml],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task {
                    let hasAccess = url.startAccessingSecurityScopedResource()
                    defer { if hasAccess { url.stopAccessingSecurityScopedResource() } }
                    await viewModel.openProject(at: url)
                    selectedProjectID = url.standardizedFileURL
                }
            case .failure(let error):
                viewModel.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: $viewModel.isPresentingNewProject) {
            NewProjectView(viewModel: viewModel)
        }
        .alert("Project Error", isPresented: Binding(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "An unexpected project error occurred.")
        }
    }

    @ViewBuilder
    private var detailView: some View {
        if let project = viewModel.activeProject {
            ProjectDetailView(
                project: project,
                files: viewModel.projectFiles,
                refresh: viewModel.refreshFiles,
                importFiles: viewModel.importFiles(at:),
                reportError: { viewModel.errorMessage = $0 }
            )
        } else {
            ContentUnavailableView {
                Label("No Project Open", systemImage: "shippingbox")
            } description: {
                Text("Create a project or open an existing project file to begin.")
            } actions: {
                HStack {
                    Button("New Project…") { viewModel.isPresentingNewProject = true }
                        .buttonStyle(.borderedProminent)
                    Button("Open Project…") { viewModel.isPresentingOpenProject = true }
                        .buttonStyle(.bordered)
                }
            }
        }
    }
}

private struct ProjectDetailView: View {
    let project: WolvenProject
    let files: [ProjectFile]
    let refresh: () -> Void
    let importFiles: ([URL]) async -> Void
    let reportError: (String) -> Void
    @State private var isImportingFiles = false

    private var projectFiles: [ProjectFile] {
        files.filter { $0.url.pathExtension.lowercased() != "cpmodproj" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(project.name)
                    .font(.largeTitle.weight(.semibold))
                Text(project.description ?? "Project workspace")
                    .foregroundStyle(.secondary)
                HStack(spacing: 18) {
                    Label(project.modName, systemImage: "shippingbox")
                    if let author = project.author, !author.isEmpty {
                        Label(author, systemImage: "person")
                    }
                    if let version = project.version, !version.isEmpty {
                        Label(version, systemImage: "number")
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .padding(24)

            Divider()

            HStack {
                Text("Project Files")
                    .font(.title2.weight(.medium))
                Spacer()
                Text("\(projectFiles.count) files")
                    .foregroundStyle(.secondary)
                Button {
                    isImportingFiles = true
                } label: {
                    Label("Add Files", systemImage: "plus")
                }
                .help("Copy files into the project's raw asset folder")
                Button(action: refresh) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .labelStyle(.iconOnly)
                .help("Refresh project files")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)

            if projectFiles.isEmpty {
                ContentUnavailableView("No Project Files", systemImage: "doc", description: Text("Place source assets in this project to see them here."))
            } else {
                AssetCatalogView(files: projectFiles)
            }
        }
        .navigationTitle(project.name)
        .fileImporter(isPresented: $isImportingFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                Task {
                    let accessedURLs = urls.filter { $0.startAccessingSecurityScopedResource() }
                    defer { accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
                    await importFiles(urls)
                }
            case .failure(let error):
                reportError(error.localizedDescription)
            }
        }
    }

}
