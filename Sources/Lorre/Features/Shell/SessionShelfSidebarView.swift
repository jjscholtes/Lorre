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

                SearchFieldView(label: "Sessions", text: $viewModel.searchQuery)

                HStack(spacing: DS.Space.x2) {
                    Button {
                        isPresentingImportPicker = true
                    } label: {
                        Text("Import Audio")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .buttonStyle(SecondaryControlButtonStyle())

                    Button {
                        viewModel.showRecorderScreenTapped()
                    } label: {
                        Text("New Recording")
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                    .buttonStyle(PrimaryControlButtonStyle())
                }
                .frame(maxWidth: .infinity)

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
                                onSelectSession: { session in
                                    viewModel.selectSession(session)
                                },
                                onRevealSession: { session in
                                    viewModel.revealFiles(for: session.id)
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
                            onSelectSession: { session in
                                viewModel.selectSession(session)
                            },
                            onRevealSession: { session in
                                viewModel.revealFiles(for: session.id)
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
                                onSelectSession: { session in
                                    viewModel.selectSession(session)
                                },
                                onRevealSession: { session in
                                    viewModel.revealFiles(for: session.id)
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
    }
}

private struct ModelStatusCompactPanelView: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var isShowingSettings: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x2) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.x2) {
                CapsLabel(text: "Models")
                Spacer()
                statusBadge
                Button {
                    isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(SecondaryControlButtonStyle())
                .help("Transcription and recording settings")
            }

            Text(viewModel.modelPreparationStatusLine)
                .font(DS.FontStyle.bodyStrong)
                .foregroundStyle(DS.ColorToken.fgPrimary)
                .lineLimit(1)

            HStack(spacing: DS.Space.x2) {
                Text("Diar \(viewModel.isSpeakerDiarizationEnabled ? "On" : "Off")")
                    .font(DS.FontStyle.mono)
                    .foregroundStyle(DS.ColorToken.fgSecondary)
                if viewModel.isSpeakerDiarizationEnabled {
                    Text("Spk \(viewModel.diarizationExpectedSpeakerCountHint.shortLabel)")
                        .font(DS.FontStyle.mono)
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                }
                if viewModel.isDiarizationDebugExportEnabled {
                    Text("DiarDbg")
                        .font(DS.FontStyle.mono)
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                }
                Text("Live \(viewModel.isLiveTranscriptionEnabled ? "On" : "Off")")
                    .font(DS.FontStyle.mono)
                    .foregroundStyle(DS.ColorToken.fgSecondary)
                if viewModel.isTranscriptConfidenceVisible {
                    Text("Conf On")
                        .font(DS.FontStyle.mono)
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                }
                if viewModel.isVocabularyBoostingEnabled {
                    Text("Vocab On")
                        .font(DS.FontStyle.mono)
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                }
                Spacer(minLength: 0)
            }
            .lineLimit(1)

            IndexRailView(mode: railMode, height: 7)
        }
        .padding(DS.Space.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsPanelSurface(alt: true, cornerRadius: DS.Radius.md)
        .popover(isPresented: $isShowingSettings, arrowEdge: .leading) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.x3) {
                    HStack {
                        Text("Transcription Settings")
                            .font(DS.FontStyle.panelTitle)
                            .foregroundStyle(DS.ColorToken.fgPrimary)
                        Spacer()
                        Button("Done") {
                            isShowingSettings = false
                        }
                        .buttonStyle(SecondaryControlButtonStyle())
                    }

                    ModelStatusPanelView(viewModel: viewModel)
                }
                .padding(DS.Space.x3)
            }
            .frame(width: 600, height: 660)
            .background(DS.ColorToken.bgApp)
        }
    }

    private var railMode: IndexRailMode {
        if let progress = viewModel.modelPreparationProgress,
           viewModel.modelPreparationState == .preparing || viewModel.modelPreparationState == .ready {
            return .progress(progress)
        }
        return .idleTicks
    }

    private var statusBadge: some View {
        let label: String
        switch viewModel.modelPreparationState {
        case .unknown, .idle:
            label = "IDLE"
        case .preparing:
            label = "PREP"
        case .ready:
            label = "READY"
        case .error:
            label = "ERROR"
        }

        return HStack(spacing: 6) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 6, height: 6)
            Text(label)
                .font(DS.FontStyle.control)
                .tracking(0.35)
                .foregroundStyle(DS.ColorToken.fgSecondary)
        }
        .padding(.horizontal, DS.Space.x3)
        .padding(.vertical, DS.Space.x2)
        .frame(minHeight: 32)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .fill(DS.ColorToken.bgPanelAlt)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .stroke(DS.ColorToken.borderStrong, lineWidth: 1)
        )
    }

    private var statusDotColor: Color {
        switch viewModel.modelPreparationState {
        case .ready:
            return DS.ColorToken.statusReady
        case .preparing:
            return DS.ColorToken.statusPreparing
        case .error:
            return DS.ColorToken.statusError
        case .idle, .unknown:
            return DS.ColorToken.statusIdle
        }
    }
}

