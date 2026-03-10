import SwiftUI

struct SpeakerBadgeView: View {
    let speakerID: String
    let variant: SpeakerBadgeVariant

    var body: some View {
        Text(speakerID)
            .font(DS.FontStyle.control)
            .foregroundStyle(foreground)
            .padding(.horizontal, DS.Space.x2)
            .padding(.vertical, DS.Space.x1)
            .background(
                Capsule(style: .continuous)
                    .fill(fill)
            )
            .overlay {
                switch variant {
                case .filled:
                    Capsule(style: .continuous)
                        .stroke(DS.ColorToken.black, lineWidth: 0)
                case .outline:
                    Capsule(style: .continuous)
                        .stroke(DS.ColorToken.borderStrong, lineWidth: 1)
                case .doubleOutline:
                    Capsule(style: .continuous)
                        .stroke(DS.ColorToken.borderStrong, lineWidth: 1)
                        .padding(1.5)
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(DS.ColorToken.borderStrong, lineWidth: 1)
                                .padding(3)
                        )
                case .dashed:
                    Capsule(style: .continuous)
                        .stroke(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                        .foregroundStyle(DS.ColorToken.borderStrong)
                }
            }
    }

    private var fill: Color {
        variant == .filled ? DS.ColorToken.black : DS.ColorToken.bgPanel
    }

    private var foreground: Color {
        variant == .filled ? DS.ColorToken.white : DS.ColorToken.fgPrimary
    }
}
