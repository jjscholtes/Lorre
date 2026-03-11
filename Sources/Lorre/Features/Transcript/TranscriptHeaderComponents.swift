import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

private enum TranscriptKeyboardAction {
    case togglePlayPause
    case pause
    case seekBackward
    case seekForward
    case export
    case deleteSession
}

private struct TranscriptKeyboardShortcutMonitor: View {
    let onAction: (TranscriptKeyboardAction) -> Void

    var body: some View {
        #if canImport(AppKit)
        TranscriptKeyboardShortcutBridge(onAction: onAction)
            .frame(width: 0, height: 0)
        #else
        EmptyView()
        #endif
    }
}

#if canImport(AppKit)
private struct TranscriptKeyboardShortcutBridge: NSViewRepresentable {
    let onAction: (TranscriptKeyboardAction) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onAction: onAction)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.installIfNeeded()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onAction = onAction
        context.coordinator.installIfNeeded()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.remove()
    }

    final class Coordinator {
        var onAction: (TranscriptKeyboardAction) -> Void
        private var monitor: Any?

        init(onAction: @escaping (TranscriptKeyboardAction) -> Void) {
            self.onAction = onAction
        }

        func installIfNeeded() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let isEditingText = MainActor.assumeIsolated { Self.isEditingText }
                guard !isEditingText else { return event }
                guard let action = Self.map(event) else { return event }
                self.onAction(action)
                return nil
            }
        }

        func remove() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        @MainActor
        private static var isEditingText: Bool {
            guard let responder = NSApp.keyWindow?.firstResponder else { return false }
            if let textView = responder as? NSTextView {
                return textView.isEditable
            }
            return responder is NSTextField
        }

        private static func map(_ event: NSEvent) -> TranscriptKeyboardAction? {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let normalizedFlags = flags.subtracting([.capsLock, .numericPad, .help, .function])
            let chars = (event.charactersIgnoringModifiers ?? "").lowercased()

            if normalizedFlags == [.command], chars == "e" {
                return .export
            }

            let unmodified = normalizedFlags.isEmpty || normalizedFlags == [.shift]
            guard unmodified else { return nil }

            switch event.keyCode {
            case 49: return .togglePlayPause // space
            case 51, 117: return .deleteSession // delete / forward delete
            default: break
            }

            switch chars {
            case "j": return .seekBackward
            case "k": return .pause
            case "l": return .seekForward
            default: return nil
            }
        }
    }
}
#endif

