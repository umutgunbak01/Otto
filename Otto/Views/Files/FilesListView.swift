import SwiftUI
import UniformTypeIdentifiers

struct FilesListView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText: String = ""
    @State private var selectedFileType: FileType? = nil
    @State private var isImporting: Bool = false
    @State private var importError: String?
    @State private var showingImportError: Bool = false
    @State private var previewingFile: FileItem?

    private var filteredFiles: [FileItem] {
        var files = appState.files

        // Filter by file type
        if let fileType = selectedFileType {
            files = files.filter { $0.fileType == fileType }
        }

        // Filter by search text
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            files = files.filter { file in
                file.name.lowercased().contains(query) ||
                file.tags.contains { $0.lowercased().contains(query) } ||
                (file.extractedText?.lowercased().contains(query) ?? false)
            }
        }

        return files.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            header

            OttoDivider()

            // Filters
            filterBar

            OttoDivider()

            // File list
            if filteredFiles.isEmpty {
                emptyState
            } else {
                fileList
            }
        }
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: FileStorageService.supportedUTTypes,
            allowsMultipleSelection: true
        ) { result in
            handleFileImport(result)
        }
        .alert("Import Error", isPresented: $showingImportError) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "Failed to import file")
        }
        .sheet(item: $previewingFile) { file in
            FilePreviewPopup(file: file) {
                previewingFile = nil
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("⌬ FILES")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(Theme.Colors.cyan)
                    .shadow(color: Theme.Colors.cyanGlow, radius: 4)

                Text("\(appState.files.count) file\(appState.files.count == 1 ? "" : "s")")
                    .font(Theme.Typography.caption)
                    .foregroundStyle(Theme.Colors.secondaryText)
            }

            Spacer()

            // Import button
            Button {
                isImporting = true
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Import")
                        .font(Theme.Typography.body)
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .background(Theme.Colors.accent)
                .foregroundStyle(Theme.Colors.bg0)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, Theme.Spacing.xl)
        .padding(.bottom, Theme.Spacing.md)
    }

    // MARK: - Filter Bar

    private var filterBar: some View {
        HStack(spacing: Theme.Spacing.md) {
            // Search
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Theme.Colors.tertiaryText)
                    .font(.system(size: 12))

                TextField("Search files...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(Theme.Typography.body)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Theme.Colors.tertiaryText)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xs)
            .background(Theme.Colors.secondaryBackground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))

            Spacer()

            // File type filter
            Menu {
                Button("All Files") {
                    selectedFileType = nil
                }

                Divider()

                ForEach(FileType.allCases, id: \.self) { type in
                    Button {
                        selectedFileType = type
                    } label: {
                        HStack {
                            Image(systemName: type.iconName)
                            Text(type.displayName)
                            if selectedFileType == type {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    Image(systemName: selectedFileType?.iconName ?? "doc")
                        .font(.system(size: 12))
                    Text(selectedFileType?.displayName ?? "All Types")
                        .font(Theme.Typography.caption)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10))
                }
                .padding(.horizontal, Theme.Spacing.sm)
                .padding(.vertical, Theme.Spacing.xs)
                .background(Theme.Colors.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.sm))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.sm)
    }

    // MARK: - File List

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredFiles) { file in
                    FileRowView(
                        file: file,
                        isSelected: previewingFile?.id == file.id,
                        onDelete: {
                            // Drop the preview pointer first, since the hover
                            // button kicks off `deleteFile` immediately after.
                            if previewingFile?.id == file.id { previewingFile = nil }
                        }
                    )
                    .onTapGesture {
                        previewingFile = file
                    }
                    .contextMenu {
                        Button {
                            previewingFile = file
                        } label: {
                            Label("Preview", systemImage: "eye")
                        }

                        Button {
                            openFile(file)
                        } label: {
                            Label("Open in Finder", systemImage: "folder")
                        }

                        Button(role: .destructive) {
                            if previewingFile?.id == file.id { previewingFile = nil }
                            Task {
                                await appState.deleteFile(file)
                            }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }

                    if file.id != filteredFiles.last?.id {
                        OttoDivider()
                            .padding(.leading, Theme.Spacing.xl + 36 + Theme.Spacing.md)
                    }
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.xl) {
            Spacer()

            Image(systemName: "doc.badge.plus")
                .font(.system(size: 48, weight: .thin))
                .foregroundStyle(Theme.Colors.tertiaryText)

            VStack(spacing: Theme.Spacing.sm) {
                Text(searchText.isEmpty && selectedFileType == nil ? "No Files Yet" : "No Files Found")
                    .font(Theme.Typography.title)

                Text(searchText.isEmpty && selectedFileType == nil
                    ? "Import CSV, Excel, PDF, or image files to store them in your Otto."
                    : "Try adjusting your search or filter criteria.")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Colors.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
            }

            if searchText.isEmpty && selectedFileType == nil {
                Button {
                    isImporting = true
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: "plus")
                        Text("Import Files")
                    }
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.vertical, Theme.Spacing.md)
                    .background(Theme.Colors.accent)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md))
                }
                .buttonStyle(.plain)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func handleFileImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            Task {
                var firstImportedFile: FileItem?
                for url in urls {
                    do {
                        let file = try await appState.importFile(from: url)
                        // Track the first imported file
                        if firstImportedFile == nil {
                            firstImportedFile = file
                        }
                    } catch {
                        await MainActor.run {
                            importError = error.localizedDescription
                            showingImportError = true
                        }
                    }
                }
                // Show preview popup for the first imported file
                if let file = firstImportedFile {
                    await MainActor.run {
                        previewingFile = file
                    }
                }
            }
        case .failure(let error):
            importError = error.localizedDescription
            showingImportError = true
        }
    }

    private func openFile(_ file: FileItem) {
        let url = FileStorageService.shared
        Task {
            let fileURL = await url.getFileURL(for: file)
            #if os(macOS)
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            #endif
        }
    }
}

#Preview {
    FilesListView()
        .environment(AppState())
        .frame(width: 900, height: 600)
}
