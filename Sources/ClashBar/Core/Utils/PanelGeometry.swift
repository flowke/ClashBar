import AppKit

enum PanelAttachmentSide: Equatable {
    case left
    case right
}

struct PanelPlacement: Equatable {
    let frame: CGRect
    let lockedOriginX: CGFloat?
    let attachmentSide: PanelAttachmentSide?
}

struct MenuBarDropdownPlacementOptions {
    let horizontalPadding: CGFloat
    let verticalSpacing: CGFloat
    let screenPadding: CGFloat
    let lockedOriginX: CGFloat?
    let preserveHorizontalPosition: Bool
}

struct PanelAnchorContext {
    let visibleFrame: CGRect
    let anchorFrameOnScreen: CGRect
    let hostWindowFrame: CGRect?

    @MainActor
    static func resolve(for anchorView: NSView?) -> PanelAnchorContext? {
        guard
            let anchorView,
            let hostWindow = anchorView.window
        else {
            return nil
        }

        let screen = hostWindow.screen ?? NSScreen.main
        guard let screen else { return nil }

        let anchorFrameInWindow = anchorView.convert(anchorView.bounds, to: nil)
        let anchorFrameOnScreen = hostWindow.convertToScreen(anchorFrameInWindow)

        return PanelAnchorContext(
            visibleFrame: screen.visibleFrame,
            anchorFrameOnScreen: anchorFrameOnScreen,
            hostWindowFrame: hostWindow.frame)
    }

    var statusBarBottomY: CGFloat {
        self.visibleFrame.maxY
    }

    func maximumHeightBelowMenuBar(screenPadding: CGFloat, verticalSpacing: CGFloat) -> CGFloat {
        let availableHeightBelowStatusBar = self.statusBarBottomY - self.visibleFrame.minY - screenPadding -
            verticalSpacing
        let visibleHeight = self.visibleFrame.height - screenPadding

        return max(1, min(availableHeightBelowStatusBar, visibleHeight).rounded(.down))
    }

    func menuBarDropdownPlacement(
        panelSize: CGSize,
        options: MenuBarDropdownPlacementOptions)
        -> PanelPlacement
    {
        let minX = self.visibleFrame.minX + options.horizontalPadding
        let maxX = self.visibleFrame.maxX - options.horizontalPadding - panelSize.width

        let centeredX = self.anchorFrameOnScreen.midX - panelSize.width / 2
        let stableX = options.preserveHorizontalPosition ? (options.lockedOriginX ?? centeredX) : centeredX
        let clampedX = min(max(stableX, minX), maxX)

        let anchorTopY = self.statusBarBottomY - options.verticalSpacing
        let minY = self.visibleFrame.minY + options.screenPadding
        let clampedY = max(minY, anchorTopY - panelSize.height)

        return PanelPlacement(
            frame: CGRect(origin: CGPoint(x: clampedX, y: clampedY), size: panelSize),
            lockedOriginX: clampedX,
            attachmentSide: nil)
    }

    func centeredWindowPlacement(panelSize: CGSize, screenPadding: CGFloat) -> PanelPlacement {
        let availableWidth = max(1, self.visibleFrame.width - screenPadding * 2)
        let availableHeight = max(1, self.visibleFrame.height - screenPadding * 2)
        let size = CGSize(
            width: min(panelSize.width, availableWidth),
            height: min(panelSize.height, availableHeight))
        let center = CGPoint(
            x: self.hostWindowFrame?.midX ?? self.anchorFrameOnScreen.midX,
            y: self.hostWindowFrame?.midY ?? self.anchorFrameOnScreen.midY)
        let minX = self.visibleFrame.minX + screenPadding
        let maxX = max(minX, self.visibleFrame.maxX - screenPadding - size.width)
        let minY = self.visibleFrame.minY + screenPadding
        let maxY = max(minY, self.visibleFrame.maxY - screenPadding - size.height)
        let origin = CGPoint(
            x: min(max(center.x - size.width / 2, minX), maxX),
            y: min(max(center.y - size.height / 2, minY), maxY))

        return PanelPlacement(
            frame: CGRect(origin: origin, size: size),
            lockedOriginX: nil,
            attachmentSide: nil)
    }

    func sideAttachedPlacement(
        contentSize: CGSize,
        preferredWidth: CGFloat?,
        lockedWidth: CGFloat? = nil,
        maximumWidth: CGFloat? = nil,
        maximumHeight: CGFloat?,
        screenPadding: CGFloat,
        edgeOverlap: CGFloat,
        preferredAttachmentSide: PanelAttachmentSide? = nil)
        -> PanelPlacement?
    {
        guard let hostWindowFrame else { return nil }

        let contentWidth = lockedWidth ?? preferredWidth ?? contentSize.width
        let panelWidth = min(
            max(1, contentWidth),
            max(1, maximumWidth ?? .greatestFiniteMagnitude),
            self.visibleFrame.width - (screenPadding * 2))

        let preferredHeight: CGFloat = if let maximumHeight {
            min(contentSize.height, maximumHeight + (screenPadding * 2))
        } else {
            contentSize.height
        }
        let panelHeight = min(max(40, preferredHeight), self.visibleFrame.height - (screenPadding * 2))

        let rightAvailable = max(0, self.visibleFrame.maxX - hostWindowFrame.maxX)
        let leftAvailable = max(0, hostWindowFrame.minX - self.visibleFrame.minX)

        let attachmentSide: PanelAttachmentSide = {
            if let preferredAttachmentSide {
                let preferredAvailable = preferredAttachmentSide == .right ? rightAvailable : leftAvailable
                if preferredAvailable >= panelWidth {
                    return preferredAttachmentSide
                }
            }

            if rightAvailable >= panelWidth {
                return .right
            }
            if leftAvailable >= panelWidth {
                return .left
            }
            return rightAvailable >= leftAvailable ? .right : .left
        }()

        let sideAvailable = attachmentSide == .right ? rightAvailable : leftAvailable
        let resolvedPanelWidth = max(1, min(panelWidth, sideAvailable))
        let panelSize = CGSize(width: resolvedPanelWidth, height: panelHeight)

        let rawOriginX: CGFloat = switch attachmentSide {
        case .right:
            hostWindowFrame.maxX - edgeOverlap
        case .left:
            hostWindowFrame.minX - panelSize.width + edgeOverlap
        }
        let minX = self.visibleFrame.minX + screenPadding
        let maxX = self.visibleFrame.maxX - screenPadding - panelSize.width
        let clampedX = max(minX, min(rawOriginX, maxX))

        let desiredY = self.anchorFrameOnScreen.midY - panelSize.height / 2
        let minY = self.visibleFrame.minY + screenPadding
        let maxY = self.visibleFrame.maxY - screenPadding - panelSize.height
        let clampedY = max(minY, min(desiredY, maxY))

        return PanelPlacement(
            frame: CGRect(origin: CGPoint(x: clampedX, y: clampedY), size: panelSize),
            lockedOriginX: nil,
            attachmentSide: attachmentSide)
    }
}