struct TranscriptHeaderView: View {
    @ObservedObject var viewModel: AppViewModel
    let session: SessionManifest
    let transcript: TranscriptDocument?
    @State private var isShowingRenameAlert = false
    @State private var isShowingDeleteConfirmation = false
    @State private var isShowingNotesSheet = false
    @State private var renameDraft = ""
    @State private var notesDraft = ""
    @State private var scrubberDraftSeconds: Double?
    @State private var resumePlaybackAfterScrub = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x3) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: DS.Space.x4) {
                    headerSummary
                    Spacer(minLength: DS.Space.x2)
                    actionBarWide
                }

                VStack(alignment: .leading, spacing: DS.Space.x3) {
                    headerSummary
                    actionBarCompact
                }
            }

            if viewModel.canControlPlayback {
                playbackPanel
            }

            if let exportMessage = viewModel.exportMessage {
                HStack(spacing: DS.Space.x2) {
                    CapsLabel(text: "Export")
                    Text(exportMessage)
                        .font(DS.FontStyle.helper)
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                }
            }
        }
        .padding(DS.Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsPanelSurface(cornerRadius: DS.Radius.lg)
        .background(
            TranscriptKeyboardShortcutMonitor { action in
                handleKeyboardShortcut(action)
            }
        )
        .onAppear {
            syncNotesDraftFromSession()
        }
        .onChange(of: session.id) { _, _ in
            syncNotesDraftFromSession()
        }
        .onChange(of: session.notes) { _, _ in
            if !isShowingNotesSheet {
                syncNotesDraftFromSession()
            }
        }
        .alert("Rename Recording", isPresented: $isShowingRenameAlert) {
            TextField("Recording name", text: $renameDraft)
            Button("Save") {
                viewModel.renameSelectedSession(to: renameDraft)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Choose a clearer session name for the transcript and exports.")
        }
        .confirmationDialog("Delete this session?", isPresented: $isShowingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete Session", role: .destructive) {
                viewModel.deleteSelectedSessionConfirmed()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the session audio, transcript, and local exports from Lorre storage.")
        }
        .sheet(isPresented: $isShowingNotesSheet) {
            SessionNotesSheet(
                title: session.displayTitle,
                notes: $notesDraft,
                hasSavedNotes: !session.normalizedNotes.isEmpty,
                onSave: {
                    viewModel.saveSelectedSessionNotes(notesDraft)
                },
                onClear: {
                    notesDraft = ""
                    viewModel.saveSelectedSessionNotes("")
                }
            )
        }
    }

    private var headerSummary: some View {
        VStack(alignment: .leading, spacing: DS.Space.x2) {
            Text(session.displayTitle)
                .font(DS.FontStyle.appTitle)
                .foregroundStyle(DS.ColorToken.fgPrimary)

            Text(
                Formatters.sessionMetadata(
                    date: session.recordedAt ?? session.createdAt,
                    durationSeconds: session.durationSeconds
                )
            )
            .font(DS.FontStyle.mono)
            .foregroundStyle(DS.ColorToken.fgSecondary)

            HStack(spacing: DS.Space.x2) {
                CapsLabel(text: "Folder")
                Button {
                    viewModel.openFolderForSelectedSession()
                } label: {
                    HStack(spacing: DS.Space.x1) {
                        Image(systemName: "folder")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DS.ColorToken.fgSecondary)
                        Text(viewModel.folderName(for: session.folderId))
                            .font(DS.FontStyle.helper)
                            .foregroundStyle(DS.ColorToken.fgSecondary)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, DS.Space.x2)
                    .padding(.vertical, DS.Space.x1)
                    .dsPanelSurface(alt: true, cornerRadius: DS.Radius.sm)
                }
                .buttonStyle(.plain)
                .help("Show this folder in the session shelf")
            }

            if let audioDeletedAt = session.audioDeletedAt {
                HStack(alignment: .top, spacing: DS.Space.x2) {
                    CapsLabel(text: "Privacy")
                    Text("Source audio deleted on \(audioDeletedAt.formatted(date: .abbreviated, time: .shortened)). Playback and waveform review are unavailable for this session.")
                        .font(DS.FontStyle.helper)
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let transcript {
                IndexRailView(
                    mode: .speakerSummary(viewModel.speakerSummaryBins(for: transcript)),
                    height: 8
                )
            } else {
                IndexRailView(mode: .idleTicks, height: 8)
            }
        }
    }

    private var playbackPanel: some View {
        VStack(alignment: .leading, spacing: DS.Space.x2) {
            HStack(spacing: DS.Space.x2) {
                CapsLabel(text: "Transport")
                Text(scrubberTimeLine)
                    .font(DS.FontStyle.mono)
                    .foregroundStyle(DS.ColorToken.fgSecondary)
                if viewModel.isAudioPlaying {
                    CapsLabel(text: "Playing")
                }
                if viewModel.isPlaybackWaveformLoading {
                    Text("Analyzing waveform…")
                        .font(DS.FontStyle.helper)
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                }
                Spacer(minLength: 0)
                noteIconControl
            }

            VStack(alignment: .leading, spacing: DS.Space.x2) {
                if viewModel.playbackWaveformBins.isEmpty {
                    IndexRailView(mode: .progress(viewModel.playbackProgressFraction), height: 8)
                        .frame(maxWidth: .infinity)
                } else {
                    WaveformStripView(
                        bins: viewModel.playbackWaveformBins,
                        progress: viewModel.playbackProgressFraction
                    )
                    .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30)
                }

                Slider(
                    value: Binding(
                        get: {
                            scrubberDraftSeconds ?? viewModel.playbackCurrentSeconds
                        },
                        set: { scrubberDraftSeconds = $0 }
                    ),
                    in: 0...max(viewModel.playbackDurationSeconds, 0.001),
                    onEditingChanged: handleScrubberEditingChanged
                )
                .tint(DS.ColorToken.fgPrimary)

                playbackTransportStrip
            }
            .padding(DS.Space.x2)
            .dsPanelSurface(alt: true, cornerRadius: DS.Radius.sm)
        }
    }

    private var actionBarWide: some View {
        HStack(spacing: DS.Space.x2) {
            moveToFolderControl
            revealFilesControl
            renameControl
            deleteControl
            if !viewModel.canControlPlayback {
                noteIconControl
            }
            exportControl
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var actionBarCompact: some View {
        VStack(alignment: .leading, spacing: DS.Space.x2) {
            HStack(spacing: DS.Space.x2) {
                moveToFolderControl
                if !viewModel.canControlPlayback {
                    noteIconControl
                }
                exportControl
            }
            HStack(spacing: DS.Space.x2) {
                revealFilesControl
                renameControl
                deleteControl
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var playbackTransportStrip: some View {
        VStack(alignment: .leading, spacing: DS.Space.x1_5) {
            HStack(spacing: DS.Space.x2) {
                HStack(spacing: DS.Space.x1) {
                    transportJumpButton(label: "-5", systemImage: "gobackward.5") {
                        viewModel.seekSelectedSessionPlaybackBy(deltaSeconds: -5)
                    }
                    playPauseControl
                    stopControl
                    transportJumpButton(label: "+5", systemImage: "goforward.5") {
                        viewModel.seekSelectedSessionPlaybackBy(deltaSeconds: 5)
                    }
                }
                .padding(DS.Space.x1)
                .dsPanelSurface(alt: true, cornerRadius: DS.Radius.sm)

                playbackSpeedControl
            }
        }
    }

    @ViewBuilder
    private func transportJumpButton(
        label: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
            }
            .frame(minWidth: 44)
        }
        .buttonStyle(SecondaryControlButtonStyle())
        .disabled(!viewModel.canControlPlayback)
    }

    private var playPauseControl: some View {
        Button {
            viewModel.toggleSelectedSessionPlayback()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: viewModel.isAudioPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(viewModel.isAudioPlaying ? "Pause" : "Play")
            }
            .frame(minWidth: 62)
        }
        .buttonStyle(PrimaryControlButtonStyle())
        .disabled(!viewModel.canControlPlayback)
    }

    private var stopControl: some View {
        Button {
            viewModel.stopSelectedSessionPlayback()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 9, weight: .semibold))
                Text("Stop")
            }
            .frame(minWidth: 56)
        }
        .buttonStyle(SecondaryControlButtonStyle())
        .disabled(!viewModel.canControlPlayback || (!viewModel.isAudioPlaying && viewModel.playbackCurrentSeconds <= 0))
    }

    private var playbackSpeedControl: some View {
        Menu {
            Button("0.75x") { viewModel.setPlaybackRate(0.75) }
            Button("1.0x") { viewModel.setPlaybackRate(1.0) }
            Button("1.25x") { viewModel.setPlaybackRate(1.25) }
            Button("1.5x") { viewModel.setPlaybackRate(1.5) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "speedometer")
                    .font(.system(size: 10, weight: .semibold))
                Text(viewModel.playbackRateLabel)
            }
            .frame(minWidth: 68)
        }
        .buttonStyle(SecondaryControlButtonStyle())
        .disabled(!viewModel.canControlPlayback)
    }

    private var moveToFolderControl: some View {
        Menu {
            Button("Unfiled") {
                viewModel.moveSelectedSessionToFolder(nil)
            }
            Divider()
            ForEach(viewModel.folders) { folder in
                Button(folder.name) {
                    viewModel.moveSelectedSessionToFolder(folder.id)
                }
            }
        } label: {
            Text("Move to Folder")
        }
        .buttonStyle(SecondaryControlButtonStyle())
    }

    private var revealFilesControl: some View {
        Button("Reveal Files") {
            viewModel.revealSelectedSessionFiles()
        }
        .buttonStyle(SecondaryControlButtonStyle())
        .disabled(viewModel.selectedSession == nil)
    }

    private var noteIconControl: some View {
        Button {
            syncNotesDraftFromSession()
            isShowingNotesSheet = true
        } label: {
            HStack(spacing: 5) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DS.ColorToken.fgPrimary)
                        .frame(width: 15, height: 15)

                    if !session.normalizedNotes.isEmpty {
                        Circle()
                            .fill(DS.ColorToken.black)
                            .frame(width: 5, height: 5)
                            .offset(x: 3, y: -3)
                    }
                }

                Text("Note")
                    .font(DS.FontStyle.control)
                    .foregroundStyle(DS.ColorToken.fgPrimary)
            }
            .padding(.horizontal, DS.Space.x2)
            .padding(.vertical, DS.Space.x1)
            .dsPanelSurface(alt: true, cornerRadius: DS.Radius.sm)
        }
        .buttonStyle(.plain)
        .help(session.normalizedNotes.isEmpty ? "Add session note" : "Edit session note")
    }

    private var renameControl: some View {
        Button("Rename") {
            renameDraft = session.displayTitle
            isShowingRenameAlert = true
        }
        .buttonStyle(SecondaryControlButtonStyle())
    }

    private var deleteControl: some View {
        Button("Delete") {
            isShowingDeleteConfirmation = true
        }
        .buttonStyle(SecondaryControlButtonStyle())
    }

    private var exportControl: some View {
        Menu {
            Button("Markdown…") {
                viewModel.exportSelectedSession(format: .markdown)
            }
            Button("Plain Text…") {
                viewModel.exportSelectedSession(format: .plainText)
            }
            Button("JSON…") {
                viewModel.exportSelectedSession(format: .json)
            }
        } label: {
            Text("Export")
        }
        .buttonStyle(PrimaryControlButtonStyle())
        .disabled(transcript == nil || session.status != .ready)
    }

    private var scrubberTimeLine: String {
        if let scrubberDraftSeconds {
            return "\(Formatters.duration(scrubberDraftSeconds)) / \(Formatters.duration(viewModel.playbackDurationSeconds))"
        }
        return viewModel.playbackTimeLine
    }

    private func handleScrubberEditingChanged(_ isEditing: Bool) {
        if isEditing {
            resumePlaybackAfterScrub = viewModel.isAudioPlaying
            if viewModel.isAudioPlaying {
                viewModel.pauseSelectedSessionPlayback()
            }
            return
        }

        let target = scrubberDraftSeconds ?? viewModel.playbackCurrentSeconds
        scrubberDraftSeconds = nil
        viewModel.seekSelectedSessionPlayback(toSeconds: target, autoplay: resumePlaybackAfterScrub)
        resumePlaybackAfterScrub = false
    }

    private func handleKeyboardShortcut(_ action: TranscriptKeyboardAction) {
        switch action {
        case .togglePlayPause:
            viewModel.toggleSelectedSessionPlayback()
        case .pause:
            viewModel.pauseSelectedSessionPlayback()
        case .seekBackward:
            viewModel.seekSelectedSessionPlaybackBy(deltaSeconds: -5)
        case .seekForward:
            viewModel.seekSelectedSessionPlaybackBy(deltaSeconds: 5)
        case .export:
            viewModel.exportSelectedSessionWithDefaultShortcut()
        case .deleteSession:
            isShowingDeleteConfirmation = true
        }
    }

    private func syncNotesDraftFromSession() {
        notesDraft = session.notes ?? ""
    }
}

