import SwiftUI

struct RecorderConsoleView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var isShowingCancelRecordingConfirmation = false
    @State private var isShowingKnownSpeakerLibrary = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: DS.Space.x4) {
                if viewModel.isRecording || viewModel.isStoppingRecording {
                    recordingConsole
                } else {
                    setupConsole
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: 940, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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

    private var recordingConsole: some View {
        VStack(alignment: .leading, spacing: DS.Space.x4) {
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

            IndexRailView(mode: .live(viewModel.liveMeterSamples), height: 24)
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
        }
        .padding(DS.Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsPanelSurface(cornerRadius: DS.Radius.lg)
    }

    private var setupConsole: some View {
        VStack(alignment: .leading, spacing: DS.Space.x4) {
            RecorderSetupHeaderView(viewModel: viewModel)
            RecorderSectionDivider()
            RecorderSourceQuickAccessView(viewModel: viewModel)
            RecorderInsetPanel {
                VStack(alignment: .leading, spacing: DS.Space.x3) {
                    RecorderPrivacyQuickAccessView(viewModel: viewModel)
                    RecorderSectionDivider()
                    RecorderProcessingProfileView(
                        viewModel: viewModel,
                        isShowingKnownSpeakerLibrary: $isShowingKnownSpeakerLibrary
                    )
                }
            }

            RecorderStartDockView(viewModel: viewModel) {
                viewModel.startRecordingTapped()
            }
        }
        .padding(DS.Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsPanelSurface(cornerRadius: DS.Radius.lg)
    }
}

private struct RecorderSetupHeaderView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x3) {
            titleBlock

            IndexRailView(mode: .idleTicks, height: 8)
                .frame(maxWidth: .infinity)
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: DS.Space.x1_5) {
            CapsLabel(text: "Recorder")
            Text("Arm the capture, then start.")
                .font(DS.FontStyle.panelTitle)
                .foregroundStyle(DS.ColorToken.fgPrimary)
        }
    }
}

private struct RecorderInsetPanel<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(DS.Space.x3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsPanelSurface(alt: true, cornerRadius: DS.Radius.md)
    }
}

private struct RecorderSectionDivider: View {
    var body: some View {
        Rectangle()
            .fill(DS.ColorToken.borderSoft)
            .frame(height: 1)
    }
}

private struct RecorderStartDockView: View {
    @ObservedObject var viewModel: AppViewModel
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x3) {
            startButton

            if viewModel.selectedRecordingSource.includesSystemAudio {
                Text("Lorre will show the native picker after you press Start Recording so you can choose the app, window, or display audio.")
                    .font(DS.FontStyle.helper)
                    .foregroundStyle(DS.ColorToken.fgSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            IndexRailView(mode: .idleTicks, height: 8)
                .frame(maxWidth: .infinity)
        }
        .padding(DS.Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsPanelSurface(alt: true, cornerRadius: DS.Radius.lg)
    }

    private var startButton: some View {
        Button(action: onStart) {
            HStack(spacing: DS.Space.x2) {
                ZStack {
                    Circle()
                        .stroke(DS.ColorToken.white.opacity(0.34), lineWidth: 1)
                        .frame(width: 20, height: 20)

                    Circle()
                        .fill(DS.ColorToken.white)
                        .frame(width: 7, height: 7)
                }

                Text("Start Recording")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DS.ColorToken.white)

                Spacer(minLength: DS.Space.x2)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.ColorToken.white.opacity(0.76))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(RecorderStartActionButtonStyle())
        .accessibilityHint("Starts \(viewModel.selectedRecordingSource.label.lowercased()) recording with the current privacy and processing profile")
    }
}

private struct RecorderSummaryBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(DS.FontStyle.mono)
            .foregroundStyle(DS.ColorToken.fgSecondary)
            .padding(.horizontal, DS.Space.x2)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(DS.ColorToken.bgPanel)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(DS.ColorToken.borderSoft, lineWidth: 1)
            )
    }
}

private struct RecorderSourceQuickAccessView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x2) {
            HStack(spacing: DS.Space.x2) {
                CapsLabel(text: "Capture Mode")
                Text(viewModel.selectedRecordingSource.shortLabel.uppercased())
                    .font(DS.FontStyle.control)
                    .foregroundStyle(DS.ColorToken.fgSecondary)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.x2) {
                    ForEach(RecordingSource.allCases) { source in
                        Button(source.label) {
                            viewModel.setRecordingSource(source)
                        }
                        .buttonStyle(
                            RecorderSourceOptionButtonStyle(
                                isSelected: viewModel.selectedRecordingSource == source,
                                iconName: sourceIcon(for: source),
                                detail: sourceDetail(for: source)
                            )
                        )
                        .disabled(isLockedDuringCapture)
                    }
                }