private struct ModelStatusPanelView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var activeTooltipRowID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x2) {
            HStack(alignment: .firstTextBaseline) {
                CapsLabel(text: "Speech & Models")
                Spacer()
                statusBadge
            }

            modelReadinessSummary

            VStack(alignment: .leading, spacing: DS.Space.x3) {
                toggleSettingsRow(
                    id: "show-confidence",
                    label: "Show Confidence",
                    tooltip: "Shows how sure Lorre is about each transcript line. Helpful when checking for mistakes.",
                    isOn: viewModel.isTranscriptConfidenceVisible,
                    setValue: viewModel.setTranscriptConfidenceVisible
                ) {
                    Text(
                        viewModel.isTranscriptConfidenceVisible
                            ? "Shows confidence under each transcript line."
                            : "Off by default for a cleaner transcript view."
                    )
                    .font(DS.FontStyle.helper)
                    .foregroundStyle(DS.ColorToken.fgSecondary)
                    .lineLimit(2)
                }

                toggleSettingsRow(
                    id: "diar-debug-json",
                    label: "Diar Debug JSON",
                    tooltip: "Saves an extra debug file if speaker labels look wrong. Most people can leave this off.",
                    isOn: viewModel.isDiarizationDebugExportEnabled,
                    setValue: viewModel.setDiarizationDebugExportEnabled
                ) {
                    Text(
                        viewModel.isDiarizationDebugExportEnabled
                            ? "Saves an extra debug file in each session folder."
                            : "Usually not needed unless you are troubleshooting."
                    )
                    .font(DS.FontStyle.helper)
                    .foregroundStyle(DS.ColorToken.fgSecondary)
                    .lineLimit(3)
                }

                toggleSettingsRow(
                    id: "vocab-boosting",
                    label: "Vocab Boosting",
                    tooltip: "Helps Lorre better recognize names and special words from your list below.",
                    isOn: viewModel.isVocabularyBoostingEnabled,
                    setValue: viewModel.setVocabularyBoostingEnabled
                ) {
                    Text(
                        viewModel.isVocabularyBoostingEnabled
                            ? "Uses your custom word list to improve recognition."
                            : "Leave off unless you need better recognition for names or special terms."
                    )
                    .font(DS.FontStyle.helper)
                    .foregroundStyle(DS.ColorToken.fgSecondary)
                    .lineLimit(3)
                }

                VStack(alignment: .leading, spacing: DS.Space.x2) {
                    HStack(spacing: DS.Space.x2) {
                        settingsLabelCell(
                            id: "vocab-terms",
                            label: "Vocab Terms",
                            tooltip: "Add words you want Lorre to recognize better. Use one line per word. You can add common alternatives after a colon."
                        )

                        Spacer()
                        Text("\(viewModel.customVocabularyTermLineCount) lines")
                            .font(DS.FontStyle.mono)
                            .foregroundStyle(DS.ColorToken.fgTertiary)
                    }

                    TextEditor(text: $viewModel.customVocabularySimpleFormatTerms)
                        .font(DS.FontStyle.mono)
                        .foregroundStyle(DS.ColorToken.fgPrimary)
                        .scrollContentBackground(.hidden)
                        .padding(DS.Space.x1)
                        .frame(minHeight: 78, maxHeight: 92)
                        .background(DS.ColorToken.fieldBg)
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.sm)
                                .stroke(DS.ColorToken.fieldBorder, lineWidth: 1)
                        )

