import SwiftUI

// swiftlint:disable:next type_name
private typealias T = MenuBarLayoutTokens

extension MenuBarRootView {
    private struct SegmentedControlStyle {
        let isMode: Bool

        static let mode = SegmentedControlStyle(isMode: true)
        static let tab = SegmentedControlStyle(isMode: false)

        var selectionBackgroundID: String {
            self.isMode ? "mode-segmented-selection-background" : "tab-segmented-selection-background"
        }

        var selectionIndicatorID: String {
            self.isMode ? "mode-segmented-selection-indicator" : "tab-segmented-selection-indicator"
        }

        var indicatorWidth: CGFloat {
            self.isMode ? 0 : 16
        }

        var indicatorBottomPadding: CGFloat {
            self.isMode ? 0 : 2
        }

        var cornerRadius: CGFloat {
            self.isMode ? 8 : 0
        }

        var rowHeight: CGFloat {
            self.isMode ? 28 : 26
        }

        var contentVerticalPadding: CGFloat {
            2
        }

        func selectedFillOpacity(isDark: Bool) -> CGFloat {
            self.isMode ? (isDark ? 0.24 : 0.16) : (isDark ? 0.22 : 0.12)
        }

        func selectedBorderOpacity(isDark: Bool) -> CGFloat {
            self.isMode ? 0 : (isDark ? 0.20 : 0.14)
        }

        func hoverFillOpacity(isDark: Bool) -> CGFloat {
            self.isMode ? (isDark ? 0.10 : 0.07) : 0
        }

        func selectedForegroundOpacity(isDark: Bool) -> CGFloat {
            self.isMode ? (isDark ? 1.0 : 0.98) : (isDark ? 0.96 : 0.92)
        }

        func selectedIconOpacity(isDark: Bool) -> CGFloat {
            self.isMode ? 1.0 : (isDark ? 0.98 : 0.94)
        }
    }

