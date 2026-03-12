import SwiftUI

struct TranscriptStageView: View {
    @ObservedObject var viewModel: AppViewModel
    let session: SessionManifest
    let transcript: TranscriptDocument?

    var body: some View {
        let canCuePlayback = viewModel.canControlPlayback
        VStack(alignment: .leading, spacing: DS.Space.x4) {
            TranscriptHeaderView(viewModel: viewModel, session: session, transcript: transcript)

            if session.status == .error, transcript == nil {
                TranscriptErrorStateView(viewModel: viewModel, session: session)
            } else if let transcript {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: DS.Space.x2) {
                            HStack(spacing: DS.Space.x2) {
                                Image(systemName: cuePlaybackIconName)
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(DS.ColorToken.fgSecondary)
                                CapsLabel(text: cuePlaybackStatusLabel)
                                Text(cuePlaybackDescription)
                                    .font(DS.FontStyle.helper)
                                    .foregroundStyle(DS.ColorToken.fgSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, DS.Space.x2_5)
                            .padding(.vertical, DS.Space.x2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .dsPanelSurface(alt: true, cornerRadius: DS.Radius.sm)

                            ForEach(transcript.segments) { segment in
                                TranscriptSegmentRowView(
                                    sessionID: session.id,
                                    segment: segment,
                                    speaker: transcript.speaker(for: segment.speakerId),
                                    speakers: transcript.speakers,
                                    canCuePlayback: canCuePlayback,
                                    isPlaybackActive: viewModel.isPlaybackSegmentActive(segment.id),
                                    showsConfidence: viewModel.isTranscriptConfidenceVisible
                                ) { updatedText in
                                    viewModel.updateSegmentText(
                                        sessionID: session.id,
                                        segmentID: segment.id,
                                        text: updatedText
                                    )
                                } onAssignSpeaker: { speakerID in
                                    viewModel.assignSpeaker(
                                        sessionID: session.id,
                                        segmentID: segment.id,
                                        speakerID: speakerID
                                    )
                                } onRenameSpeaker: { speakerID, newName in
                                    viewModel.renameSpeaker(
                                        sessionID: session.id,
                                        speakerID: speakerID,
                                        to: newName
                                    )
                                } onSeekRequested: {
                                    viewModel.seekSelectedSessionPlayback(to: segment.startMs)
                                }
                                .id(segment.id)
                            }
                        }
                        .padding(DS.Space.x4)
                    }
                    .onChange(of: viewModel.activePlaybackSegmentID) { _, activeID in
                        guard let activeID else { return }
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(activeID, anchor: .center)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .dsPanelSurface(cornerRadius: DS.Radius.lg)
            } else {
                VStack(alignment: .leading, spacing: DS.Space.x2) {
                    CapsLabel(text: "Transcript")
                    Text("Transcript is not available yet.")
                        .font(DS.FontStyle.panelTitle)
                        .foregroundStyle(DS.ColorToken.fgPrimary)
                    Text("Select a ready session or wait for processing to complete.")
                        .font(DS.FontStyle.body)
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                    IndexRailView(mode: .idleTicks, height: 8)
                }
                .padding(DS.Space.x4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .dsPanelSurface(cornerRadius: DS.Radius.lg)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var cuePlaybackStatusLabel: String {
        if !session.hasRetainedAudio {
            return "Playback unavailable"
        }
        if !viewModel.canControlPlayback {
            return "Cue Playback"
        }
        return "Cue Playback"
    }

    private var cuePlaybackDescription: String {
        if !session.hasRetainedAudio {
            return "Privacy Mode deleted the source audio for this session, so cue playback is unavailable."
        }
        if !viewModel.canControlPlayback {
            return "Cue playback becomes available once the session is ready."
        }
        return "Click a fragment or timestamp to play from that point."
    }

    private var cuePlaybackIconName: String {
        if !session.hasRetainedAudio {
            return "lock.fill"
        }
        if !viewModel.canControlPlayback {
            return "clock.fill"
        }
        return "play.fill"
    }
}