                    HStack(spacing: DS.Space.x2) {
                        Button("Save Terms") {
                            viewModel.saveCustomVocabularyTerms()
                        }
                        .buttonStyle(SecondaryControlButtonStyle())

                        Text("One per line. Aliases format: Canonical: alias1, alias2")
                            .font(DS.FontStyle.helper)
                            .foregroundStyle(DS.ColorToken.fgSecondary)
                            .lineLimit(2)
                    }
                }
                .padding(.top, DS.Space.x1)
                .zIndex(activeTooltipRowID == "vocab-terms" ? 100 : 0)
            }
            .padding(.top, DS.Space.x1)
            .padding(.bottom, DS.Space.x1)

            IndexRailView(mode: railMode, height: 7)
                .padding(.top, DS.Space.x1)

            HStack(spacing: DS.Space.x2) {
                Button(action: viewModel.prepareModelsTapped) {
                    Text(buttonLabel)
                }
                .buttonStyle(buttonIsPrimary ? AnyButtonStyle(PrimaryControlButtonStyle()) : AnyButtonStyle(SecondaryControlButtonStyle()))
                .disabled(viewModel.modelPreparationState == .preparing)

                if viewModel.modelPreparationState == .preparing {
                    Text("Local download / warmup")
                        .font(DS.FontStyle.mono)
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                }
            }
        }
        .padding(DS.Space.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsPanelSurface(alt: true, cornerRadius: DS.Radius.md)
    }

    private var railMode: IndexRailMode {
        if let progress = viewModel.modelPreparationProgress, viewModel.modelPreparationState == .preparing || viewModel.modelPreparationState == .ready {
            return .progress(progress)
        }
        return .idleTicks
    }

    private var modelReadinessSummary: some View {
        VStack(alignment: .leading, spacing: DS.Space.x2) {
            Text(modelSummaryTitle)
                .font(DS.FontStyle.bodyStrong)
                .foregroundStyle(DS.ColorToken.fgPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(modelSummarySubtitle)
                .font(DS.FontStyle.helper)
                .foregroundStyle(DS.ColorToken.fgSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: DS.Space.x1_5) {
                modelInfoRow(label: "Last prepared", value: modelLastPreparedText)
                modelInfoRow(label: "Includes", value: modelCapabilitiesText)
                modelInfoRow(label: "Processing", value: modelProcessingModeText)
            }

            VStack(alignment: .leading, spacing: 4) {
                CapsLabel(text: "Technical details")
                Text(viewModel.modelPreparationDetailLine)
                    .font(DS.FontStyle.helper)
                    .foregroundStyle(DS.ColorToken.fgSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(viewModel.fluidAudioStatus)
                    .font(DS.FontStyle.mono)
                    .foregroundStyle(DS.ColorToken.fgTertiary)
                    .lineLimit(3)
            }
            .padding(.top, 2)
        }
        .padding(DS.Space.x2)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .fill(DS.ColorToken.bgPanelAlt)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .stroke(DS.ColorToken.borderSoft, lineWidth: 1)
        )
    }

    @ViewBuilder
    private func modelInfoRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.x2) {
            Text(label)
                .font(DS.FontStyle.helper)
                .foregroundStyle(DS.ColorToken.fgSecondary)
                .frame(width: 92, alignment: .leading)

            Text(value)
                .font(DS.FontStyle.helper)
                .foregroundStyle(DS.ColorToken.fgPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var modelSummaryTitle: String {
        switch viewModel.modelPreparationState {
        case .ready:
            return "Lorre is ready to transcribe on this Mac."
        case .preparing:
            return "Lorre is preparing the speech tools."
        case .error:
            return "Model setup needs attention."
        case .idle, .unknown:
            return "Models are not prepared yet."
        }
    }

    private var modelSummarySubtitle: String {
        switch viewModel.modelPreparationState {
        case .ready:
            return "You can record and transcribe locally. Audio stays on this device during processing."
        case .preparing:
            return "This may download and warm up models once, so future recordings start faster."
        case .error:
            return "Lorre could not finish model setup. You can try preparing the models again below."
        case .idle, .unknown:
            return "Prepare models once to speed up transcription and speaker recognition on this Mac."
        }
    }

    private var modelLastPreparedText: String {
        guard case .ready = viewModel.modelPreparationState else {
            return "Not prepared yet"
        }

        let prefix = "Last prepared "
        let parts = viewModel.modelPreparationDetailLine.split(separator: "•").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let first = parts.first, first.hasPrefix(prefix) {
            return String(first.dropFirst(prefix.count))
        }
        return "Ready"
    }

    private var modelCapabilitiesText: String {
        let normalized = Set(modelCapabilityLabels.map { $0.lowercased() })
        if normalized.isEmpty {
            return "Speech transcription"
        }
        return Array(normalized).sorted().map { normalizedLabel in
            modelCapabilityLabels.first(where: { $0.lowercased() == normalizedLabel }) ?? normalizedLabel
        }
        .joined(separator: " • ")
    }

    private var modelCapabilityLabels: [String] {
        let detail = viewModel.modelPreparationDetailLine.lowercased()
        let runtime = viewModel.fluidAudioStatus.lowercased()
        let combined = "\(detail) \(runtime)"

        var labels: [String] = []
        if combined.contains("asr") {
            labels.append("Speech-to-text")
        }
        if combined.contains("vad") || combined.contains("silero") {
            labels.append("Pause / silence detection")
        }
        if combined.contains("diar") {
            labels.append("Speaker recognition")
        }
        if combined.contains("parakeet") || combined.contains("stream") {
            labels.append("Live preview support")
        }
        return labels
    }

    private var modelProcessingModeText: String {
        let runtime = viewModel.fluidAudioStatus.lowercased()
        if runtime.contains("mock") {
            return "Test/demo processing pipeline is active (not the full production models)."
        }
        if runtime.contains("unavailable") {
            return "A fallback pipeline is active in this build. Some model features may be limited."
        }
        if runtime.contains("available") {
            return "Local processing is available on this Mac (no cloud upload required)."
        }
        return "Local processing status is available in the technical details below."
    }

    @ViewBuilder
    private func toggleSettingsRow<Description: View>(
        id: String,
        label: String,
        tooltip: String,
        isOn: Bool,
        setValue: @escaping (Bool) -> Void,
        @ViewBuilder description: () -> Description
    ) -> some View {
        HStack(alignment: .top, spacing: DS.Space.x2) {
            settingsLabelCell(id: id, label: label, tooltip: tooltip)

            InlineBooleanSettingControl(
                isOn: isOn,
                setValue: setValue
            )
            .frame(width: settingsToggleColumnWidth, alignment: .leading)

            description()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, DS.Space.x1)
        .zIndex(activeTooltipRowID == id ? 100 : 0)
    }

    private func settingsLabelCell(id: String, label: String, tooltip: String) -> some View {
        HStack(spacing: DS.Space.x1_5) {
            CapsLabel(text: label)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: settingsLabelTextColumnWidth, alignment: .leading)

            SettingsInfoTooltipIcon(message: tooltip) { isHovering in
                if isHovering {
                    activeTooltipRowID = id
                } else if activeTooltipRowID == id {
                    activeTooltipRowID = nil
                }
            }
            .frame(width: settingsTooltipColumnWidth, alignment: .center)
        }
        .frame(width: settingsLabelColumnWidth, alignment: .leading)
    }

    private var settingsLabelTextColumnWidth: CGFloat { 132 }
    private var settingsTooltipColumnWidth: CGFloat { 16 }
    private var settingsLabelColumnWidth: CGFloat { settingsLabelTextColumnWidth + settingsTooltipColumnWidth + DS.Space.x1_5 }
    private var settingsToggleColumnWidth: CGFloat { 110 }

    private var statusBadge: some View {
        let label: String
        switch viewModel.modelPreparationState {
        case .unknown, .idle:
            label = "IDLE"
        case .preparing:
            label = "PREPARING"
        case .ready:
            label = "READY"
        case .error:
            label = "ERROR"
        }

        return HStack(spacing: 6) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 6, height: 6)
            Text(label)
                .font(DS.FontStyle.control)
                .tracking(0.35)
                .foregroundStyle(DS.ColorToken.fgSecondary)
        }
        .padding(.horizontal, DS.Space.x3)
        .padding(.vertical, DS.Space.x2)
        .frame(minHeight: 32)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .fill(DS.ColorToken.bgPanelAlt)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .stroke(DS.ColorToken.borderStrong, lineWidth: 1)
        )
    }

    private var statusDotColor: Color {
        switch viewModel.modelPreparationState {
        case .ready:
            return DS.ColorToken.statusReady
        case .preparing:
            return DS.ColorToken.statusPreparing
        case .error:
            return DS.ColorToken.statusError
        case .idle, .unknown:
            return DS.ColorToken.statusIdle
        }
    }

    private var buttonLabel: String {
        switch viewModel.modelPreparationState {
        case .ready:
            return "Re-prepare Models"
        case .preparing:
            return "Preparing…"
        default:
            return "Prepare Models"
        }
    }

    private var buttonIsPrimary: Bool {
        switch viewModel.modelPreparationState {
        case .idle, .unknown, .error:
            return true
        case .preparing, .ready:
            return false
        }
    }
}

