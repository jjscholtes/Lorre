import SwiftUI

struct RecorderConsoleView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var isShowingCancelRecordingConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x4) {
            if !(viewModel.isRecording || viewModel.isStoppingRecording) {
                StageHeaderCard(
                    title: "Record",
                    statusLine: viewModel.visibleStageStatusLine,
                    rail: .live(viewModel.isRecording ? viewModel.liveMeterSamples : []),
                    trailingActions: {
                        EmptyView()
                    }
                )
            }

            VStack(alignment: .leading, spacing: DS.Space.x4) {
                if viewModel.isRecording || viewModel.isStoppingRecording {
                    HStack(alignment: .center, spacing: DS.Space.x4) {
                        VStack(alignment: .leading, spacing: DS.Space.x1) {
                            CapsLabel(text: "Record")
                            Text(viewModel.isStoppingRecording ? "Stopping…" : "Recording \(viewModel.selectedRecordingSource.label)")
                                .font(DS.FontStyle.panelTitle)
                                .foregroundStyle(DS.ColorToken.fgPrimary)
                        }

                        Spacer()

                        Text(Formatters.duration(viewModel.recordingElapsedSeconds))
                            .font(DS.FontStyle.timer)
                            .foregroundStyle(DS.ColorToken.fgPrimary)
                    }

                    Text("Audio capture is stored locally. Stop to create a session and begin transcript processing.")
                        .font(DS.FontStyle.body)
                        .foregroundStyle(DS.ColorToken.fgSecondary)

                    if viewModel.isDeleteAudioAfterTranscriptionEnabled {
                        Text("Privacy mode is on. After the transcript is saved, Lorre will delete the source audio and keep the transcript and exports.")
                            .font(DS.FontStyle.helper)
                            .foregroundStyle(DS.ColorToken.fgSecondary)
                    }

                    IndexRailView(
                        mode: .live(viewModel.liveMeterSamples),
                        height: 24
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DS.Space.x2)

                    if viewModel.isLiveTranscriptionSupported && viewModel.isLiveTranscriptionEnabled {
                        LiveTranscriptPreviewCard(viewModel: viewModel)
                    }

                    HStack(spacing: DS.Space.x2) {
                        Button("Stop Recording") {
                            viewModel.stopRecordingTapped()
                        }
                        .buttonStyle(PrimaryControlButtonStyle())
                        .disabled(viewModel.isStoppingRecording)

                        Button("Cancel Recording") {
                            isShowingCancelRecordingConfirmation = true
                        }
                            .buttonStyle(SecondaryControlButtonStyle())
                            .disabled(viewModel.isStoppingRecording)
                    }
                } else {
                    VStack(alignment: .leading, spacing: DS.Space.x3) {
                        CapsLabel(text: "Recording Setup")
                        Text("Set your recording options before you start recording.")
                            .font(DS.FontStyle.panelTitle)
                            .foregroundStyle(DS.ColorToken.fgPrimary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(setupDescription)
                            .font(DS.FontStyle.body)
                            .foregroundStyle(DS.ColorToken.fgSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if viewModel.isLiveTranscriptionSupported && viewModel.isLiveTranscriptionEnabled {
                            Text("Live preview is enabled: new recordings show an English-only partial preview while recording, then run a multilingual v3 post-pass after stop.")
                                .font(DS.FontStyle.helper)
                                .foregroundStyle(DS.ColorToken.fgSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        IndexRailView(mode: .idleTicks, height: 9)
                            .frame(maxWidth: .infinity)
                    }
                }

                RecorderSourceQuickAccessView(viewModel: viewModel)

                SpeakerRecognitionQuickAccessView(
                    viewModel: viewModel,
                    scopeNote: "Changes here apply when the next recording or imported audio is processed."
                )

                RecorderLivePreviewQuickAccessView(viewModel: viewModel)
                RecorderPrivacyQuickAccessView(viewModel: viewModel)

                if !(viewModel.isRecording || viewModel.isStoppingRecording) {
                    RecorderStartActionButton(
                        recordingSource: viewModel.selectedRecordingSource,
                        isSpeakerRecognitionEnabled: viewModel.isSpeakerDiarizationEnabled,
                        isLivePreviewSupported: viewModel.isLiveTranscriptionSupported,
                        isLivePreviewEnabled: viewModel.isLiveTranscriptionEnabled,
                        isDisabled: viewModel.isStoppingRecording
                    ) {
                        viewModel.startRecordingTapped()
                    }
                }
            }
            .padding(DS.Space.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsPanelSurface(cornerRadius: DS.Radius.lg)

            Spacer(minLength: 0)
        }
        .confirmationDialog(
            "Cancel this recording?",
            isPresented: $isShowingCancelRecordingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete In-Progress Session", role: .destructive) {
                viewModel.cancelRecordingTapped()
            }
            Button("Keep Recording", role: .cancel) {}
        } message: {
            Text("This will stop recording immediately. The in-progress session and audio will be deleted.")
        }
    }

    private var setupDescription: String {
        switch viewModel.selectedRecordingSource {
        case .microphone:
            return "Audio stays local. Record your microphone, then review the transcript, assign speakers, and export from the same workspace."
        case .systemAudio:
            return "Audio stays local. Capture the selected app, window, or display audio, then review and export from the same workspace."
        case .microphoneAndSystemAudio:
            return "Audio stays local. Capture your microphone plus the selected app, window, or display audio. Lorre stores separate stems and a mixed track for review."
        }
    }
}

private struct RecorderStartActionButton: View {
    let recordingSource: RecordingSource
    let isSpeakerRecognitionEnabled: Bool
    let isLivePreviewSupported: Bool
    let isLivePreviewEnabled: Bool
    let isDisabled: Bool
    let onStart: () -> Void

    var body: some View {
        Button(action: onStart) {
            HStack(alignment: .center, spacing: DS.Space.x2_5) {
                recordIndicator

                Text("Start Recording")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(primaryTextColor)

                Spacer(minLength: DS.Space.x2)

                modeChip

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(secondaryTextColor)
            }
            .frame(minWidth: 300, idealWidth: 380, maxWidth: 460, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(RecorderStartActionButtonStyle())
        .disabled(isDisabled)
        .accessibilityHint("Starts \(recordingSource.label.lowercased()) recording using the selected speaker recognition and live preview settings")
    }

    private var primaryTextColor: Color {
        isDisabled ? DS.ColorToken.fgSecondary : DS.ColorToken.white
    }

    private var secondaryTextColor: Color {
        isDisabled ? DS.ColorToken.fgTertiary : DS.ColorToken.white.opacity(0.76)
    }

    private var modeSummary: String {
        let source = recordingSource.shortLabel
        let speaker = isSpeakerRecognitionEnabled ? "Spk On" : "Spk Off"
        let live: String
        if !isLivePreviewSupported {
            live = "Live N/A"
        } else if isLivePreviewEnabled {
            live = "Live EN"
        } else {
            live = "Live Off"
        }
        return "\(source) • \(speaker) • \(live)"
    }

    private var modeChip: some View {
        Text(modeSummary)
            .font(DS.FontStyle.mono)
            .foregroundStyle(secondaryTextColor)
            .lineLimit(1)
            .padding(.horizontal, DS.Space.x2)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(
                        isDisabled
                            ? DS.ColorToken.bgPanel
                            : DS.ColorToken.white.opacity(0.06)
                    )
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(
                        isDisabled
                            ? DS.ColorToken.borderStrong
                            : DS.ColorToken.white.opacity(0.14),
                        lineWidth: 1
                    )
            )
    }

    private var recordIndicator: some View {
        ZStack {
            Circle()
                .stroke(indicatorStroke, lineWidth: 1)
                .frame(width: 20, height: 20)

            Circle()
                .fill(indicatorFill)
                .frame(width: 7, height: 7)
        }
        .frame(width: 20, height: 20)
    }

    private var indicatorStroke: Color {
        isDisabled ? DS.ColorToken.borderStrong : DS.ColorToken.white.opacity(0.34)
    }

    private var indicatorFill: Color {
        isDisabled ? DS.ColorToken.fgSecondary : DS.ColorToken.white
    }
}

private struct RecorderSourceQuickAccessView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x2) {
            HStack(spacing: DS.Space.x2) {
                CapsLabel(text: "Source")
                Text(viewModel.selectedRecordingSource.shortLabel.uppercased())
                    .font(DS.FontStyle.control)
                    .foregroundStyle(DS.ColorToken.fgSecondary)
            }

            Text(sourceDescription)
                .font(DS.FontStyle.helper)
                .foregroundStyle(DS.ColorToken.fgSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DS.Space.x2) {
                ForEach(RecordingSource.allCases) { source in
                    Button(source.label) {
                        viewModel.setRecordingSource(source)
                    }
                    .buttonStyle(RecorderSourceOptionButtonStyle(isSelected: viewModel.selectedRecordingSource == source))
                    .disabled(isLockedDuringCapture)
                }
            }

            if isLockedDuringCapture {
                Text("Finish or cancel the current recording to change the source.")
                    .font(DS.FontStyle.helper)
                    .foregroundStyle(DS.ColorToken.fgTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Space.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsPanelSurface(alt: true, cornerRadius: DS.Radius.md)
    }

    private var isLockedDuringCapture: Bool {
        viewModel.isRecording || viewModel.isStoppingRecording
    }

    private var sourceDescription: String {
        switch viewModel.selectedRecordingSource {
        case .microphone:
            return "Records your microphone only."
        case .systemAudio:
            return "Uses the native ScreenCaptureKit picker to capture system audio from a selected app, window, or display."
        case .microphoneAndSystemAudio:
            return "Captures your microphone and the selected app, window, or display audio together. Lorre stores separate stems and a mixed session track."
        }
    }
}

private struct RecorderSourceOptionButtonStyle: PrimitiveButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label
                .font(DS.FontStyle.control)
                .foregroundStyle(isSelected ? DS.ColorToken.white : DS.ColorToken.fgPrimary)
                .padding(.horizontal, DS.Space.x2_5)
                .padding(.vertical, DS.Space.x1_5)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                        .fill(isSelected ? DS.ColorToken.black : DS.ColorToken.bgPanel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                        .stroke(
                            isSelected ? DS.ColorToken.white.opacity(0.12) : DS.ColorToken.borderStrong,
                            lineWidth: 1
                        )
                )
        }
    }
}