private struct SessionNotesSheet: View {
    let title: String
    @Binding var notes: String
    let hasSavedNotes: Bool
    let onSave: () -> Void
    let onClear: () -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isNotesFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x3) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.x2) {
                VStack(alignment: .leading, spacing: DS.Space.x1) {
                    CapsLabel(text: "Session Note")
                    Text(title)
                        .font(DS.FontStyle.bodyStrong)
                        .foregroundStyle(DS.ColorToken.fgPrimary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(SecondaryControlButtonStyle())
            }

            Text("Private note for this session. Stored locally with the recording metadata.")
                .font(DS.FontStyle.helper)
                .foregroundStyle(DS.ColorToken.fgSecondary)

            TextEditor(text: $notes)
                .font(DS.FontStyle.body)
                .foregroundStyle(DS.ColorToken.fgPrimary)
                .scrollContentBackground(.hidden)
                .focused($isNotesFocused)
                .padding(DS.Space.x2)
                .frame(minHeight: 180)
                .background(DS.ColorToken.fieldBg)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                        .stroke(isNotesFocused ? DS.ColorToken.borderStrong : DS.ColorToken.borderSoft, lineWidth: 1)
                )
                .dsPanelSurface(alt: true, cornerRadius: DS.Radius.sm)

            HStack(spacing: DS.Space.x2) {
                Button("Save Note") {
                    onSave()
                    dismiss()
                }
                    .buttonStyle(PrimaryControlButtonStyle())

                Button("Clear Note") { onClear() }
                    .buttonStyle(SecondaryControlButtonStyle())
                    .disabled((notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) && !hasSavedNotes)

                Spacer()
            }
        }
        .padding(DS.Space.x4)
        .frame(minWidth: 520, minHeight: 320)
        .background(DS.ColorToken.bgApp)
    }
}

