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

    /// Display-only date buckets over the sorted list (mockup group labels).
    private struct FileGroup: Identifiable {
        let id: String
        let title: String
        let files: [FileItem]
    }

    private var fileGroups: [FileGroup] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today) ?? today
        let weekStart = cal.dateInterval(of: .weekOfYear, for: Date())?.start ?? today

        var buckets: [(id: String, title: String, files: [FileItem])] = [
            ("today", "Today", []),
            ("yesterday", "Yesterday", []),
            ("week", "Earlier this week", []),
            ("earlier", "Earlier", []),
        ]

        for file in filteredFiles {
            let day = cal.startOfDay(for: file.updatedAt)
            if day == today {
                buckets[0].files.append(file)
            } else if day == yesterday {
                buckets[1].files.append(file)
            } else if day >= weekStart {
                buckets[2].files.append(file)
            } else {
                buckets[3].files.append(file)
            }
        }

        return buckets
            .filter { !$0.files.isEmpty }
            .map { FileGroup(id: $0.id, title: $0.title, files: $0.files) }
    }

    var body: some View {
        VStack(spacing: 0) {
            viewbar

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
        // Full-area overlay instead of a sheet: sheets size to their ideal
        // width and can never fill the window, which kept the CSV table
        // cramped. The overlay gives the preview the whole content area.
        .overlay {
            if let file = previewingFile {
                ZStack {
                    Color.black.opacity(0.45)
                        .onTapGesture { previewingFile = nil }

                    FilePreviewPopup(file: file) {
                        previewingFile = nil
                    }
                    .id(file.id)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.lg))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.Radius.lg)
                            .stroke(Theme.Colors.panelEdge, lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.45), radius: 36, y: 10)
                    .padding(Theme.Spacing.xl)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: previewingFile != nil)
        .onChange(of: appState.locateItemId) { _, newValue in
            openLocatedFile(newValue)
        }
        .onAppear {
            openLocatedFile(appState.locateItemId)
        }
    }

    /// Locate-flow arrival: open the requested file's preview and consume the
    /// request (same pattern as ConnectionListView).
    private func openLocatedFile(_ itemId: UUID?) {
        guard let itemId, let file = appState.files.first(where: { $0.id == itemId }) else { return }
        previewingFile = file
        appState.locateItemId = nil
    }

    // MARK: - Viewbar

    private var viewbar: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Files")
                .font(Theme.Typography.display)
                .foregroundStyle(Theme.Colors.text)

            OttoCountChip(text: countText)

            typeFilterMenu
                .padding(.leading, 4)

            Spacer(minLength: 8)

            OttoSearchMini(placeholder: "Search files…", text: $searchText)

            OttoNewButton(label: "Import") {
                isImporting = true
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    private var countText: String {
        let count = appState.files.count
        let total = appState.files.reduce(Int64(0)) { $0 + $1.fileSize }
        guard count > 0, total > 0 else {
            return "\(count) file\(count == 1 ? "" : "s")"
        }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return "\(count) · \(formatter.string(fromByteCount: total))"
    }

    /// Seven file types + "all" is too many for a pill rail, so the type
    /// filter stays a Menu — restyled with the shared bar-button chrome.
    private var typeFilterMenu: some View {
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
            OttoBarButtonLabel(
                label: selectedFileType?.displayName ?? "Type",
                showsCaret: true
            )
        }
        .buttonStyle(.plain)
        #if os(macOS)
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        #endif
    }

    // MARK: - File List

    private var fileList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(fileGroups) { group in
                    OttoGroupLabel(text: group.title, count: group.files.count)

                    ForEach(group.files) { file in
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
                    }
                }
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.xxl)
            .frame(maxWidth: 828)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        let unfiltered = searchText.isEmpty && selectedFileType == nil
        return OttoEmptyState(
            systemImage: "folder",
            title: unfiltered ? "No Files Yet" : "No Files Found",
            message: unfiltered
                ? "Import CSV, Excel, PDF, or image files to store them in your Otto."
                : "Try adjusting your search or filter criteria.",
            tip: "Everything you import becomes agent-readable"
        ) {
            if unfiltered {
                OttoNewButton(label: "Import Files") {
                    isImporting = true
                }
            }
        }
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