private struct RecorderStartActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && isEnabled

        configuration.label
            .padding(.horizontal, DS.Space.x3)
            .padding(.vertical, DS.Space.x2)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .fill(
                        isEnabled
                            ? DS.ColorToken.black.opacity(pressed ? 0.92 : 1)
                            : DS.ColorToken.bgPanelAlt
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .stroke(
                        isEnabled
                            ? DS.ColorToken.white.opacity(0.08)
                            : DS.ColorToken.borderStrong,
                        lineWidth: 1
                    )
            )
            .opacity(isEnabled ? 1 : 0.95)
    }
}

private struct LiveTranscriptPreviewCard: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x2) {
            HStack(spacing: DS.Space.x2) {
                CapsLabel(text: "Live Preview")
                if let preview = viewModel.liveTranscriptPreview, preview.isFinalizing {
                    Text("FINALIZING")
                        .font(DS.FontStyle.control)
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                } else {
                    Text("BETA")
                        .font(DS.FontStyle.control)
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                }
            }

            if let preview = viewModel.liveTranscriptPreview, let error = preview.errorMessage {
                Text(error)
                    .font(DS.FontStyle.helper)
                    .foregroundStyle(DS.ColorToken.fgSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let preview = viewModel.liveTranscriptPreview, preview.hasContent || preview.hasSpeakerHint {
                if preview.hasSpeakerHint {
                    HStack(spacing: DS.Space.x2) {
                        Image(systemName: "person.wave.2")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DS.ColorToken.fgSecondary)
                        Text(preview.activeSpeakerDisplayName ?? "Known speaker")
                            .font(DS.FontStyle.bodyStrong)
                            .foregroundStyle(DS.ColorToken.fgPrimary)
                        if let confidence = preview.activeSpeakerConfidence {
                            Text("\(Int((confidence * 100).rounded()))%")
                                .font(DS.FontStyle.mono)
                                .foregroundStyle(DS.ColorToken.fgTertiary)
                        }
                    }
                }

                if !preview.confirmedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(preview.confirmedText)
                        .font(DS.FontStyle.body)
                        .foregroundStyle(DS.ColorToken.fgPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !preview.partialText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(preview.partialText)
                        .font(DS.FontStyle.body)
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                        .italic()
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Listening for speech… partial transcript will appear here while recording.")
                    .font(DS.FontStyle.helper)
                    .foregroundStyle(DS.ColorToken.fgSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Live preview is English-only. Final post-pass (Parakeet v3) usually performs better for Dutch + English.")
                .font(DS.FontStyle.helper)
                .foregroundStyle(DS.ColorToken.fgTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsPanelSurface(alt: true, cornerRadius: DS.Radius.md)
    }
}

private struct RecorderLivePreviewQuickAccessView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x2) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: DS.Space.x2) {
                    titleRow
                    toggleControl
                }

                VStack(alignment: .leading, spacing: DS.Space.x2) {
                    titleRow
                    toggleControl
                }
            }

