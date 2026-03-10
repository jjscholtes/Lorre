import Foundation

#if canImport(FluidAudio)
@preconcurrency import FluidAudio
#endif

#if canImport(FluidAudio)
enum FluidAudioProgressSupport {
    static func makeUpdate(
        phase: ProcessingPhase,
        component: ProcessingComponent,
        label: String,
        progress: DownloadUtils.DownloadProgress
    ) -> ProcessingUpdate {
        let detail: String
        switch progress.phase {
        case .listing:
            detail = "Listing required files from \(ModelRegistry.baseURL)"
        case let .downloading(completedFiles, totalFiles):
            detail = "Downloading \(completedFiles)/\(max(totalFiles, 1)) files from \(ModelRegistry.baseURL)"
        case let .compiling(modelName):
            if modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                detail = "Compiling Core ML assets"
            } else {
                detail = "Compiling \(modelName)"
            }
        }

        return ProcessingUpdate(
            phase: phase,
            component: component,
            label: label,
            detail: detail,
            fraction: clamp(progress.fractionCompleted)
        )
    }

    static func readyUpdate(
        phase: ProcessingPhase,
        component: ProcessingComponent,
        label: String,
        detail: String
    ) -> ProcessingUpdate {
        ProcessingUpdate(
            phase: phase,
            component: component,
            label: label,
            detail: detail,
            fraction: 1.0
        )
    }

    static func scale(
        _ update: ProcessingUpdate,
        into range: ClosedRange<Double>
    ) -> ProcessingUpdate {
        let local = clamp(update.fraction ?? 0)
        let scaledFraction = range.lowerBound + ((range.upperBound - range.lowerBound) * local)
        return ProcessingUpdate(
            phase: update.phase,
            component: update.component,
            label: update.label,
            detail: update.detail,
            fraction: clamp(scaledFraction)
        )
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

enum KnownSpeakerSimilarity {
    static func cosineDistance(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return .infinity }

        var dot: Float = 0
        var lhsNorm: Float = 0
        var rhsNorm: Float = 0

        for (left, right) in zip(lhs, rhs) {
            dot += left * right
            lhsNorm += left * left
            rhsNorm += right * right
        }

        let denominator = sqrt(lhsNorm) * sqrt(rhsNorm)
        guard denominator > 0 else { return .infinity }
        let similarity = max(-1, min(1, dot / denominator))
        return 1 - similarity
    }
}
#endif
