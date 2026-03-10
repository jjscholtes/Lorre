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

            if viewModel.isRecording || viewModel.isStoppingRecording || viewModel.selectedSession == nil {
                RecorderConsoleView(viewModel: viewModel)
            } else if let session = viewModel.selectedSession, session.status == .processing {
                ProcessingPipelineView(viewModel: viewModel, session: session)
            } else if let session = viewModel.selectedSession {
                TranscriptStageView(
                    viewModel: viewModel,
                    session: session,
                    transcript: viewModel.activeTranscript
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
