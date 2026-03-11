import SwiftUI

struct SpeakerRecognitionQuickAccessView: View {
    @ObservedObject var viewModel: AppViewModel
    let scopeNote: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x3) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: DS.Space.x2) {
                    titleLabel
                    Spacer(minLength: DS.Space.x2)
                    controlsRow
                }

                VStack(alignment: .leading, spacing: DS.Space.x2) {
                    titleLabel
                    controlsRow
                }
            }

            Text(statusDescription)
                .font(DS.FontStyle.helper)
                .foregroundStyle(DS.ColorToken.fgSecondary)
                .fixedSize(horizontal: false, vertical: true)

            KnownSpeakerLibraryQuickAccessView(viewModel: viewModel)

            Text(scopeNote)
                .font(DS.FontStyle.helper)
                .foregroundStyle(DS.ColorToken.fgTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsPanelSurface(alt: true, cornerRadius: DS.Radius.md)
    }

    private var titleLabel: some View {
        HStack(spacing: DS.Space.x2) {
            CapsLabel(text: "Speaker Recognition")
            Text(viewModel.isSpeakerDiarizationEnabled ? "ON" : "OFF")
                .font(DS.FontStyle.control)
                .foregroundStyle(DS.ColorToken.fgSecondary)
        }
    }

    private var controlsRow: some View {
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
            .help("Use diarization during processing to assign speaker IDs automatically")

            expectedSpeakersMenu
        }
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
                Text("Speakers: \(viewModel.diarizationExpectedSpeakerCountHint.detailLabel)")
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
        .help("Hint the diarizer with an expected speaker count")
    }

    private var statusDescription: String {
        if viewModel.isSpeakerDiarizationEnabled {
            return "Automatic speaker labels are enabled. Expected speaker hint: \(viewModel.diarizationExpectedSpeakerCountHint.detailLabel). Enrolled speakers are used to relabel diarization clusters and warm-start the live recorder."
        }
        return "Automatic speaker labels are off for faster processing. The speaker library is still kept locally so you can re-enable automatic labeling later."
    }
}

struct KnownSpeakerLibraryQuickAccessView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x2) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.x2) {
                CapsLabel(text: "Known Speakers")
                Spacer()
                Text("\(viewModel.knownSpeakers.count)")
                    .font(DS.FontStyle.mono)
                    .foregroundStyle(DS.ColorToken.fgSecondary)
            }

            HStack(spacing: DS.Space.x2) {
                TextField("Speaker name", text: $viewModel.knownSpeakerDraftName)
                    .textFieldStyle(.plain)
                    .font(DS.FontStyle.body)
                    .padding(.horizontal, DS.Space.x2)
                    .padding(.vertical, DS.Space.x2)
                    .background(DS.ColorToken.fieldBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.sm)
                            .stroke(DS.ColorToken.fieldBorder, lineWidth: 1)
                    )

                Button("Add Sample") {
                    viewModel.importKnownSpeaker()
                }
                .buttonStyle(SecondaryControlButtonStyle())
                .disabled(viewModel.isKnownSpeakerOperationInFlight)
            }

            Text(viewModel.knownSpeakerOperationDescription ?? viewModel.knownSpeakerLibraryStatusLine)
                .font(DS.FontStyle.helper)
                .foregroundStyle(
                    viewModel.isKnownSpeakerOperationInFlight
                        ? DS.ColorToken.fgSecondary
                        : DS.ColorToken.fgTertiary
                )
                .fixedSize(horizontal: false, vertical: true)

            if viewModel.knownSpeakers.isEmpty {
                Text("Import a clean clip from a single voice. Lorre stores the clip locally, extracts a speaker embedding, and uses it for offline relabeling plus live speaker hints.")
                    .font(DS.FontStyle.helper)
                    .foregroundStyle(DS.ColorToken.fgSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: DS.Space.x2) {
                    ForEach(viewModel.knownSpeakers) { speaker in
                        knownSpeakerRow(speaker)
                    }
                }
                .padding(.top, DS.Space.x1)
            }
        }
        .padding(DS.Space.x2_5)
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
    private func knownSpeakerRow(_ speaker: KnownSpeaker) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.x1_5) {
            HStack(alignment: .top, spacing: DS.Space.x2) {
                SpeakerBadgeView(speakerID: speaker.id, variant: speaker.styleVariant)

                VStack(alignment: .leading, spacing: 2) {
                    Text(speaker.safeDisplayName)
                        .font(DS.FontStyle.bodyStrong)
                        .foregroundStyle(DS.ColorToken.fgPrimary)

                    Text(referenceClipSummary(for: speaker))
                        .font(DS.FontStyle.helper)
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: DS.Space.x2)

                HStack(spacing: DS.Space.x2) {
                    Button("Re-enroll") {
                        viewModel.reenrollKnownSpeaker(speaker.id)
                    }
                    .buttonStyle(SecondaryControlButtonStyle())
                    .disabled(viewModel.isKnownSpeakerOperationInFlight)

                    Button("Remove", role: .destructive) {
                        viewModel.deleteKnownSpeaker(speaker.id)
                    }
                    .buttonStyle(SecondaryControlButtonStyle())
                    .disabled(viewModel.isKnownSpeakerOperationInFlight)
                }
            }

            Text(enrollmentSummary(for: speaker))
                .font(DS.FontStyle.mono)
                .foregroundStyle(DS.ColorToken.fgTertiary)
        }
        .padding(.horizontal, DS.Space.x2)
        .padding(.vertical, DS.Space.x2)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .fill(DS.ColorToken.bgPanel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .stroke(DS.ColorToken.borderSoft, lineWidth: 1)
        )
    }

    private func referenceClipSummary(for speaker: KnownSpeaker) -> String {
        guard let clip = speaker.referenceClip else {
            return "Reference clip metadata unavailable."
        }
        return "\(clip.sourceFileName) • \(Formatters.duration(clip.durationSeconds)) • \(clip.sampleRate) Hz"
    }

    private func enrollmentSummary(for speaker: KnownSpeaker) -> String {
        let updated = speaker.updatedAt.formatted(date: .abbreviated, time: .shortened)
        return "\(speaker.enrollmentCount) enrollment\(speaker.enrollmentCount == 1 ? "" : "s") • updated \(updated)"
    }
}
