import SwiftUI

struct ModelStatusCompactPanelView: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var isShowingSettings: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x2) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.x2) {
                CapsLabel(text: "Models")
                Spacer()
                statusBadge
                Button {
                    isShowingSettings = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(SecondaryControlButtonStyle())
                .help("Model and app settings")
            }

            Text(viewModel.modelPreparationStatusLine)
                .font(DS.FontStyle.bodyStrong)
                .foregroundStyle(DS.ColorToken.fgPrimary)
                .lineLimit(1)

            HStack(spacing: DS.Space.x2) {
                Text("Diar \(viewModel.isSpeakerDiarizationEnabled ? "On" : "Off")")
                    .font(DS.FontStyle.mono)
                    .foregroundStyle(DS.ColorToken.fgSecondary)
                if viewModel.isSpeakerDiarizationEnabled {
                    Text("Eng \(viewModel.diarizationEngine.shortLabel)")
                        .font(DS.FontStyle.mono)
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                    Text("Spk \(viewModel.diarizationExpectedSpeakerCountHint.shortLabel)")
                        .font(DS.FontStyle.mono)
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                }
                Text("Live \(viewModel.isLiveTranscriptionEnabled ? "On" : "Off")")
                    .font(DS.FontStyle.mono)
                    .foregroundStyle(DS.ColorToken.fgSecondary)
                Spacer(minLength: 0)
            }
            .lineLimit(1)

            if hasAppFlags {
                HStack(spacing: DS.Space.x2) {
                    if viewModel.isDiarizationDebugExportEnabled {
                        Text("DiarDbg")
                    }
                    if viewModel.isTranscriptConfidenceVisible {
                        Text("Conf On")
                    }
                    if viewModel.isVocabularyBoostingEffectivelyEnabled {
                        Text("Vocab On")
                    }
                    if viewModel.isCustomModelRegistryConfigured {
                        Text("Mirror")
                    }
                    Spacer(minLength: 0)
                }
                .font(DS.FontStyle.mono)
                .foregroundStyle(DS.ColorToken.fgTertiary)
                .lineLimit(1)
            }

            IndexRailView(mode: railMode, height: 7)
        }
        .padding(DS.Space.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsPanelSurface(alt: true, cornerRadius: DS.Radius.md)
        .popover(isPresented: $isShowingSettings, arrowEdge: .leading) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.x3) {
                    HStack {
                        Text("Model & App Settings")
                            .font(DS.FontStyle.panelTitle)
                            .foregroundStyle(DS.ColorToken.fgPrimary)
                        Spacer()
                        Button("Done") {
                            isShowingSettings = false
                        }
                        .buttonStyle(SecondaryControlButtonStyle())
                    }

                    ModelStatusPanelView(viewModel: viewModel)
                }
                .padding(DS.Space.x3)
            }
            .frame(width: 600, height: 660)
            .background(DS.ColorToken.bgApp)
        }
    }

    private var railMode: IndexRailMode {
        if let progress = viewModel.modelPreparationProgress,
           viewModel.modelPreparationState == .preparing || viewModel.modelPreparationState == .ready {
            return .progress(progress)
        }
        return .idleTicks
    }

    private var hasAppFlags: Bool {
        viewModel.isDiarizationDebugExportEnabled
            || viewModel.isTranscriptConfidenceVisible
            || viewModel.isVocabularyBoostingEffectivelyEnabled
            || viewModel.isCustomModelRegistryConfigured
    }

    private var statusBadge: some View {
        let label: String
        switch viewModel.modelPreparationState {
        case .unknown, .idle:
            label = "IDLE"
        case .preparing:
            label = "PREP"
        case .ready:
            label = "READY"
        case .error:
            label = "ERROR"
        }

        return HStack(spacing: 6) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 6, height: 6)
            Text(label)
                .font(DS.FontStyle.control)
                .tracking(0.35)
                .foregroundStyle(DS.ColorToken.fgSecondary)
        }
        .padding(.horizontal, DS.Space.x3)
        .padding(.vertical, DS.Space.x2)
        .frame(minHeight: 32)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .fill(DS.ColorToken.bgPanelAlt)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .stroke(DS.ColorToken.borderStrong, lineWidth: 1)
        )
    }

    private var statusDotColor: Color {
        switch viewModel.modelPreparationState {
        case .ready:
            return DS.ColorToken.statusReady
        case .preparing:
            return DS.ColorToken.statusPreparing
        case .error:
            return DS.ColorToken.statusError
        case .idle, .unknown:
            return DS.ColorToken.statusIdle
        }
    }
}

