import SwiftUI

struct TranscriptSegmentRowView: View {
    private let topControlMinHeight: CGFloat = 72

    let sessionID: UUID
    let segment: TranscriptSegment
    let speaker: SpeakerProfile
    let speakers: [SpeakerProfile]
    let canCuePlayback: Bool
    let isPlaybackActive: Bool
    let showsConfidence: Bool
    let onCommitText: (String) -> Void
    let onAssignSpeaker: (String) -> Void
    let onRenameSpeaker: (String, String) -> Void
    let onSeekRequested: () -> Void

    @State private var draftText: String = ""
    @State private var showSpeakerPopover = false
    @State private var isRowHovered = false
    @FocusState private var isTextFocused: Bool

    init(
        sessionID: UUID,
        segment: TranscriptSegment,
        speaker: SpeakerProfile,
        speakers: [SpeakerProfile],
        canCuePlayback: Bool = true,
        isPlaybackActive: Bool = false,
        showsConfidence: Bool = false,
        onCommitText: @escaping (String) -> Void,
        onAssignSpeaker: @escaping (String) -> Void,
        onRenameSpeaker: @escaping (String, String) -> Void,
        onSeekRequested: @escaping () -> Void = {}
    ) {
        self.sessionID = sessionID
        self.segment = segment
        self.speaker = speaker
        self.speakers = speakers
        self.canCuePlayback = canCuePlayback
        self.isPlaybackActive = isPlaybackActive
        self.showsConfidence = showsConfidence
        self.onCommitText = onCommitText
        self.onAssignSpeaker = onAssignSpeaker
        self.onRenameSpeaker = onRenameSpeaker
        self.onSeekRequested = onSeekRequested
        _draftText = State(initialValue: segment.text)
    }

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.x3) {
            Button(action: onSeekRequested) {
                VStack(alignment: .leading, spacing: DS.Space.x1) {
                    Text(Formatters.timestamp(ms: segment.startMs))
                        .font(DS.FontStyle.monoStrong)
                        .foregroundStyle(canCuePlayback ? DS.ColorToken.fgPrimary : DS.ColorToken.fgSecondary)
                    Text(Formatters.timestamp(ms: segment.endMs))
                        .font(DS.FontStyle.mono)
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                }
                .padding(.horizontal, DS.Space.x2)
                .padding(.vertical, DS.Space.x1_5)
                .frame(width: 88, alignment: .leading)
                .frame(minHeight: topControlMinHeight, alignment: .topLeading)
                .dsPanelSurface(
                    selected: isPlaybackActive,
                    alt: !isPlaybackActive,
                    cornerRadius: DS.Radius.sm
                )
            }
            .buttonStyle(.plain)
            .disabled(!canCuePlayback)
            .help(
                canCuePlayback
                    ? "Play from \(Formatters.timestamp(ms: segment.startMs))"
                    : "Playback is unavailable because this session no longer has source audio."
            )

            Button {
                showSpeakerPopover.toggle()
            } label: {
                HStack(alignment: .center, spacing: DS.Space.x2) {
                    SpeakerBadgeView(speakerID: speaker.id, variant: speaker.styleVariant)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(speaker.safeDisplayName)
                            .font(DS.FontStyle.bodyStrong)
                            .foregroundStyle(DS.ColorToken.fgPrimary)
                            .lineLimit(1)
                        Text("Speaker \(speaker.id)")
                            .font(DS.FontStyle.helper)
                            .foregroundStyle(DS.ColorToken.fgSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                }
                .padding(.horizontal, DS.Space.x2)
                .padding(.vertical, DS.Space.x2)
                .frame(width: 230, alignment: .leading)
                .frame(minHeight: topControlMinHeight, alignment: .leading)
                .dsPanelSurface(alt: true, cornerRadius: DS.Radius.sm)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showSpeakerPopover, arrowEdge: .top) {
                SpeakerAssignmentPopoverView(
                    selectedSpeakerID: speaker.id,
                    speakers: speakers,
                    onAssignSpeaker: { speakerID in
                        onAssignSpeaker(speakerID)
                        showSpeakerPopover = false
                    },
                    onRenameSpeaker: { speakerID, name in
                        onRenameSpeaker(speakerID, name)
                    }
                )
                .frame(width: 320)
                .padding(DS.Space.x3)
            }

            VStack(alignment: .leading, spacing: DS.Space.x2) {
                TextField("Transcript segment", text: $draftText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(DS.FontStyle.body)
                    .foregroundStyle(DS.ColorToken.fgPrimary)
                    .focused($isTextFocused)
                    .lineLimit(1...4)
                    .padding(DS.Space.x2_5)
                    .frame(maxWidth: .infinity, minHeight: topControlMinHeight, alignment: .topLeading)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                            .fill(DS.ColorToken.fieldBg)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                            .stroke(isTextFocused ? DS.ColorToken.borderStrong : DS.ColorToken.borderSoft, lineWidth: 1)
                    )
                    .onSubmit {
                        commitIfNeeded()
                    }
                    .onChange(of: isTextFocused) { _, focused in
                        if !focused { commitIfNeeded() }
                    }
                    .onChange(of: segment.text) { _, newText in
                        if !isTextFocused, draftText != newText {
                            draftText = newText
                        }
                    }

                if shouldShowMetadataRow {
                    HStack(spacing: DS.Space.x2) {
                        if isPlaybackActive {
                            CapsLabel(text: "Current")
                        }
                        if segment.isEdited {
                            CapsLabel(text: "Edited")
                        }
                        if showsConfidence, let confidence = segment.confidence {
                            Text("conf \(Int(confidence * 100))%")
                                .font(DS.FontStyle.mono)
                                .foregroundStyle(DS.ColorToken.fgSecondary)
                        }
                        Spacer()
                    }
                }
            }
        }
        .padding(DS.Space.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            guard canCuePlayback else { return }
            onSeekRequested()
        }
        .onHover { hovering in
            isRowHovered = hovering
        }
        .dsPanelSurface(selected: isPlaybackActive || isRowHovered, cornerRadius: DS.Radius.md)
    }

    private func commitIfNeeded() {
        let normalized = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized != segment.text else { return }
        onCommitText(normalized)
    }

    private var shouldShowMetadataRow: Bool {
        isPlaybackActive || segment.isEdited || (showsConfidence && segment.confidence != nil)
    }
}