                VStack(spacing: DS.Space.x2) {
                    ForEach(RecordingSource.allCases) { source in
                        Button(source.label) {
                            viewModel.setRecordingSource(source)
                        }
                        .buttonStyle(
                            RecorderSourceOptionButtonStyle(
                                isSelected: viewModel.selectedRecordingSource == source,
                                iconName: sourceIcon(for: source),
                                detail: sourceDetail(for: source)
                            )
                        )
                        .disabled(isLockedDuringCapture)
                    }
                }
            }

            if viewModel.selectedRecordingSource.includesSystemAudio {
                Text("After start, Lorre opens the native picker so you can choose the app, window, or display audio to capture.")
                    .font(DS.FontStyle.helper)
                    .foregroundStyle(DS.ColorToken.fgSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isLockedDuringCapture {
                Text("Finish or cancel the current recording to change the source.")
                    .font(DS.FontStyle.helper)
                    .foregroundStyle(DS.ColorToken.fgTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isLockedDuringCapture: Bool {
        viewModel.isRecording || viewModel.isStoppingRecording
    }

    private func sourceDetail(for source: RecordingSource) -> String {
        switch source {
        case .microphone:
            return "Your voice only"
        case .systemAudio:
            return "Mac audio only"
        case .microphoneAndSystemAudio:
            return "Your voice + Mac audio"
        }
    }

    private func sourceIcon(for source: RecordingSource) -> String {
        switch source {
        case .microphone:
            return "mic.fill"
        case .systemAudio:
            return "speaker.wave.2.fill"
        case .microphoneAndSystemAudio:
            return "waveform.badge.mic"
        }
    }
}

private struct RecorderSourceOptionButtonStyle: ButtonStyle {
    let isSelected: Bool
    let iconName: String
    let detail: String

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: DS.Space.x2) {
            iconBadge

            VStack(alignment: .leading, spacing: 2) {
                configuration.label
                    .font(DS.FontStyle.control)
                    .foregroundStyle(isSelected ? DS.ColorToken.white : DS.ColorToken.fgPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)

                Text(detail)
                    .font(DS.FontStyle.helper)
                    .foregroundStyle(isSelected ? DS.ColorToken.white.opacity(0.82) : DS.ColorToken.fgSecondary)
                    .lineLimit(1)
            }

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.ColorToken.white)
            }
        }
        .padding(.horizontal, DS.Space.x2_5)
        .padding(.vertical, DS.Space.x2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .fill(isSelected ? DS.ColorToken.black.opacity(configuration.isPressed ? 0.92 : 1) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .stroke(
                    isSelected ? DS.ColorToken.white.opacity(0.12) : DS.ColorToken.borderSoft,
                    lineWidth: 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous))
    }

    private var iconBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .fill(isSelected ? DS.ColorToken.white.opacity(0.12) : .clear)
                .frame(width: 30, height: 30)

            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .stroke(isSelected ? DS.ColorToken.white.opacity(0.16) : DS.ColorToken.borderSoft, lineWidth: 1)
                .frame(width: 30, height: 30)

            Image(systemName: iconName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSelected ? DS.ColorToken.white : DS.ColorToken.fgSecondary)
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
            titleRow

            Text(statusDescription)
                .font(DS.FontStyle.helper)
                .foregroundStyle(DS.ColorToken.fgSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Space.x2) {
                    privacyOption(
                        title: "Keep Audio",
                        detail: "Playback and waveform review stay available after transcription.",
                        isSelected: !viewModel.isDeleteAudioAfterTranscriptionEnabled
                    ) {
                        viewModel.setDeleteAudioAfterTranscriptionEnabled(false)
                    }

                    privacyOption(
                        title: "Delete After Transcript",
                        detail: "Lorre removes the source audio and keeps the transcript and exports.",
                        isSelected: viewModel.isDeleteAudioAfterTranscriptionEnabled
                    ) {
                        viewModel.setDeleteAudioAfterTranscriptionEnabled(true)
                    }
                }

                VStack(spacing: DS.Space.x2) {
                    privacyOption(
                        title: "Keep Audio",
                        detail: "Playback and waveform review stay available after transcription.",
                        isSelected: !viewModel.isDeleteAudioAfterTranscriptionEnabled
                    ) {
                        viewModel.setDeleteAudioAfterTranscriptionEnabled(false)
                    }

                    privacyOption(
                        title: "Delete After Transcript",
                        detail: "Lorre removes the source audio and keeps the transcript and exports.",
                        isSelected: viewModel.isDeleteAudioAfterTranscriptionEnabled
                    ) {
                        viewModel.setDeleteAudioAfterTranscriptionEnabled(true)
                    }
                }
            }

            if isLockedDuringCapture {
                Text("Finish or cancel the current recording to change this privacy setting.")
                    .font(DS.FontStyle.helper)
                    .foregroundStyle(DS.ColorToken.fgTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var titleRow: some View {
        HStack(spacing: DS.Space.x2) {
            CapsLabel(text: "Retention")
            Text(viewModel.isDeleteAudioAfterTranscriptionEnabled ? "DELETE AFTER TRANSCRIPT" : "KEEP AUDIO")
                .font(DS.FontStyle.control)
                .foregroundStyle(DS.ColorToken.fgSecondary)
        }
    }

    private var isLockedDuringCapture: Bool {
        viewModel.isRecording || viewModel.isStoppingRecording
    }

    private func privacyOption(
        title: String,
        detail: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DS.Space.x1_5) {
                    Text(title)
                        .font(DS.FontStyle.control)
                        .foregroundStyle(isSelected ? DS.ColorToken.white : DS.ColorToken.fgPrimary)
                        .lineLimit(1)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DS.ColorToken.white)
                    }
                }

                Text(detail)
                    .font(DS.FontStyle.helper)
                    .foregroundStyle(isSelected ? DS.ColorToken.white.opacity(0.82) : DS.ColorToken.fgSecondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, DS.Space.x2_5)
            .padding(.vertical, DS.Space.x2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .fill(isSelected ? DS.ColorToken.black : .clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                    .stroke(
                        isSelected ? DS.ColorToken.white.opacity(0.12) : DS.ColorToken.borderSoft,
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(isLockedDuringCapture)
    }

    private var statusDescription: String {
        if viewModel.isDeleteAudioAfterTranscriptionEnabled {
            return "Transcript and exports only."
        }
        return "Audio stays available for playback and waveform review."
    }
}

private struct RecorderProcessingProfileView: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var isShowingKnownSpeakerLibrary: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x2) {
            HStack(spacing: DS.Space.x2) {
                CapsLabel(text: "Processing Profile")
                Text(profileStateLabel)
                    .font(DS.FontStyle.control)
                    .foregroundStyle(DS.ColorToken.fgSecondary)
            }