struct ModelStatusPanelView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var activeTooltipRowID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.x2) {
            HStack(alignment: .firstTextBaseline) {
                CapsLabel(text: "Speech & Models")
                Spacer()
                statusBadge
            }

            modelReadinessSummary

            modelRegistryConfigurationPanel

            VStack(alignment: .leading, spacing: DS.Space.x3) {
                HStack(alignment: .top, spacing: DS.Space.x2) {
                    settingsLabelCell(
                        id: "diar-engine",
                        label: "Diar Engine",
                        tooltip: "Choose which local diarization model Lorre uses for speaker assignment on new processing runs."
                    )

                    Menu {
                        ForEach(DiarizationEngine.allCases, id: \.self) { engine in
                            Button {
                                viewModel.setDiarizationEngine(engine)
                            } label: {
                                HStack {
                                    Text(engine.detailLabel)
                                    if engine == viewModel.diarizationEngine {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: DS.Space.x1_5) {
                            Text(viewModel.diarizationEngine.detailLabel)
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                        }
                    }
                    .buttonStyle(SecondaryControlButtonStyle())
                    .frame(width: settingsToggleColumnWidth, alignment: .leading)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(viewModel.diarizationEngine.settingsSummary)
                            .font(DS.FontStyle.helper)
                            .foregroundStyle(DS.ColorToken.fgSecondary)
                            .lineLimit(2)
                        Text("Current: \(viewModel.diarizationEngine.shortLabel)")
                            .font(DS.FontStyle.mono)
                            .foregroundStyle(DS.ColorToken.fgTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.vertical, DS.Space.x1)
                .zIndex(activeTooltipRowID == "diar-engine" ? 100 : 0)

                toggleSettingsRow(
                    id: "show-confidence",
                    label: "Show Confidence",
                    tooltip: "Shows how sure Lorre is about each transcript line. Helpful when checking for mistakes.",
                    isOn: viewModel.isTranscriptConfidenceVisible,
                    setValue: viewModel.setTranscriptConfidenceVisible
                ) {
                    Text(
                        viewModel.isTranscriptConfidenceVisible
                            ? "Shows confidence under each transcript line."
                            : "Off by default for a cleaner transcript view."
                    )
                    .font(DS.FontStyle.helper)
                    .foregroundStyle(DS.ColorToken.fgSecondary)
                    .lineLimit(2)
                }

                toggleSettingsRow(
                    id: "diar-debug-json",
                    label: "Diar Debug JSON",
                    tooltip: "Saves an extra debug file if speaker labels look wrong. Most people can leave this off.",
                    isOn: viewModel.isDiarizationDebugExportEnabled,
                    setValue: viewModel.setDiarizationDebugExportEnabled
                ) {
                    Text(
                        viewModel.isDiarizationDebugExportEnabled
                            ? "Saves an extra debug file in each session folder."
                            : "Usually not needed unless you are troubleshooting."
                    )
                    .font(DS.FontStyle.helper)
                    .foregroundStyle(DS.ColorToken.fgSecondary)
                    .lineLimit(3)
                }

                toggleSettingsRow(
                    id: "vocab-boosting",
                    label: "Vocab Boosting",
                    tooltip: "Helps Lorre better recognize names and special words from your list below when the runtime supports it.",
                    isOn: viewModel.isVocabularyBoostingAvailable && viewModel.isVocabularyBoostingEnabled,
                    isDisabled: !viewModel.isVocabularyBoostingAvailable,
                    setValue: viewModel.setVocabularyBoostingEnabled
                ) {
                    Text(viewModel.vocabularyBoostingSupportSummary)
                        .font(DS.FontStyle.helper)
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                        .lineLimit(3)
                }

                VStack(alignment: .leading, spacing: DS.Space.x2) {
                    HStack(spacing: DS.Space.x2) {
                        settingsLabelCell(
                            id: "vocab-terms",
                            label: "Vocab Terms",
                            tooltip: "Add words you want Lorre to recognize better. Use one line per word. You can add common alternatives after a colon."
                        )

                        Spacer()
                        Text("\(viewModel.customVocabularyTermLineCount) lines")
                            .font(DS.FontStyle.mono)
                            .foregroundStyle(DS.ColorToken.fgTertiary)
                    }

                    TextEditor(text: $viewModel.customVocabularySimpleFormatTerms)
                        .font(DS.FontStyle.mono)
                        .foregroundStyle(DS.ColorToken.fgPrimary)
                        .scrollContentBackground(.hidden)
                        .padding(DS.Space.x1)
                        .frame(minHeight: 78, maxHeight: 92)
                        .background(DS.ColorToken.fieldBg)
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.sm)
                                .stroke(DS.ColorToken.fieldBorder, lineWidth: 1)
                        )

                    HStack(spacing: DS.Space.x2) {
                        Button(viewModel.isVocabularyBoostingAvailable ? "Save Terms" : "Save Terms for Later") {
                            viewModel.saveCustomVocabularyTerms()
                        }
                        .buttonStyle(SecondaryControlButtonStyle())

                        Text(
                            viewModel.isVocabularyBoostingAvailable
                                ? "One per line. Aliases format: Canonical: alias1, alias2"
                                : "You can still curate the list now. It stays stored until the new SDK vocabulary path is wired back in."
                        )
                        .font(DS.FontStyle.helper)
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                        .lineLimit(2)
                    }
                }
                .padding(.top, DS.Space.x1)
                .zIndex(activeTooltipRowID == "vocab-terms" ? 100 : 0)
            }
            .padding(.top, DS.Space.x1)
            .padding(.bottom, DS.Space.x1)

            IndexRailView(mode: railMode, height: 7)
                .padding(.top, DS.Space.x1)

            HStack(spacing: DS.Space.x2) {
                Button(action: viewModel.prepareModelsTapped) {
                    Text(buttonLabel)
                }
                .buttonStyle(buttonIsPrimary ? AnyButtonStyle(PrimaryControlButtonStyle()) : AnyButtonStyle(SecondaryControlButtonStyle()))
                .disabled(viewModel.modelPreparationState == .preparing)

                if viewModel.modelPreparationState == .preparing {
                    Text("Local download / warmup")
                        .font(DS.FontStyle.mono)
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                }
            }
        }
        .padding(DS.Space.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsPanelSurface(alt: true, cornerRadius: DS.Radius.md)
    }

    private var railMode: IndexRailMode {
        if let progress = viewModel.modelPreparationProgress, viewModel.modelPreparationState == .preparing || viewModel.modelPreparationState == .ready {
            return .progress(progress)
        }
        return .idleTicks
    }

    private var modelReadinessSummary: some View {
        VStack(alignment: .leading, spacing: DS.Space.x2) {
            Text(modelSummaryTitle)
                .font(DS.FontStyle.bodyStrong)
                .foregroundStyle(DS.ColorToken.fgPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(modelSummarySubtitle)
                .font(DS.FontStyle.helper)
                .foregroundStyle(DS.ColorToken.fgSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: DS.Space.x1_5) {
                modelInfoRow(label: "Last prepared", value: modelLastPreparedText)
                modelInfoRow(label: "Includes", value: modelCapabilitiesText)
                modelInfoRow(label: "Processing", value: viewModel.runtimeCapabilities.processingModeDescription)
                modelInfoRow(label: "Registry", value: viewModel.modelRegistrySummaryLabel)
            }

            VStack(alignment: .leading, spacing: 4) {
                CapsLabel(text: "Technical details")
                Text(viewModel.modelPreparationDetailLine)
                    .font(DS.FontStyle.helper)
                    .foregroundStyle(DS.ColorToken.fgSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(viewModel.fluidAudioStatus)
                    .font(DS.FontStyle.mono)
                    .foregroundStyle(DS.ColorToken.fgTertiary)
                    .lineLimit(3)
            }
            .padding(.top, 2)
        }
        .padding(DS.Space.x2)
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
    private func modelInfoRow(label: String, value: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.x2) {
            Text(label)
                .font(DS.FontStyle.helper)
                .foregroundStyle(DS.ColorToken.fgSecondary)
                .frame(width: 92, alignment: .leading)

            Text(value)
                .font(DS.FontStyle.helper)
                .foregroundStyle(DS.ColorToken.fgPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var modelRegistryConfigurationPanel: some View {
        VStack(alignment: .leading, spacing: DS.Space.x2) {
            HStack(spacing: DS.Space.x2) {
                CapsLabel(text: "Model Registry")
                Spacer()
                Text(viewModel.isCustomModelRegistryConfigured ? "CUSTOM" : "DEFAULT")
                    .font(DS.FontStyle.control)
                    .foregroundStyle(DS.ColorToken.fgSecondary)
            }

            TextField("https://huggingface.co", text: $viewModel.modelRegistryCustomBaseURL)
                .textFieldStyle(.plain)
                .font(DS.FontStyle.body)
                .foregroundStyle(DS.ColorToken.fgPrimary)
                .padding(.horizontal, DS.Space.x2)
                .padding(.vertical, DS.Space.x2)
                .background(DS.ColorToken.fieldBg)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.sm)
                        .stroke(DS.ColorToken.fieldBorder, lineWidth: 1)
                )

            HStack(spacing: DS.Space.x2) {
                Button("Save Registry") {
                    viewModel.saveModelRegistryConfiguration()
                }
                .buttonStyle(SecondaryControlButtonStyle())

                Button("Use Default") {
                    viewModel.resetModelRegistryConfiguration()
                }
                .buttonStyle(SecondaryControlButtonStyle())
                .disabled(!viewModel.isCustomModelRegistryConfigured)
            }

            Text("Set a mirror or private registry base URL before downloading models. Leave blank to use the default Hugging Face registry.")
                .font(DS.FontStyle.helper)
                .foregroundStyle(DS.ColorToken.fgSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.x2)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .fill(DS.ColorToken.bgPanelAlt)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .stroke(DS.ColorToken.borderSoft, lineWidth: 1)
        )
    }

    private var modelSummaryTitle: String {
        switch viewModel.modelPreparationState {
        case .ready:
            return "Lorre is ready to transcribe on this Mac."
        case .preparing:
            return "Lorre is preparing the speech tools."
        case .error:
            return "Model setup needs attention."
        case .idle, .unknown:
            return "Models are not prepared yet."
        }
    }

    private var modelSummarySubtitle: String {
        switch viewModel.modelPreparationState {
        case .ready:
            return "You can record and transcribe locally. Audio stays on this device during processing."
        case .preparing:
            return "This may download and warm up models once, so future recordings start faster."
        case .error:
            return "Lorre could not finish model setup. You can try preparing the models again below."
        case .idle, .unknown:
            return "Prepare models once to speed up transcription and speaker recognition on this Mac."
        }
    }

    private var modelLastPreparedText: String {
        guard case .ready = viewModel.modelPreparationState else {
            return "Not prepared yet"
        }

        let prefix = "Last prepared "
        let parts = viewModel.modelPreparationDetailLine.split(separator: "•").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let first = parts.first, first.hasPrefix(prefix) {
            return String(first.dropFirst(prefix.count))
        }
        return "Ready"
    }

    private var modelCapabilitiesText: String {
        let labels = viewModel.runtimeCapabilities.featureLabels
        if labels.isEmpty {
            return "Speech transcription"
        }
        return labels.joined(separator: " • ")
    }

    @ViewBuilder
    private func toggleSettingsRow<Description: View>(
        id: String,
        label: String,
        tooltip: String,
        isOn: Bool,
        isDisabled: Bool = false,
        setValue: @escaping (Bool) -> Void,
        @ViewBuilder description: () -> Description
    ) -> some View {
        HStack(alignment: .top, spacing: DS.Space.x2) {
            settingsLabelCell(id: id, label: label, tooltip: tooltip)

            InlineBooleanSettingControl(
                isOn: isOn,
                isDisabled: isDisabled,
                setValue: setValue
            )
            .frame(width: settingsToggleColumnWidth, alignment: .leading)

            description()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, DS.Space.x1)
        .zIndex(activeTooltipRowID == id ? 100 : 0)
    }

    private func settingsLabelCell(id: String, label: String, tooltip: String) -> some View {
        HStack(spacing: DS.Space.x1_5) {
            CapsLabel(text: label)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: settingsLabelTextColumnWidth, alignment: .leading)

            SettingsInfoTooltipIcon(message: tooltip) { isHovering in
                if isHovering {
                    activeTooltipRowID = id
                } else if activeTooltipRowID == id {
                    activeTooltipRowID = nil
                }
            }
            .frame(width: settingsTooltipColumnWidth, alignment: .center)
        }
        .frame(width: settingsLabelColumnWidth, alignment: .leading)
    }

    private var settingsLabelTextColumnWidth: CGFloat { 132 }
    private var settingsTooltipColumnWidth: CGFloat { 16 }
    private var settingsLabelColumnWidth: CGFloat { settingsLabelTextColumnWidth + settingsTooltipColumnWidth + DS.Space.x1_5 }
    private var settingsToggleColumnWidth: CGFloat { 110 }

    private var statusBadge: some View {
        let label: String
        switch viewModel.modelPreparationState {
        case .unknown, .idle:
            label = "IDLE"
        case .preparing:
            label = "PREPARING"
        case .ready:
            label = "READY"
        case .error:
            label = "ERROR"
        }

        return HStack(spacing: 6) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 6, height: 6)
            Text(label)
                .font(DS.FontStyle.control)
                .tracking(0.35)
                .foregroundStyle(DS.ColorToken.fgSecondary)
        }
        .padding(.horizontal, DS.Space.x3)
        .padding(.vertical, DS.Space.x2)
        .frame(minHeight: 32)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .fill(DS.ColorToken.bgPanelAlt)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .stroke(DS.ColorToken.borderStrong, lineWidth: 1)
        )
    }