private struct SpeakerAssignmentPopoverView: View {
    let selectedSpeakerID: String
    let speakers: [SpeakerProfile]
    let onAssignSpeaker: (String) -> Void
    let onRenameSpeaker: (String, String) -> Void

    @State private var renameText: String = ""
    @State private var renameTargetID: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x3) {
            CapsLabel(text: "Assign Speaker")

            VStack(spacing: DS.Space.x2) {
                ForEach(speakers) { speaker in
                    Button {
                        onAssignSpeaker(speaker.id)
                        renameTargetID = speaker.id
                        renameText = speaker.safeDisplayName
                    } label: {
                        HStack(spacing: DS.Space.x2) {
                            SpeakerBadgeView(speakerID: speaker.id, variant: speaker.styleVariant)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(speaker.safeDisplayName)
                                    .font(DS.FontStyle.bodyStrong)
                                    .foregroundStyle(DS.ColorToken.fgPrimary)
                                Text("Speaker \(speaker.id)")
                                    .font(DS.FontStyle.helper)
                                    .foregroundStyle(DS.ColorToken.fgSecondary)
                            }
                            Spacer()
                            if speaker.id == selectedSpeakerID {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(DS.ColorToken.fgPrimary)
                            }
                        }
                        .padding(.horizontal, DS.Space.x2)
                        .padding(.vertical, DS.Space.x2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .dsPanelSurface(
                            selected: speaker.id == selectedSpeakerID,
                            alt: speaker.id != selectedSpeakerID,
                            cornerRadius: DS.Radius.sm
                        )
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: DS.Space.x2) {
                CapsLabel(text: "Rename Speaker")
                TextField("Speaker name", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(DS.FontStyle.body)
                    .foregroundStyle(DS.ColorToken.fgPrimary)
                    .padding(.horizontal, DS.Space.x3)
                    .padding(.vertical, DS.Space.x2)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                            .fill(DS.ColorToken.fieldBg)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                            .stroke(DS.ColorToken.borderSoft, lineWidth: 1)
                    )

                HStack(spacing: DS.Space.x2) {
                    Button("Apply") {
                        let targetID = renameTargetID.isEmpty ? selectedSpeakerID : renameTargetID
                        onRenameSpeaker(targetID, renameText)
                    }
                    .buttonStyle(SecondaryControlButtonStyle())

                    Text("Select a row speaker, then rename.")
                        .font(DS.FontStyle.helper)
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                }
            }
        }
        .onAppear {
            if renameTargetID.isEmpty {
                renameTargetID = selectedSpeakerID
                renameText = speakers.first(where: { $0.id == selectedSpeakerID })?.safeDisplayName ?? ""
            }
        }
    }
}