            Text(profileDescription)
                .font(DS.FontStyle.helper)
                .foregroundStyle(DS.ColorToken.fgSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: DS.Space.x2) {
                processingRow(
                    title: "Speaker recognition",
                    detail: speakerRecognitionDetail,
                    control: {
                        HStack(spacing: DS.Space.x2) {
                            Toggle(
                                "Enable automatic speaker labeling",
                                isOn: Binding(
                                    get: { viewModel.isSpeakerDiarizationEnabled },
                                    set: { viewModel.setSpeakerDiarizationEnabled($0) }
                                )
                            )
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(DS.ColorToken.fgPrimary)

                            expectedSpeakersMenu
                        }
                    }
                )

                processingRow(
                    title: "Live preview",
                    detail: livePreviewDetail,
                    control: {
                        Toggle(
                            "Enable English-only live transcript preview while recording",
                            isOn: Binding(
                                get: { viewModel.isLiveTranscriptionEnabled },
                                set: { viewModel.setLiveTranscriptionEnabled($0) }
                            )
                        )
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(DS.ColorToken.fgPrimary)
                        .disabled(!viewModel.isLiveTranscriptionSupported)
                    }
                )
            }

            if viewModel.isSpeakerDiarizationEnabled {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        isShowingKnownSpeakerLibrary.toggle()
                    }
                } label: {
                    HStack(spacing: DS.Space.x2) {
                        CapsLabel(text: "Speaker Library")
                        Text("\(viewModel.knownSpeakers.count) enrolled")
                            .font(DS.FontStyle.mono)
                            .foregroundStyle(DS.ColorToken.fgSecondary)
                        Spacer()
                        Text(isShowingKnownSpeakerLibrary ? "Hide" : "Manage")
                            .font(DS.FontStyle.control)
                            .foregroundStyle(DS.ColorToken.fgSecondary)
                        Image(systemName: isShowingKnownSpeakerLibrary ? "chevron.up" : "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DS.ColorToken.fgSecondary)
                    }
                    .padding(.horizontal, DS.Space.x3)
                    .padding(.vertical, DS.Space.x1_5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                            .fill(DS.ColorToken.bgPanelAlt)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                            .stroke(DS.ColorToken.borderSoft, lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                if isShowingKnownSpeakerLibrary {
                    KnownSpeakerLibraryQuickAccessView(viewModel: viewModel)
                }
            }
        }
    }

    private func processingRow<Control: View>(
        title: String,
        detail: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: DS.Space.x3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DS.FontStyle.control)
                        .foregroundStyle(DS.ColorToken.fgPrimary)
                    Text(detail)
                        .font(DS.FontStyle.helper)
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: DS.Space.x2)
                control()
            }

            VStack(alignment: .leading, spacing: DS.Space.x2) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DS.FontStyle.control)
                        .foregroundStyle(DS.ColorToken.fgPrimary)
                    Text(detail)
                        .font(DS.FontStyle.helper)
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                control()
            }
        }
        .padding(.horizontal, DS.Space.x2_5)
        .padding(.vertical, DS.Space.x2)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .fill(.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md, style: .continuous)
                .stroke(DS.ColorToken.borderSoft, lineWidth: 1)
        )
    }

    private var expectedSpeakersMenu: some View {
        Menu {
            ForEach(DiarizationSpeakerCountHint.tuningPresets, id: \.self) { hint in
                Button {
                    viewModel.setDiarizationExpectedSpeakerCountHint(hint)
                } label: {
                    if viewModel.diarizationExpectedSpeakerCountHint.normalized() == hint.normalized() {
                        Label(hint.detailLabel, systemImage: "checkmark")
                    } else {
                        Text(hint.detailLabel)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(viewModel.diarizationExpectedSpeakerCountHint.detailLabel)
                    .font(DS.FontStyle.control)
                    .foregroundStyle(DS.ColorToken.fgPrimary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DS.ColorToken.fgSecondary)
            }
            .padding(.horizontal, DS.Space.x2)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(DS.ColorToken.bgPanelAlt)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .stroke(DS.ColorToken.borderSoft, lineWidth: 1)
            )
        }
        .disabled(!viewModel.isSpeakerDiarizationEnabled)
    }

    private var profileStateLabel: String {
        if viewModel.isSpeakerDiarizationEnabled && viewModel.isLiveTranscriptionEnabled {
            return "FULL PROFILE"
        }
        if viewModel.isSpeakerDiarizationEnabled || viewModel.isLiveTranscriptionEnabled {
            return "MIXED PROFILE"
        }
        return "POST-PASS ONLY"
    }

    private var profileDescription: String {
        let speaker = viewModel.isSpeakerDiarizationEnabled
            ? "Lorre will label speakers during the final transcript pass."
            : "Speakers stay manual unless you reprocess later."
        let live: String
        if !viewModel.isLiveTranscriptionSupported {
            live = "Live preview is unavailable in this build."
        } else if viewModel.isLiveTranscriptionEnabled {
            live = "An English-only preview appears while recording."
        } else {
            live = "No live preview during capture."
        }
        return "\(speaker) \(live)"
    }

    private var speakerRecognitionDetail: String {
        if viewModel.isSpeakerDiarizationEnabled {
            return "Expected speakers: \(viewModel.diarizationExpectedSpeakerCountHint.detailLabel). Enrolled voices help relabel diarization clusters."
        }
        return "Turn this on if you want Lorre to assign speaker labels automatically after capture."
    }

    private var livePreviewDetail: String {
        if !viewModel.isLiveTranscriptionSupported {
            return "Not available in this build. The final transcript still runs after you stop."
        }
        if viewModel.isLiveTranscriptionEnabled {
            return "Shows an English-only preview while recording. Final post-pass remains the source of truth."
        }
        return "Capture first, then let Lorre transcribe after you stop."
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