private struct WaveformStripView: View {
    let bins: [Double]
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            let count = max(1, bins.count)
            let gap: CGFloat = 1
            let totalGap = gap * CGFloat(max(0, count - 1))
            let barWidth = max(1, (proxy.size.width - totalGap) / CGFloat(count))

            HStack(alignment: .center, spacing: gap) {
                ForEach(Array(bins.enumerated()), id: \.offset) { index, rawValue in
                    let value = min(max(rawValue, 0.05), 1.0)
                    let barHeight = max(3, proxy.size.height * CGFloat(value))
                    let isPlayed = Double(index + 1) / Double(count) <= progress

                    RoundedRectangle(cornerRadius: min(2, barWidth / 2), style: .continuous)
                        .fill(isPlayed ? DS.ColorToken.fgPrimary : DS.ColorToken.borderStrong)
                        .frame(width: barWidth, height: barHeight)
                        .frame(maxHeight: .infinity, alignment: .center)
                        .opacity(isPlayed ? 1.0 : 0.85)
                }
            }
            .padding(.horizontal, 1)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(DS.ColorToken.bgPanelAlt)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .stroke(DS.ColorToken.borderSoft, lineWidth: 1)
            )
        }
    }
}

struct TranscriptErrorStateView: View {
    @ObservedObject var viewModel: AppViewModel
    let session: SessionManifest

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x3) {
            CapsLabel(text: "Error")
            Text("Transcript could not be prepared")
                .font(DS.FontStyle.panelTitle)
                .foregroundStyle(DS.ColorToken.fgPrimary)
            Text(session.lastErrorMessage ?? "Unknown processing error.")
                .font(DS.FontStyle.body)
                .foregroundStyle(DS.ColorToken.fgSecondary)
            IndexRailView(mode: .progress(0), height: 8)
            HStack(spacing: DS.Space.x2) {
                Button("Retry Processing") {
                    viewModel.retryProcessingSelectedSession()
                }
                .buttonStyle(SecondaryControlButtonStyle())

                Button("Delete (Later)") {}
                    .buttonStyle(SecondaryControlButtonStyle())
                    .disabled(true)
            }
        }
        .padding(DS.Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsPanelSurface(cornerRadius: DS.Radius.lg)
    }
}
