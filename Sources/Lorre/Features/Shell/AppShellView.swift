import SwiftUI

struct AppShellView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        GeometryReader { geometry in
            let compactWidth = geometry.size.width < 1180
            let compactHeight = geometry.size.height < 820
            let shellSpacing = compactWidth ? DS.Space.x4 : DS.Space.x6
            let horizontalPadding = compactWidth ? DS.Space.x4 : DS.Space.x8
            let verticalPadding = compactHeight ? DS.Space.x4 : DS.Space.x6
            let sidebarWidth = min(312, max(248, geometry.size.width * (compactWidth ? 0.34 : 0.3)))

            ZStack {
                DS.ColorToken.bgApp.ignoresSafeArea()

                HStack(alignment: .top, spacing: shellSpacing) {
                    SessionShelfView(viewModel: viewModel)
                        .frame(width: sidebarWidth)

                    WorkStageContainerView(viewModel: viewModel)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .layoutPriority(1)
                }
                .padding(.horizontal, horizontalPadding)
                .padding(.vertical, verticalPadding)
            }
        }
    }
}

private struct WorkStageContainerView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x4) {
            if let banner = viewModel.banner {
                AppBannerView(banner: banner) {
                    viewModel.clearBanner()
                }
            }

            if viewModel.isBrowsingArchivedSessionWhileRecording {
                ActiveRecordingWorkspaceView(viewModel: viewModel)
            }

            switch viewModel.workStageRoute {
            case .recorder:
                RecorderConsoleView(viewModel: viewModel)
            case let .processing(sessionID):
                if let session = viewModel.sessions.first(where: { $0.id == sessionID }) {
                    ProcessingPipelineView(viewModel: viewModel, session: session)
                }
            case let .transcript(sessionID):
                if let session = viewModel.sessions.first(where: { $0.id == sessionID }) {
                    TranscriptStageView(
                        viewModel: viewModel,
                        session: session,
                        transcript: viewModel.activeTranscript
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct ActiveRecordingWorkspaceView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x3) {
            HStack(alignment: .top, spacing: DS.Space.x3) {
                VStack(alignment: .leading, spacing: DS.Space.x1_5) {
                    HStack(spacing: DS.Space.x2) {
                        ActiveRecordingBadge(label: viewModel.isStoppingRecording ? "FINALIZING" : "LIVE")
                        CapsLabel(text: "Recorder")
                    }

                    Text(viewModel.activeRecordingHeadline)
                        .font(DS.FontStyle.panelTitle)
                        .foregroundStyle(DS.ColorToken.fgPrimary)

                    Text(viewModel.activeRecordingDetail)
                        .font(DS.FontStyle.body)
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: DS.Space.x2)

                VStack(alignment: .trailing, spacing: DS.Space.x1) {
                    Text(Formatters.duration(viewModel.recordingElapsedSeconds))
                        .font(DS.FontStyle.timer)
                        .foregroundStyle(DS.ColorToken.fgPrimary)

                    Text(viewModel.activeRecordingSourceBadge)
                        .font(DS.FontStyle.monoStrong)
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                }
            }

            IndexRailView(mode: .live(viewModel.liveMeterSamples), height: 12)
                .frame(maxWidth: .infinity)

            HStack(spacing: DS.Space.x2) {
                Button("Open Recorder") {
                    viewModel.showRecorderScreenTapped()
                }
                .buttonStyle(SecondaryControlButtonStyle())

                Button(viewModel.isStoppingRecording ? "Finalizing…" : "Stop Recording") {
                    viewModel.stopRecordingTapped()
                }
                .buttonStyle(PrimaryControlButtonStyle())
                .disabled(viewModel.isStoppingRecording)

                Button("Cancel") {
                    viewModel.cancelRecordingTapped()
                }
                .buttonStyle(SecondaryControlButtonStyle())
                .disabled(viewModel.isStoppingRecording)
            }
        }
        .padding(DS.Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsPanelSurface(cornerRadius: DS.Radius.lg)
    }
}

private struct ActiveRecordingBadge: View {
    let label: String

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Circle()
                .fill(DS.ColorToken.white.opacity(0.92))
                .frame(width: 6, height: 6)

            Text(label)
                .font(DS.FontStyle.control)
                .foregroundStyle(DS.ColorToken.white)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, DS.Space.x2)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(DS.ColorToken.black)
        )
    }
}

private struct AppBannerView: View {
    let banner: AppBanner
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.x3) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(iconColor)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: DS.Space.x1) {
                Text(banner.title)
                    .font(DS.FontStyle.bodyStrong)
                    .foregroundStyle(DS.ColorToken.fgPrimary)
                Text(banner.message)
                    .font(DS.FontStyle.helper)
                    .foregroundStyle(DS.ColorToken.fgSecondary)
                    .textSelection(.enabled)
            }

            Spacer()

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.ColorToken.fgSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(DS.Space.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsPanelSurface(alt: true, cornerRadius: DS.Radius.md)
    }

    private var iconName: String {
        switch banner.kind {
        case .info: "info.circle"
        case .success: "checkmark.circle"
        case .error: "exclamationmark.triangle"
        }
    }

    private var iconColor: Color {
        switch banner.kind {
        case .info: DS.ColorToken.fgSecondary
        case .success: DS.ColorToken.fgPrimary
        case .error: DS.ColorToken.fgPrimary
        }
    }
}