private struct InlineBooleanSettingControl: View {
    let isOn: Bool
    var isDisabled: Bool = false
    let setValue: (Bool) -> Void

    var body: some View {
        HStack(spacing: 2) {
            segment(title: "Off", selected: !isOn) { setValue(false) }
            segment(title: "On", selected: isOn) { setValue(true) }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .fill(DS.ColorToken.bgPanelAlt)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .stroke(DS.ColorToken.borderSoft, lineWidth: 1)
        )
        .opacity(isDisabled ? 0.55 : 1)
        .disabled(isDisabled)
    }

    private func segment(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DS.FontStyle.control)
                .foregroundStyle(selected ? DS.ColorToken.white : DS.ColorToken.fgPrimary)
                .frame(minWidth: 38)
                .padding(.horizontal, DS.Space.x2)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: max(6, DS.Radius.sm - 2), style: .continuous)
                        .fill(selected ? DS.ColorToken.black : .clear)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsInfoTooltipIcon: View {
    let message: String
    var onHoverChanged: ((Bool) -> Void)? = nil
    @State private var isShowingTooltip = false

    var body: some View {
        Image(systemName: "questionmark.circle")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(DS.ColorToken.fgTertiary)
            .frame(width: 16, height: 16, alignment: .center)
            .contentShape(Rectangle())
            .accessibilityLabel("More info")
            .accessibilityHint(message)
            #if os(macOS)
            .onHover { isHovering in
                isShowingTooltip = isHovering
                onHoverChanged?(isHovering)
            }
            #endif
            .popover(isPresented: $isShowingTooltip, arrowEdge: .bottom) {
                tooltipBubble
                    .padding(DS.Space.x2)
                    .frame(width: 300, alignment: .leading)
                    .background(DS.ColorToken.bgPanel)
            }
            .zIndex(isShowingTooltip ? 100 : 0)
    }

    private var tooltipBubble: some View {
        Text(message)
            .font(DS.FontStyle.helper)
            .foregroundStyle(DS.ColorToken.fgPrimary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Space.x2)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(DS.ColorToken.bgPanelAlt)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .stroke(DS.ColorToken.borderStrong, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
    }
}

private struct AnyButtonStyle: ButtonStyle {
    private let makeBodyClosure: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        self.makeBodyClosure = { configuration in
            AnyView(style.makeBody(configuration: configuration))
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        makeBodyClosure(configuration)
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
    let onSelectSession: (SessionManifest) -> Void
    let onRevealSession: (SessionManifest) -> Void
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
                        Button("Reveal Files") {
                            onRevealSession(session)
                        }

                        Button("Rename…") {
                            onRenameSession(session)
                        }

                        Button("Delete…", role: .destructive) {
                            onDeleteSession(session)
                        }

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
