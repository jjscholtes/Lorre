import SwiftUI

struct IndexRailSpeakerBin: Identifiable {
    let id = UUID()
    let variant: SpeakerBadgeVariant
    let weight: Double
}

enum IndexRailMode {
    case idleTicks
    case progress(Double)
    case live([Double])
    case speakerSummary([IndexRailSpeakerBin])
}

struct IndexRailView: View {
    let mode: IndexRailMode
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                    .fill(DS.ColorToken.bgPanelAlt)
                RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                    .stroke(DS.ColorToken.borderSoft, lineWidth: 1)

                switch mode {
                case .idleTicks:
                    idleTicks(width: proxy.size.width)
                case let .progress(value):
                    progressRail(width: proxy.size.width, fraction: value)
                case let .live(samples):
                    liveRail(width: proxy.size.width, samples: samples)
                case let .speakerSummary(bins):
                    speakerSummaryRail(width: proxy.size.width, bins: bins)
                }
            }
        }
        .frame(height: height)
    }

    @ViewBuilder
    private func idleTicks(width: CGFloat) -> some View {
        let count = max(8, Int(width / 10))
        HStack(spacing: 2) {
            ForEach(0..<count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(index.isMultiple(of: 3) ? DS.ColorToken.borderStrong : DS.ColorToken.borderSoft)
                    .frame(height: height - 4)
            }
        }
        .padding(.horizontal, 3)
        .frame(width: width, alignment: .leading)
    }

    @ViewBuilder
    private func progressRail(width: CGFloat, fraction: Double) -> some View {
        let clamped = min(1, max(0, fraction))
        let innerWidth = max(0, (width - 6) * clamped)
        RoundedRectangle(cornerRadius: (height - 4) / 2, style: .continuous)
            .fill(DS.ColorToken.black)
            .frame(width: innerWidth, height: max(2, height - 4))
            .padding(.leading, 3)
            .padding(.vertical, 2)
    }

    @ViewBuilder
    private func liveRail(width: CGFloat, samples: [Double]) -> some View {
        let bars = samples.isEmpty ? Array(repeating: 0.12, count: 24) : samples
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(bars.enumerated()), id: \.offset) { _, sample in
                let clamped = min(1.0, max(0.0, sample))
                // Slightly boost low-to-mid amplitudes so spoken-volume changes read more clearly.
                let scaledSample = min(1.0, max(0.03, pow(clamped, 0.62) * 1.18))
                RoundedRectangle(cornerRadius: 1.25, style: .continuous)
                    .fill(DS.ColorToken.black)
                    .frame(height: max(2, (height - 2) * CGFloat(scaledSample)))
            }
        }
        .frame(width: width - 6, height: height - 2, alignment: .leading)
        .padding(.top, 1)
        .padding(.horizontal, 3)
    }

    @ViewBuilder
    private func speakerSummaryRail(width: CGFloat, bins: [IndexRailSpeakerBin]) -> some View {
        let validBins = bins.filter { $0.weight > 0 }
        let total = max(validBins.reduce(0) { $0 + $1.weight }, 0.0001)
        HStack(spacing: 2) {
            ForEach(validBins) { bin in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(color(for: bin.variant))
                    .frame(maxWidth: .infinity, maxHeight: height - 4)
                    .layoutPriority(bin.weight / total)
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 2)
    }

    private func color(for variant: SpeakerBadgeVariant) -> Color {
        switch variant {
        case .filled:
            return DS.ColorToken.black
        case .outline:
            return DS.ColorToken.borderStrong
        case .doubleOutline:
            return DS.ColorToken.fgSecondary
        case .dashed:
            return DS.ColorToken.fgTertiary
        }
    }
}
