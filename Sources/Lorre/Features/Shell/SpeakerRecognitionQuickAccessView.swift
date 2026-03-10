import SwiftUI

struct SpeakerRecognitionQuickAccessView: View {
    @ObservedObject var viewModel: AppViewModel
    let scopeNote: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x2) {
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
            if viewModel.isSpeakerDiarizationEnabled {
                Text("ON")
                    .font(DS.FontStyle.control)
                    .foregroundStyle(DS.ColorToken.fgSecondary)
            } else {
                Text("OFF")
                    .font(DS.FontStyle.control)
                    .foregroundStyle(DS.ColorToken.fgSecondary)
            }
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
            return "Automatic speaker labels are enabled. Expected speaker hint: \(viewModel.diarizationExpectedSpeakerCountHint.detailLabel)."
        }
        return "Automatic speaker labels are off for faster processing. You can still assign speakers manually in the transcript."
    }
}