    private var statusDotColor: Color {
        switch viewModel.modelPreparationState {
        case .ready:
            return DS.ColorToken.statusReady
        case .preparing:
            return DS.ColorToken.statusPreparing
        case .error:
            return DS.ColorToken.statusError
        case .idle, .unknown:
            return DS.ColorToken.statusIdle
        }
    }

    private var buttonLabel: String {
        switch viewModel.modelPreparationState {
        case .ready:
            return "Re-prepare Models"
        case .preparing:
            return "Preparing…"
        default:
            return "Prepare Models"
        }
    }

    private var buttonIsPrimary: Bool {
        switch viewModel.modelPreparationState {
        case .idle, .unknown, .error:
            return true
        case .preparing, .ready:
            return false
        }
    }
}

private struct InlineBooleanSettingControl: View {
    let isOn: Bool
    var isDisabled: Bool = false
    let setValue: (Bool) -> Void

    var body: some View {
        HStack(spacing: 2) {
            segment(title: "Off", selected: !isOn) { setValue(false) }
            segment(title: "On", selected: isOn) { setValue(true) }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .fill(DS.ColorToken.bgPanelAlt)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                .stroke(DS.ColorToken.borderSoft, lineWidth: 1)
        )
        .opacity(isDisabled ? 0.55 : 1)
        .disabled(isDisabled)
    }

