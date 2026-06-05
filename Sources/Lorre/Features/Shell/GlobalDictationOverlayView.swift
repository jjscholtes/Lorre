import SwiftUI

struct GlobalDictationOverlayCard: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x3) {
            HStack(alignment: .top, spacing: DS.Space.x3) {
                VStack(alignment: .leading, spacing: DS.Space.x1_5) {
                    HStack(spacing: DS.Space.x2) {
                        statusBadge
                        CapsLabel(text: viewModel.globalDictationTargetLabel ?? "Text Field")
                    }

                    Text(viewModel.globalDictationTitle)
                        .font(DS.FontStyle.panelTitle)
                        .foregroundStyle(DS.ColorToken.fgPrimary)

                    Text(viewModel.globalDictationDetail)
                        .font(DS.FontStyle.body)
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: DS.Space.x2)

                if viewModel.globalDictationPhase == .listening {
                    Text(Formatters.duration(viewModel.globalDictationElapsedSeconds))
                        .font(DS.FontStyle.timer)
                        .foregroundStyle(DS.ColorToken.fgPrimary)
                        .monospacedDigit()
                }
            }

            IndexRailView(mode: railMode, height: 10)
                .frame(maxWidth: .infinity)

            if !viewModel.globalDictationTranscriptText.isEmpty {
                Text(viewModel.globalDictationTranscriptText)
                    .font(DS.FontStyle.body)
                    .foregroundStyle(DS.ColorToken.fgPrimary)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .padding(DS.Space.x2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(DS.ColorToken.bgPanelAlt)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                            .stroke(DS.ColorToken.borderSoft, lineWidth: 1)
                    )
            }

            HStack(spacing: DS.Space.x2) {
                switch viewModel.globalDictationPhase {
                case .listening:
                    Button("Stop") {
                        viewModel.stopGlobalDictationTapped()
                    }
                    .buttonStyle(PrimaryControlButtonStyle())

                    Button("Cancel") {
                        viewModel.cancelGlobalDictationTapped()
                    }
                    .buttonStyle(SecondaryControlButtonStyle())
                case .transcribing, .inserting:
                    Button(viewModel.globalDictationPhase == .transcribing ? "Transcribing…" : "Inserting…") {}
                        .buttonStyle(SecondaryControlButtonStyle())
                        .disabled(true)
                case .inserted, .failed:
                    if !viewModel.globalDictationTranscriptText.isEmpty {
                        Button("Copy") {
                            viewModel.copyGlobalDictationTranscriptToClipboard()
                        }
                        .buttonStyle(SecondaryControlButtonStyle())
                    }

                    Button("Dismiss") {
                        viewModel.dismissGlobalDictationOverlay()
                    }
                    .buttonStyle(PrimaryControlButtonStyle())
                case .idle:
                    EmptyView()
                }
            }
        }
        .padding(DS.Space.x4)
        .frame(width: 420, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                .fill(DS.ColorToken.bgPanel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.lg, style: .continuous)
                .stroke(DS.ColorToken.borderStrong, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 18, y: 10)
    }

    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 6, height: 6)

            Text(statusLabel)
                .font(DS.FontStyle.control)
                .foregroundStyle(DS.ColorToken.white)
        }
        .padding(.horizontal, DS.Space.x2)
        .padding(.vertical, 6)
        .background(
            Capsule(style: .continuous)
                .fill(DS.ColorToken.black)
        )
    }

    private var statusLabel: String {
        switch viewModel.globalDictationPhase {
        case .idle:
            return "IDLE"
        case .listening:
            return "LIVE"
        case .transcribing:
            return "ASR"
        case .inserting:
            return "PASTE"
        case .inserted:
            return "DONE"
        case .failed:
            return "BLOCKED"
        }
    }

    private var statusDotColor: Color {
        switch viewModel.globalDictationPhase {
        case .failed:
            return DS.ColorToken.statusError
        case .inserted:
            return DS.ColorToken.statusReady
        case .transcribing, .inserting:
            return DS.ColorToken.statusPreparing
        case .idle:
            return DS.ColorToken.statusIdle
        case .listening:
            return DS.ColorToken.white
        }
    }

    private var railMode: IndexRailMode {
        switch viewModel.globalDictationPhase {
        case .listening:
            return .live(viewModel.globalDictationMeterSamples)
        case .transcribing:
            return .progress(0.55)
        case .inserting:
            return .progress(0.85)
        case .inserted:
            return .progress(1)
        case .failed, .idle:
            return .idleTicks
        }
    }
}

#if canImport(AppKit)
import AppKit

struct GlobalDictationPanelPresenter: NSViewRepresentable {
    @ObservedObject var viewModel: AppViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.update(viewModel: viewModel)
    }

    final class Coordinator {
        private var panel: NSPanel?

        @MainActor
        func update(viewModel: AppViewModel) {
            guard viewModel.isGlobalDictationOverlayVisible else {
                panel?.orderOut(nil)
                return
            }

            let content = GlobalDictationOverlayCard(viewModel: viewModel)
            if let panel {
                if let hostingView = panel.contentView as? NSHostingView<GlobalDictationOverlayCard> {
                    hostingView.rootView = content
                } else {
                    panel.contentView = NSHostingView(rootView: content)
                }
                position(panel)
                panel.orderFrontRegardless()
                return
            }

            let panel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 220),
                styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.isReleasedWhenClosed = false
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: content)
            self.panel = panel
            position(panel)
            panel.orderFrontRegardless()
        }

        @MainActor
        private func position(_ panel: NSPanel) {
            let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
            let size = panel.frame.size
            let x = visibleFrame.maxX - size.width - 28
            let y = visibleFrame.minY + 28
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }
}
#endif