            Text(statusDescription)
                .font(DS.FontStyle.helper)
                .foregroundStyle(DS.ColorToken.fgSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if isLockedDuringCapture {
                Text("You can change this before you start recording, or after you stop.")
                    .font(DS.FontStyle.helper)
                    .foregroundStyle(DS.ColorToken.fgTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Space.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsPanelSurface(alt: true, cornerRadius: DS.Radius.md)
    }

    private var titleRow: some View {
        HStack(spacing: DS.Space.x2) {
            CapsLabel(text: "Live Preview")
            Text(viewModel.isLiveTranscriptionEnabled ? "ON" : "OFF")
                .font(DS.FontStyle.control)
                .foregroundStyle(DS.ColorToken.fgSecondary)
        }
    }

    private var toggleControl: some View {
        Toggle(
            "Enable English-only live transcript preview while recording",
            isOn: Binding(
                get: { viewModel.isLiveTranscriptionEnabled },
                set: { viewModel.setLiveTranscriptionEnabled($0) }
            )
        )
        .labelsHidden()
        .accessibilityLabel("Enable English-only live transcript preview while recording")
        .toggleStyle(.switch)
        .tint(DS.ColorToken.fgPrimary)
        .disabled(isToggleDisabled)
        .help(toggleHelpText)
    }

    private var isLockedDuringCapture: Bool {
        viewModel.isRecording || viewModel.isStoppingRecording
    }

    private var isToggleDisabled: Bool {
        !viewModel.isLiveTranscriptionSupported || isLockedDuringCapture
    }

    private var toggleHelpText: String {
        if !viewModel.isLiveTranscriptionSupported {
            return "Live preview is unavailable in this build"
        }
        if isLockedDuringCapture {
            return "Finish or cancel the current recording to change live preview"
        }
        return "Show an English-only live transcript preview while recording"
    }

    private var statusDescription: String {
        if !viewModel.isLiveTranscriptionSupported {
            return "English-only Live Preview is not available in this build. Your recording will still be transcribed after you stop."
        }
        if viewModel.isLiveTranscriptionEnabled {
            return "Shows a live transcript while recording (English only). After you stop, Lorre runs the full final transcript."
        }
        return "English-only Live Preview is off. Lorre will transcribe the audio after you stop."
    }
}

private struct RecorderPrivacyQuickAccessView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x2) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: DS.Space.x2) {
                    titleRow
                    toggleControl
                }

                VStack(alignment: .leading, spacing: DS.Space.x2) {
                    titleRow
                    toggleControl
                }
            }

            Text(statusDescription)
                .font(DS.FontStyle.helper)
                .foregroundStyle(DS.ColorToken.fgSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if isLockedDuringCapture {
                Text("Finish or cancel the current recording to change this privacy setting.")
                    .font(DS.FontStyle.helper)
                    .foregroundStyle(DS.ColorToken.fgTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(DS.Space.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsPanelSurface(alt: true, cornerRadius: DS.Radius.md)
    }

    private var titleRow: some View {
        HStack(spacing: DS.Space.x2) {
            CapsLabel(text: "Privacy")
            Text(viewModel.isDeleteAudioAfterTranscriptionEnabled ? "DELETE AUDIO" : "KEEP AUDIO")
                .font(DS.FontStyle.control)
                .foregroundStyle(DS.ColorToken.fgSecondary)
        }
    }

    private var toggleControl: some View {
        Toggle(
            "Delete source audio after the transcript is saved",
            isOn: Binding(
                get: { viewModel.isDeleteAudioAfterTranscriptionEnabled },
                set: { viewModel.setDeleteAudioAfterTranscriptionEnabled($0) }
            )
        )
        .labelsHidden()
        .accessibilityLabel("Delete source audio after the transcript is saved")
        .toggleStyle(.switch)
        .tint(DS.ColorToken.fgPrimary)
        .disabled(isLockedDuringCapture)
        .help(toggleHelpText)
    }

    private var isLockedDuringCapture: Bool {
        viewModel.isRecording || viewModel.isStoppingRecording
    }

    private var toggleHelpText: String {
        if isLockedDuringCapture {
            return "Finish or cancel the current recording to change the privacy setting"
        }
        return "Delete the recorded audio after transcription completes and keep only the transcript and exports"
    }

    private var statusDescription: String {
        if viewModel.isDeleteAudioAfterTranscriptionEnabled {
            return "After transcription finishes, Lorre deletes the source audio and any stored stems. Playback and waveform review will no longer be available for those sessions."
        }
        return "Lorre keeps the recorded audio after transcription so you can play it back, review the waveform, and export later."
    }
}

struct ProcessingPipelineView: View {
    @ObservedObject var viewModel: AppViewModel
    let session: SessionManifest

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x4) {
            StageHeaderCard(
                title: session.displayTitle,
                statusLine: session.processing.progressLabel ?? "Processing",
                rail: .progress(session.processing.progressFraction ?? 0.1),
                trailingActions: {
                    HStack(spacing: DS.Space.x2) {
                        Button("Export") {}
                            .buttonStyle(PrimaryControlButtonStyle())
                            .disabled(true)
                        Button("Reveal Files") {}
                            .buttonStyle(SecondaryControlButtonStyle())
                            .disabled(true)
                    }
                }
            )

            VStack(alignment: .leading, spacing: DS.Space.x3) {
                CapsLabel(text: "Processing Pipeline")
                Text(session.processing.progressPhase?.label ?? "Processing")
                    .font(DS.FontStyle.panelTitle)
                    .foregroundStyle(DS.ColorToken.fgPrimary)
                Text(session.processing.progressLabel ?? "Working on transcript…")
                    .font(DS.FontStyle.body)
                    .foregroundStyle(DS.ColorToken.fgSecondary)

                IndexRailView(mode: .progress(session.processing.progressFraction ?? 0.1), height: 10)
                    .frame(maxWidth: .infinity)

                HStack(spacing: DS.Space.x4) {
                    pipelineMetadata(label: "STATUS", value: session.status.label)
                    pipelineMetadata(label: "PHASE", value: session.processing.progressPhase?.rawValue.uppercased() ?? "WAITING")
                    pipelineMetadata(label: "FLUIDAUDIO", value: "SEAM READY")
                }

                Text("Processing stays in the main work stage so the user keeps context while the transcript is prepared.")
                    .font(DS.FontStyle.helper)
                    .foregroundStyle(DS.ColorToken.fgSecondary)
            }
            .padding(DS.Space.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsPanelSurface(cornerRadius: DS.Radius.lg)

            SpeakerRecognitionQuickAccessView(
                viewModel: viewModel,
                scopeNote: "This changes future processing runs. The current session keeps the settings it started with."
            )

            if let transcript = viewModel.activeTranscript, transcript.sessionId == session.id {
                VStack(alignment: .leading, spacing: DS.Space.x2) {
                    HStack(spacing: DS.Space.x2) {
                        CapsLabel(text: "Transcript Preview")
                        Text("Draft transcript while diarization runs (showing first \(min(4, transcript.segments.count)) segments)")
                            .font(DS.FontStyle.helper)
                            .foregroundStyle(DS.ColorToken.fgSecondary)
                    }

                    ForEach(Array(transcript.segments.prefix(4))) { segment in
                        HStack(alignment: .top, spacing: DS.Space.x2) {
                            Text(Formatters.timestamp(ms: segment.startMs))
                                .font(DS.FontStyle.mono)
                                .foregroundStyle(DS.ColorToken.fgSecondary)
                                .frame(width: 54, alignment: .leading)
                            Text(segment.text)
                                .font(DS.FontStyle.body)
                                .foregroundStyle(DS.ColorToken.fgPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .lineLimit(2)
                        }
                        .padding(.vertical, DS.Space.x1)
                    }
                }
                .padding(DS.Space.x4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dsPanelSurface(cornerRadius: DS.Radius.lg)
            }

            Spacer(minLength: 0)
        }
    }

    private func pipelineMetadata(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.x1) {
            CapsLabel(text: label)
            Text(value)
                .font(DS.FontStyle.mono)
                .foregroundStyle(DS.ColorToken.fgPrimary)
        }
    }
}

struct StageHeaderCard<TrailingActions: View>: View {
    let title: String
    let statusLine: String
    let rail: IndexRailMode
    @ViewBuilder var trailingActions: () -> TrailingActions

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.x4) {
            VStack(alignment: .leading, spacing: DS.Space.x2) {
                Text(title)
                    .font(DS.FontStyle.appTitle)
                    .foregroundStyle(DS.ColorToken.fgPrimary)
                    .lineLimit(2)

                Text(statusLine)
                    .font(DS.FontStyle.stageStatus)
                    .foregroundStyle(DS.ColorToken.fgSecondary)

                IndexRailView(mode: rail, height: railHeight)
                    .frame(width: 220)
            }

            Spacer()

            trailingActions()
        }
        .padding(DS.Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsPanelSurface(cornerRadius: DS.Radius.lg)
    }

    private var railHeight: CGFloat {
        switch rail {
        case .live:
            return 10
        default:
            return 8
        }
    }
}