    var modeAndTabSection: some View {
        VStack(spacing: T.space2) {
            HStack(spacing: T.space6) {
                self.modeSwitcher

                Spacer(minLength: 0)

                self.modeActionButtons
            }
            self.topTabs
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var modeSwitcher: some View {
        HStack(spacing: 0) {
            self.modeSegmentButton(
                title: tr("ui.mode.rule"),
                mode: .rule,
                symbol: "shield.lefthalf.filled")
            self.modeSegmentButton(
                title: tr("ui.mode.global"),
                mode: .global,
                symbol: "globe")
            self.modeSegmentButton(
                title: tr("ui.mode.direct"),
                mode: .direct,
                symbol: "bolt.fill")
        }
        .padding(.horizontal, 5)
        .padding(.vertical, T.space4)
        .frame(width: 170)
        .background {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    Color(nsColor: .controlBackgroundColor)
                        .opacity(self.isDarkAppearance ? 0.78 : 0.92))
                .overlay {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(
                            self.nativeControlBorder.opacity(self.isDarkAppearance ? 0.48 : 0.22),
                            lineWidth: T.stroke)
                }
        }
    }

    var modeActionButtons: some View {
        let coreIsRunning = self.appViewModel.isRuntimeRunning
        let coreIsUnavailable = !self.appViewModel.isRemoteTarget
            && !coreIsRunning
            && !self.appViewModel.isMihomoCoreAvailable

        return HStack(spacing: T.space2) {
            self.modeActionButton(
                id: "webui",
                symbol: "globe.americas.fill",
                title: self.tr("ui.action.open_webui"),
                tint: nativeInfo,
                isDisabled: self.isSwitchingMachine)
            {
                self.appViewModel.openControllerWebUI()
            }

            self.modeActionButton(
                id: "core",
                symbol: coreIsRunning
                    ? "stop.circle"
                    : coreIsUnavailable ? "exclamationmark.triangle" : "play.circle",
                title: self.appViewModel.isCoreActionProcessing
                    ? self.tr("app.primary.processing")
                    : coreIsRunning
                    ? self.tr("ui.action.stop_core")
                    : coreIsUnavailable
                    ? self.tr("ui.action.core_unavailable")
                    : self.tr("ui.action.start_core"),
                tint: coreIsRunning ? nativeWarning : coreIsUnavailable ? nativeWarning : nativePositive,
                isDisabled: self.appViewModel.isRemoteTarget,
                isUnavailable: coreIsUnavailable,
                helpText: coreIsUnavailable
                    ? self.tr(
                        "app.core.setup_required.message",
                        self.appViewModel.workingDirectoryManager.coreDirectoryURL.path)
                    : nil,
                isLoading: self.appViewModel.isCoreActionProcessing)
            {
                if self.appViewModel.isRuntimeRunning {
                    await self.appViewModel.stopCore()
                } else {
                    await self.appViewModel.startCore(trigger: .manual)
                }
            }
        }
        .padding(T.space1)
        .frame(width: 168)
        .background(self.nativeControlSurface(cornerRadius: SegmentedControlStyle.mode.cornerRadius))
    }

    func modeActionButton(
        id: String,
        symbol: String,
        title: String,
        tint: Color,
        isDisabled: Bool = false,
        isUnavailable: Bool = false,
        helpText: String? = nil,
        isLoading: Bool = false,
        action: @escaping () async -> Void) -> some View
    {
        let hovered = self.hoveredModeAction == id
        let disabled = isDisabled || isUnavailable || isLoading

        return Button {
            Task { await action() }
        } label: {
            HStack(spacing: T.space2) {
                if isLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(tint)
                } else {
                    Image(systemName: symbol)
                        .font(.app(size: T.FontSize.caption, weight: .semibold))
                        .foregroundStyle(isUnavailable ? tint.opacity(0.78) : disabled ? nativeTertiaryLabel : tint)
                }

                Text(title)
                    .font(.app(size: T.FontSize.caption, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .foregroundStyle(isUnavailable ? nativeSecondaryLabel : disabled ? nativeTertiaryLabel :
                        (hovered ? nativePrimaryLabel : nativeSecondaryLabel))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovered && !disabled ? nativeHoverFill.opacity(isDarkAppearance ? 0.9 : 0.7) : .clear)
            }
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(isUnavailable ? 0.9 : disabled ? 0.78 : 1)
        .help(helpText ?? title)
        .accessibilityLabel(title)
        .onHover { isHovering in
            self.hoveredModeAction = isHovering ? id :
                (self.hoveredModeAction == id ? nil : self.hoveredModeAction)
        }
    }

    func modeSegmentButton(title: String, mode: CoreMode, symbol: String) -> some View {
        let style = SegmentedControlStyle.mode
        let selected = appViewModel.currentMode == mode
        let switchingThisMode = switchingMode == mode
        let isEnabled = appViewModel.isModeSwitchEnabled && switchingMode == nil
        let hovered = isEnabled && hoveredMode == mode

        return Button {
            guard appViewModel.isModeSwitchEnabled, switchingMode == nil,
                  mode != appViewModel.currentMode else { return }

            switchingMode = mode
            Task { @MainActor in
                await appViewModel.switchMode(to: mode)
                switchingMode = nil
            }
        } label: {
            ZStack(alignment: .bottom) {
                HStack(spacing: T.space4) {
                    if switchingThisMode {
                        ProgressView()
                            .controlSize(.small)
                            .tint(self.segmentedAccentColor(style: style))
                    } else {
                        Image(systemName: symbol)
                            .font(.app(size: T.FontSize.caption, weight: .bold))
                            .foregroundStyle(self.segmentedIconColor(
                                style: style,
                                selected: selected,
                                hovered: hovered,
                                enabled: isEnabled))
                    }

                    Text(title)
                        .font(.app(size: T.FontSize.caption, weight: .semibold))
                        .lineLimit(1)
                        .foregroundStyle(self.segmentedLabelColor(
                            style: style,
                            selected: selected,
                            hovered: hovered,
                            enabled: isEnabled))
                }
                .padding(.vertical, style.contentVerticalPadding)
                .frame(maxWidth: .infinity)
                .frame(height: style.rowHeight)
                .background(self.segmentedButtonBackground(
                    style: style,
                    selected: selected,
                    hovered: hovered,
                    enabled: isEnabled))
                .contentShape(RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.94)
        .onHover { hoveredMode = self.nextHovered(current: hoveredMode, target: mode, isHovering: $0) }
        .animation(.snappy(duration: 0.18), value: appViewModel.currentMode)
        .animation(.easeOut(duration: 0.12), value: hoveredMode)
    }

    var topTabs: some View {
        HStack(spacing: T.space2) {
            ForEach(RootTab.allCases, id: \.self) { tab in
                self.tabSegmentButton(tab)
            }
        }
        .frame(width: contentWidth)
    }

    func tabSegmentButton(_ tab: RootTab) -> some View {
        let style = SegmentedControlStyle.tab
        let selected = self.rootViewModel.currentTab == tab
        let hovered = hoveredTab == tab

        return Button {
            guard self.rootViewModel.currentTab != tab else { return }
            withAnimation(.snappy(duration: 0.18)) {
                self.rootViewModel.syncCurrentTab(tab)
            }
        } label: {
            ZStack(alignment: .bottom) {
                Text(self.tr(tab.titleKey))
                    .font(.app(size: T.FontSize.body, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(T.minimumScale)
                    .foregroundStyle(self.segmentedLabelColor(style: style, selected: selected, hovered: hovered))
                    .frame(maxWidth: .infinity)
                    .frame(height: style.rowHeight)

                if selected {
                    Capsule(style: .continuous)
                        .fill(self.segmentedAccentColor(style: style))
                        .frame(width: style.indicatorWidth, height: 2)
                        .padding(.bottom, style.indicatorBottomPadding)
                        .matchedGeometryEffect(id: style.selectionIndicatorID, in: self.segmentedSelectionNamespace)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoveredTab = self.nextHovered(current: hoveredTab, target: tab, isHovering: $0) }
        .animation(.snappy(duration: 0.18), value: self.rootViewModel.currentTab)
        .animation(.easeOut(duration: 0.12), value: hoveredTab)
    }

    @ViewBuilder
    private func segmentedButtonBackground(
        style: SegmentedControlStyle,
        selected: Bool,
        hovered: Bool,
        enabled: Bool = true) -> some View
    {
        let shape = RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
        if selected, style.isMode {
            let fill = enabled
                ? self.nativeHoverFill.opacity(isDarkAppearance ? 0.22 : 0.14)
                : self.nativeControlFill.opacity(isDarkAppearance ? 0.56 : 0.72)
            let border = enabled
                ? self.nativeHoverFill.opacity(isDarkAppearance ? 0.38 : 0.24)
                : self.nativeControlBorder.opacity(isDarkAppearance ? 0.24 : 0.18)
            shape
                .fill(fill)
                .overlay {
                    shape.stroke(
                        border,
                        lineWidth: enabled ? 0 : T.stroke)
                }
                .matchedGeometryEffect(id: style.selectionBackgroundID, in: self.segmentedSelectionNamespace)
        } else if hovered {
            shape.fill(self.segmentedHoverFill(style: style))
        } else {
            Color.clear
        }
    }

    private func segmentedLabelColor(
        style: SegmentedControlStyle,
        selected: Bool,
        hovered: Bool,
        enabled: Bool = true) -> Color
    {
        guard enabled else {
            return nativePrimaryLabel.opacity(
                selected
                    ? (isDarkAppearance ? 0.82 : 0.72)
                    : (isDarkAppearance ? 0.68 : 0.56))
        }

        if selected {
            return style.isMode
                ? nativePrimaryLabel
                : nativePrimaryLabel
        }
        if hovered {
            return nativePrimaryLabel.opacity(isDarkAppearance ? 0.82 : (style.isMode ? 0.72 : 0.74))
        }
        return nativeSecondaryLabel
    }

    private func segmentedIconColor(
        style: SegmentedControlStyle,
        selected: Bool,
        hovered: Bool,
        enabled: Bool = true) -> Color
    {
        guard enabled else {
            return nativePrimaryLabel.opacity(
                selected
                    ? (isDarkAppearance ? 0.82 : 0.72)
                    : (isDarkAppearance ? 0.68 : 0.56))
        }

        if selected {
            return style.isMode
                ? nativePrimaryLabel
                : self.segmentedSelectedForeground(style: style)
        }
        if hovered {
            return nativeSecondaryLabel.opacity(isDarkAppearance ? 0.96 : 0.84)
        }
        return nativeTertiaryLabel
    }

    private func segmentedAccentColor(style: SegmentedControlStyle) -> Color {
        let accent = self.appViewModel.appTheme.palette(isDark: self.isDarkAppearance).accent
        return style.isMode ? accent : accent.opacity(0.88)
    }

    private func segmentedSelectionFill(style: SegmentedControlStyle) -> Color {
        self.segmentedAccentColor(style: style).opacity(style.selectedFillOpacity(isDark: isDarkAppearance))
    }

    private func segmentedSelectionBorder(style: SegmentedControlStyle) -> Color {
        self.segmentedAccentColor(style: style).opacity(style.selectedBorderOpacity(isDark: isDarkAppearance))
    }

    private func segmentedHoverFill(style: SegmentedControlStyle) -> Color {
        nativeHoverFill.opacity(style.hoverFillOpacity(isDark: isDarkAppearance))
    }

    private func segmentedSelectedForeground(style: SegmentedControlStyle) -> Color {
        self.segmentedAccentColor(style: style)
            .opacity(style.selectedForegroundOpacity(isDark: self.isDarkAppearance))
    }
}