    private func segment(title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(DS.FontStyle.control)
                .foregroundStyle(selected ? DS.ColorToken.white : DS.ColorToken.fgPrimary)
                .frame(minWidth: 38)
                .padding(.horizontal, DS.Space.x2)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: max(6, DS.Radius.sm - 2), style: .continuous)
                        .fill(selected ? DS.ColorToken.black : .clear)
                )
        }
        .buttonStyle(.plain)
    }
}

private struct SettingsInfoTooltipIcon: View {
    let message: String
    var onHoverChanged: ((Bool) -> Void)? = nil
    @State private var isShowingTooltip = false

    var body: some View {
        Image(systemName: "questionmark.circle")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(DS.ColorToken.fgTertiary)
            .frame(width: 16, height: 16, alignment: .center)
            .contentShape(Rectangle())
            .accessibilityLabel("More info")
            .accessibilityHint(message)
            #if os(macOS)
            .onHover { isHovering in
                isShowingTooltip = isHovering
                onHoverChanged?(isHovering)
            }
            #endif
            .popover(isPresented: $isShowingTooltip, arrowEdge: .bottom) {
                tooltipBubble
                    .padding(DS.Space.x2)
                    .frame(width: 300, alignment: .leading)
                    .background(DS.ColorToken.bgPanel)
            }
            .zIndex(isShowingTooltip ? 100 : 0)
    }

    private var tooltipBubble: some View {
        Text(message)
            .font(DS.FontStyle.helper)
            .foregroundStyle(DS.ColorToken.fgPrimary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Space.x2)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .fill(DS.ColorToken.bgPanelAlt)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.sm, style: .continuous)
                    .stroke(DS.ColorToken.borderStrong, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 8, x: 0, y: 4)
    }
}

private struct AnyButtonStyle: ButtonStyle {
    private let makeBodyClosure: (Configuration) -> AnyView

    init<S: ButtonStyle>(_ style: S) {
        self.makeBodyClosure = { configuration in
            AnyView(style.makeBody(configuration: configuration))
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        makeBodyClosure(configuration)
    }
}
