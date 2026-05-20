import SwiftUI
import UniformTypeIdentifiers

struct SessionShelfView: View {
    private static let compactViewFilters: [ShelfFilter] = [.processing, .errors]

    @ObservedObject var viewModel: AppViewModel
    @State private var isPresentingImportPicker = false
    @State private var isShowingCreateFolderAlert = false
    @State private var newFolderName = ""
    @State private var contextRenameSession: SessionManifest?
    @State private var contextRenameDraft = ""
    @State private var contextDeleteSession: SessionManifest?
    @State private var contextRenameFolder: SessionFolder?
    @State private var contextRenameFolderDraft = ""
    @State private var contextDeleteFolder: SessionFolder?
    @State private var isShowingModelSettings = false
    @State private var searchText = ""
    @State private var searchDebounceTask: Task<Void, Never>?

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: DS.Space.x4) {
                VStack(alignment: .leading, spacing: DS.Space.x2) {
                    Text("Lorre")
                        .font(DS.FontStyle.appTitle)
                        .foregroundStyle(DS.ColorToken.fgPrimary)

                    Text("Fully local transcription and speaker review tool")
                        .font(DS.FontStyle.helper)
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.9)
                }

                SearchFieldView(label: "Sessions", text: $searchText)
                    .onChange(of: searchText) { _, newValue in
                        searchDebounceTask?.cancel()
                        searchDebounceTask = Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(180))
                            guard !Task.isCancelled else { return }
                            viewModel.searchQuery = newValue
                        }
                    }

                HStack(spacing: DS.Space.x2) {
                    Button {
                        isPresentingImportPicker = true
                    } label: {
                        Text("Import Audio")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .buttonStyle(SecondaryControlButtonStyle())
                    .disabled(viewModel.isStartingRecording || viewModel.hasActiveRecording)

                    Button {
                        viewModel.showRecorderScreenTapped()
                    } label: {
                        Text(viewModel.recorderShelfActionLabel)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .buttonStyle(PrimaryControlButtonStyle())
                    .disabled(viewModel.isStartingRecording || (viewModel.hasActiveRecording && viewModel.selectedSession == nil))
                }
                .frame(maxWidth: .infinity)

                if viewModel.hasActiveRecording {
                    ActiveRecordingShelfCard(viewModel: viewModel)
                }

                VStack(alignment: .leading, spacing: DS.Space.x2) {
                    CapsLabel(text: "Views")
                    ForEach(Self.compactViewFilters) { filter in
                        Button {
                            viewModel.selectedFilter = filter
                            viewModel.toggleSidebarViewExpansion(filter)
                        } label: {
                            FolderFilterRowView(
                                title: filter.title,
                                iconName: filter.iconName,
                                count: viewModel.count(for: filter),
                                isSelected: viewModel.selectedFilter == filter,
                                isExpanded: viewModel.expandedViewFilters.contains(filter)
                            )
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())

                        if viewModel.expandedViewFilters.contains(filter) {
                            FolderContentsListView(
                                sessions: viewModel.sessionsForViewBrowser(filter),
                                selectedSessionID: viewModel.selectedSessionID,
                                folders: viewModel.folders,
                                sessionActionStates: { session in
                                    viewModel.sessionActions(for: .shelfContextMenu, session: session)
                                },
                                onSelectSession: { session in
                                    viewModel.selectSession(session)
                                },
                                onPerformSessionAction: { action, session in
                                    viewModel.performSessionAction(action, for: session.id)
                                },
                                onRenameSession: { session in
                                    contextRenameSession = session
                                    contextRenameDraft = session.displayTitle
                                },
                                onDeleteSession: { session in
                                    contextDeleteSession = session
                                },
                                onMoveSession: { sessionID, folderID in
                                    viewModel.moveSession(sessionID, to: folderID)
                                }
                            )
                        }
                    }
                }

                VStack(alignment: .leading, spacing: DS.Space.x2) {
                    HStack(spacing: DS.Space.x2) {
                        CapsLabel(text: "Folders")
                        Spacer()
                        Button("New Folder") {
                            newFolderName = ""
                            isShowingCreateFolderAlert = true
                        }
                        .buttonStyle(SecondaryControlButtonStyle())
                    }

                    Button {
                        viewModel.selectFolderFilter(nil)
                    } label: {
                        FolderFilterRowView(
                            title: "All Folders",
                            iconName: "tray.full",
                            count: viewModel.sessions.count,
                            isSelected: viewModel.selectedFolderID == nil
                        )
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())

                    Button {
                        viewModel.selectFolderFilter(AppViewModel.unfiledFolderSelectionID)
                        viewModel.toggleSidebarFolderExpansion(AppViewModel.unfiledFolderSelectionID)
                    } label: {
                        FolderFilterRowView(
                            title: "Unfiled",
                            iconName: "folder",
                            count: viewModel.countForFolder(AppViewModel.unfiledFolderSelectionID),
                            isSelected: viewModel.selectedFolderID == AppViewModel.unfiledFolderSelectionID,
                            isExpanded: viewModel.expandedFolderIDs.contains(AppViewModel.unfiledFolderSelectionID)
                        )
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())

                    if viewModel.expandedFolderIDs.contains(AppViewModel.unfiledFolderSelectionID) {
                        FolderContentsListView(
                            sessions: viewModel.sessionsForFolderBrowser(AppViewModel.unfiledFolderSelectionID),
                            selectedSessionID: viewModel.selectedSessionID,
                            folders: viewModel.folders,
                            sessionActionStates: { session in
                                viewModel.sessionActions(for: .shelfContextMenu, session: session)
                            },
                            onSelectSession: { session in
                                viewModel.selectSession(session)
                            },
                            onPerformSessionAction: { action, session in
                                viewModel.performSessionAction(action, for: session.id)
                            },
                            onRenameSession: { session in
                                contextRenameSession = session
                                contextRenameDraft = session.displayTitle
                            },
                            onDeleteSession: { session in
                                contextDeleteSession = session
                            },
                            onMoveSession: { sessionID, folderID in
                                viewModel.moveSession(sessionID, to: folderID)
                            }
                        )
                    }

                    ForEach(viewModel.folders) { folder in
                        Button {
                            viewModel.selectFolderFilter(folder.id)
                            viewModel.toggleSidebarFolderExpansion(folder.id)
                        } label: {
                            FolderFilterRowView(
                                title: folder.name,
                                iconName: "folder",
                                count: viewModel.countForFolder(folder.id),
                                isSelected: viewModel.selectedFolderID == folder.id,
                                isExpanded: viewModel.expandedFolderIDs.contains(folder.id)
                            )
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button("Rename Folder…") {
                                contextRenameFolder = folder
                                contextRenameFolderDraft = folder.name
                            }
                            Button("Delete Folder…", role: .destructive) {
                                contextDeleteFolder = folder
                            }
                        }

                        if viewModel.expandedFolderIDs.contains(folder.id) {
                            FolderContentsListView(
                                sessions: viewModel.sessionsForFolderBrowser(folder.id),
                                selectedSessionID: viewModel.selectedSessionID,
                                folders: viewModel.folders,
                                sessionActionStates: { session in
                                    viewModel.sessionActions(for: .shelfContextMenu, session: session)
                                },
                                onSelectSession: { session in
                                    viewModel.selectSession(session)
                                },
                                onPerformSessionAction: { action, session in
                                    viewModel.performSessionAction(action, for: session.id)
                                },
                                onRenameSession: { session in
                                    contextRenameSession = session
                                    contextRenameDraft = session.displayTitle
                                },
                                onDeleteSession: { session in
                                    contextDeleteSession = session
                                },
                                onMoveSession: { sessionID, folderID in
                                    viewModel.moveSession(sessionID, to: folderID)
                                }
                            )
                        }
                    }
                }

                ModelStatusCompactPanelView(
                    viewModel: viewModel,
                    isShowingSettings: $isShowingModelSettings
                )
            }
            .padding(DS.Space.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
        .frame(maxHeight: .infinity, alignment: .top)
        .dsPanelSurface(cornerRadius: DS.Radius.lg)
        .fileImporter(
            isPresented: $isPresentingImportPicker,
            allowedContentTypes: [.audio]
        ) { result in
            viewModel.importAudioPickerCompleted(result)
        }
        .alert("New Folder", isPresented: $isShowingCreateFolderAlert) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                viewModel.createFolder(named: newFolderName)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Create a local session folder for organizing recordings.")
        }
        .alert("Rename Folder", isPresented: Binding(
            get: { contextRenameFolder != nil },
            set: { if !$0 { contextRenameFolder = nil } }
        )) {
            TextField("Folder name", text: $contextRenameFolderDraft)
            Button("Save") {
                if let folder = contextRenameFolder {
                    viewModel.renameFolder(folder.id, to: contextRenameFolderDraft)
                }
                contextRenameFolder = nil
            }
            Button("Cancel", role: .cancel) {
                contextRenameFolder = nil
            }
        } message: {
            Text("Rename this folder for session organization.")
        }
        .alert("Rename Recording", isPresented: Binding(
            get: { contextRenameSession != nil },
            set: { if !$0 { contextRenameSession = nil } }
        )) {
            TextField("Recording name", text: $contextRenameDraft)
            Button("Save") {
                if let session = contextRenameSession {
                    viewModel.renameSession(session.id, to: contextRenameDraft)
                }
                contextRenameSession = nil
            }
            Button("Cancel", role: .cancel) {
                contextRenameSession = nil
            }
        } message: {
            Text("Rename this recording in the session shelf and exports.")
        }
        .confirmationDialog(
            "Delete this folder?",
            isPresented: Binding(
                get: { contextDeleteFolder != nil },
                set: { if !$0 { contextDeleteFolder = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Folder", role: .destructive) {
                if let folder = contextDeleteFolder {
                    viewModel.deleteFolder(folder.id)
                }
                contextDeleteFolder = nil
            }
            Button("Cancel", role: .cancel) {
                contextDeleteFolder = nil
            }
        } message: {
            if let folder = contextDeleteFolder {
                Text("Delete folder \"\(folder.name)\" and move its recordings to Unfiled.")
            } else {
                Text("Delete this folder and move its recordings to Unfiled.")
            }
        }
        .confirmationDialog(
            "Delete this recording?",
            isPresented: Binding(
                get: { contextDeleteSession != nil },
                set: { if !$0 { contextDeleteSession = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Session", role: .destructive) {
                if let session = contextDeleteSession {
                    viewModel.deleteSession(session.id)
                }
                contextDeleteSession = nil
            }
            Button("Cancel", role: .cancel) {
                contextDeleteSession = nil
            }
        } message: {
            Text("This removes the session audio, transcript, and local exports from Lorre storage.")
        }
        .onAppear {
            searchText = viewModel.searchQuery
        }
        .onChange(of: viewModel.searchQuery) { _, newValue in
            if searchText != newValue {
                searchText = newValue
            }
        }
        .onDisappear {
            searchDebounceTask?.cancel()
            searchDebounceTask = nil
        }
    }
}

private struct ActiveRecordingShelfCard: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x2) {
            HStack(spacing: DS.Space.x2) {
                HStack(alignment: .center, spacing: 6) {
                    Circle()
                        .fill(DS.ColorToken.white.opacity(0.92))
                        .frame(width: 6, height: 6)

                    Text(viewModel.isStoppingRecording ? "FINALIZING" : "LIVE")
                        .font(DS.FontStyle.control)
                        .foregroundStyle(DS.ColorToken.white)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.horizontal, DS.Space.x2)
                .padding(.vertical, 6)
                .background(
                    Capsule(style: .continuous)
                        .fill(DS.ColorToken.black)
                )
                Spacer(minLength: 0)
                Text(Formatters.duration(viewModel.recordingElapsedSeconds))
                    .font(DS.FontStyle.monoStrong)
                    .foregroundStyle(DS.ColorToken.fgPrimary)
            }

            Text(viewModel.activeRecordingHeadline)
                .font(DS.FontStyle.bodyStrong)
                .foregroundStyle(DS.ColorToken.fgPrimary)

            Text(viewModel.activeRecordingDetail)
                .font(DS.FontStyle.helper)
                .foregroundStyle(DS.ColorToken.fgSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DS.Space.x2) {
                CapsLabel(text: viewModel.activeRecordingSourceBadge)
                Spacer(minLength: 0)
                if viewModel.selectedSession != nil {
                    Button("Open Recorder") {
                        viewModel.showRecorderScreenTapped()
                    }
                    .buttonStyle(SecondaryControlButtonStyle())
                    .disabled(viewModel.isStoppingRecording)
                }
            }

            IndexRailView(mode: .live(viewModel.liveMeterSamples), height: 10)
                .frame(maxWidth: .infinity)
        }
        .padding(DS.Space.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsPanelSurface(alt: true, cornerRadius: DS.Radius.md)
    }
}

private struct FolderFilterRowView: View {
    let title: String
    let iconName: String
    let count: Int
    let isSelected: Bool
    var isExpanded: Bool? = nil

    var body: some View {
        HStack(spacing: DS.Space.x2) {
            if let isExpanded {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DS.ColorToken.fgSecondary)
                    .frame(width: 10)
            }
            Image(systemName: iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.ColorToken.fgSecondary)
                .frame(width: 16)

            Text(title)
                .font(DS.FontStyle.body)
                .foregroundStyle(DS.ColorToken.fgPrimary)

            Spacer()

            Text("\(count)")
                .font(DS.FontStyle.mono)
                .foregroundStyle(DS.ColorToken.fgSecondary)
        }
        .padding(.horizontal, DS.Space.x3)
        .padding(.vertical, DS.Space.x2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsPanelSurface(selected: isSelected, alt: !isSelected, cornerRadius: DS.Radius.sm)
    }
}

private struct FolderContentsListView: View {
    let sessions: [SessionManifest]
    let selectedSessionID: UUID?
    let folders: [SessionFolder]
    let sessionActionStates: (SessionManifest) -> [SessionActionState]
    let onSelectSession: (SessionManifest) -> Void
    let onPerformSessionAction: (SessionAction, SessionManifest) -> Void
    let onRenameSession: (SessionManifest) -> Void
    let onDeleteSession: (SessionManifest) -> Void
    let onMoveSession: (UUID, String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x1) {
            if sessions.isEmpty {
                Text("No recordings")
                    .font(DS.FontStyle.helper)
                    .foregroundStyle(DS.ColorToken.fgSecondary)
                    .padding(.leading, DS.Space.x6)
                    .padding(.vertical, DS.Space.x1)
            } else {
                ForEach(sessions) { session in
                    Button {
                        onSelectSession(session)
                    } label: {
                        HStack(spacing: DS.Space.x2) {
                            Circle()
                                .fill(DS.ColorToken.fgSecondary.opacity(0.7))
                                .frame(width: 4, height: 4)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(primaryShelfTitle(for: session))
                                    .font(DS.FontStyle.body)
                                    .foregroundStyle(DS.ColorToken.fgPrimary)
                                    .lineLimit(1)
                                Text(secondaryShelfMetadata(for: session))
                                .font(DS.FontStyle.mono)
                                .foregroundStyle(DS.ColorToken.fgSecondary)
                                .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Text(session.status.label.uppercased())
                                .font(DS.FontStyle.control)
                                .tracking(0.6)
                                .foregroundStyle(DS.ColorToken.fgSecondary)
                        }
                        .padding(.horizontal, DS.Space.x2_5)
                        .padding(.vertical, DS.Space.x2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .dsPanelSurface(
                            selected: selectedSessionID == session.id,
                            alt: true,
                            cornerRadius: DS.Radius.sm
                        )
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    .contextMenu {
                        let actionStates = Dictionary(
                            uniqueKeysWithValues: sessionActionStates(session).map { ($0.action, $0) }
                        )

                        if let revealState = actionStates[.revealFiles] {
                            Button(revealState.action.title) {
                                onPerformSessionAction(.revealFiles, session)
                            }
                            .disabled(!revealState.isEnabled)
                        }

                        if let retryState = actionStates[.retryProcessing] {
                            Button(retryState.action.title) {
                                onPerformSessionAction(.retryProcessing, session)
                            }
                            .disabled(!retryState.isEnabled)
                        }

                        if actionStates[.retryProcessing] != nil {
                            Divider()
                        }

                        Button("Rename…") {
                            onRenameSession(session)
                        }
                        .disabled(!(actionStates[.rename]?.isEnabled ?? false))

                        Button("Delete…", role: .destructive) {
                            onDeleteSession(session)
                        }
                        .disabled(!(actionStates[.delete]?.isEnabled ?? false))

                        Divider()

                        Menu("Move to Folder") {
                            Button("Unfiled") {
                                onMoveSession(session.id, nil)
                            }
                            Divider()
                            ForEach(folders) { folder in
                                Button(folder.name) {
                                    onMoveSession(session.id, folder.id)
                                }
                            }
                        }
                        .disabled(!(actionStates[.moveToFolder]?.isEnabled ?? false))
                    }
                    .padding(.leading, DS.Space.x4)
                }
            }
        }
    }

    private func primaryShelfTitle(for session: SessionManifest) -> String {
        guard isDefaultGeneratedSessionTitle(session.displayTitle) else {
            return session.displayTitle
        }
        let date = session.recordedAt ?? session.createdAt
        let timeString = date.formatted(date: .omitted, time: .shortened)
        if let duration = session.durationSeconds {
            return "\(timeString) • \(Formatters.duration(duration))"
        }
        return timeString
    }

    private func secondaryShelfMetadata(for session: SessionManifest) -> String {
        let date = session.recordedAt ?? session.createdAt
        if isDefaultGeneratedSessionTitle(session.displayTitle) {
            return date.formatted(date: .abbreviated, time: .omitted)
        }
        return Formatters.sessionMetadata(date: date, durationSeconds: session.durationSeconds)
    }

    private func isDefaultGeneratedSessionTitle(_ title: String) -> Bool {
        title.hasPrefix("Session ")
    }
}
