import AppKit
import XCTest
@testable import ClashBar

@MainActor
final class BrandIconRenderingTests: XCTestCase {
    func testIconStateFollowsCoreAndProxySwitches() {
        let cases: [(Bool, Bool, Bool, MenuBarIconState)] = [
            (false, false, false, .sleep),
            (false, true, false, .sleep),
            (false, false, true, .sleep),
            (false, true, true, .sleep),
            (true, false, false, .sleep),
            (true, true, false, .run),
            (true, false, true, .tun),
            (true, true, true, .tun),
        ]
        for (running, proxy, tun, expected) in cases {
            let display = self.display(running: running, proxy: proxy, tun: tun)
            XCTAssertEqual(display.iconState, expected)
            let warning = self.display(running: running, proxy: proxy, tun: tun, hasWarning: true)
            XCTAssertEqual(warning.iconState, .warning)
            XCTAssertNotEqual(display, warning)
        }
    }

    func testBrandImagesLoadWithPerStateRenderingAndTransparency() throws {
        let images: [(NSImage?, Bool)] = [
            (BrandIcon.appImage, false),
            (BrandIcon.headerImage(for: .sleep), true),
            (BrandIcon.headerImage(for: .run), false),
            (BrandIcon.headerImage(for: .tun), false),
            (BrandIcon.headerImage(for: .warning), false),
            (BrandIcon.runImage, true),
            (BrandIcon.sleepImage, true),
            (BrandIcon.tunImage, true),
            (BrandIcon.warningImage, true),
        ]
        for (image, isTemplate) in images {
            let source = try XCTUnwrap(image)
            XCTAssertEqual(source.isTemplate, isTemplate)
            let data = try XCTUnwrap(source.tiffRepresentation)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: data))
            XCTAssertTrue(bitmap.hasAlpha)
            XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)).alphaComponent, 0.01)
        }
    }

    func testAllStatesRenderAsNeutralTemplatesInBothAppearances() throws {
        _ = NSApplication.shared
        let renderer = StatusItemContentView()
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            for mode in [StatusBarDisplayMode.iconOnly, .iconAndSpeed] {
                for display in [
                    self.display(mode: mode, proxy: false),
                    self.display(mode: mode),
                    self.display(mode: mode, proxy: false, tun: true),
                    self.display(mode: mode, hasWarning: true),
                ] {
                    renderer.apply(display: display, appearance: appearance)
                    let image = try XCTUnwrap(renderer.image)
                    XCTAssertTrue(image.isTemplate)
                    let iconWidth: CGFloat = display.iconState == .tun ? 28 : 24
                    XCTAssertEqual(image.size.width, iconWidth + (mode == .iconAndSpeed ? 43 : 0))
                    XCTAssertEqual(try self.coloredPixelCount(image), 0)
                    let bitmap = try self.bitmap(image)
                    let topEdgeAlpha = try (0..<min(72, bitmap.pixelsWide)).map { column in
                        try XCTUnwrap(bitmap.colorAt(x: column, y: 0)).alphaComponent
                    }.max() ?? 0
                    XCTAssertLessThan(topEdgeAlpha, 0.99, "The icon should fit without clipping its ears")
                    try self.savePreview(image, name: "\(appearanceName.rawValue)-\(mode.rawValue)-\(display.iconState)")
                }
            }
        }
    }

    func testSwitchingStatesKeepsTemplateRendering() throws {
        _ = NSApplication.shared
        let renderer = StatusItemContentView()
        let displays = [
            self.display(proxy: false),
            self.display(),
            self.display(hasWarning: true),
            self.display(proxy: false, tun: true),
            self.display(proxy: false),
        ]
        for display in displays {
            renderer.apply(display: display)
            let image = try XCTUnwrap(renderer.image)
            XCTAssertTrue(image.isTemplate)
        }
    }

    func testSolidStatesKeepTransparentEyesMouthAndShield() throws {
        for (image, masterWidth) in [(BrandIcon.runImage, 112), (BrandIcon.tunImage, 128)] {
            let source = try XCTUnwrap(image)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(source.tiffRepresentation)))
            for point in [(35, 46), (77, 46), (52, 65)] {
                let column = point.0 * bitmap.pixelsWide / masterWidth
                let row = point.1 * bitmap.pixelsHigh / 88
                XCTAssertLessThan(try XCTUnwrap(bitmap.colorAt(x: column, y: row)).alphaComponent, 0.05)
            }
            XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 55 * bitmap.pixelsWide / masterWidth, y: 30 * bitmap.pixelsHigh / 88)).alphaComponent, 0.95)
        }
        let tun = try XCTUnwrap(BrandIcon.tunImage)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(tun.tiffRepresentation)))
        let leftHalf = try XCTUnwrap(bitmap.colorAt(x: 87 * bitmap.pixelsWide / 128, y: 66 * bitmap.pixelsHigh / 88))
        let rightHalf = try XCTUnwrap(bitmap.colorAt(x: 96 * bitmap.pixelsWide / 128, y: 66 * bitmap.pixelsHigh / 88))
        XCTAssertLessThan(leftHalf.alphaComponent, 0.05)
        XCTAssertGreaterThan(rightHalf.alphaComponent, 0.95)
    }

    func testPanelSleepUsesLatestMenuBarTemplateArtwork() throws {
        let panel = try XCTUnwrap(BrandIcon.headerImage(for: .sleep))
        let menuBar = try XCTUnwrap(BrandIcon.sleepImage)
        XCTAssertFalse(panel === menuBar)
        XCTAssertEqual(panel.tiffRepresentation, menuBar.tiffRepresentation)
        XCTAssertTrue(panel.isTemplate)
    }

    func testPanelWarningUsesBadgeFreeMenuBarArtwork() throws {
        let panel = try XCTUnwrap(BrandIcon.headerImage(for: .warning))
        let menuBar = try XCTUnwrap(BrandIcon.warningImage)
        let panelBitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(panel.tiffRepresentation)))
        let menuBarBitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(menuBar.tiffRepresentation)))

        XCTAssertEqual(panelBitmap.pixelsWide, menuBarBitmap.pixelsWide)
        XCTAssertEqual(panelBitmap.pixelsHigh, menuBarBitmap.pixelsHigh)
        for row in 0..<panelBitmap.pixelsHigh {
            for column in 0..<panelBitmap.pixelsWide {
                let panelAlpha = try XCTUnwrap(panelBitmap.colorAt(x: column, y: row)).alphaComponent
                let menuBarAlpha = try XCTUnwrap(menuBarBitmap.colorAt(x: column, y: row)).alphaComponent
                XCTAssertEqual(panelAlpha, menuBarAlpha, accuracy: 1 / 255)
            }
        }
    }

    func testIconInkFitsEighteenPointsAndStaysVerticallyCentered() throws {
        _ = NSApplication.shared
        let renderer = StatusItemContentView()
        for display in [self.display(proxy: false), self.display(), self.display(tun: true), self.display(hasWarning: true)] {
            renderer.apply(display: display)
            let image = try XCTUnwrap(renderer.image)
            for bitmap in image.representations.compactMap({ $0 as? NSBitmapImageRep }) {
                let scale = CGFloat(bitmap.pixelsHigh) / image.size.height
                var occupiedRows: [Int] = []
                for row in 0..<bitmap.pixelsHigh {
                    for column in 0..<bitmap.pixelsWide {
                        if try XCTUnwrap(bitmap.colorAt(x: column, y: row)).alphaComponent > 0.1 {
                            occupiedRows.append(row)
                            break
                        }
                    }
                }
                let firstRow = try XCTUnwrap(occupiedRows.first)
                let lastRow = try XCTUnwrap(occupiedRows.last)
                let height = CGFloat(lastRow - firstRow + 1) / scale
                XCTAssertGreaterThan(height, 15)
                XCTAssertLessThanOrEqual(height, 18 + 1 / scale)
                let center = CGFloat(firstRow + lastRow + 1) / (2 * scale)
                XCTAssertEqual(center, image.size.height / 2, accuracy: 1)
            }
        }
    }

    func testSpeedTextAdaptsToMenuBarAppearance() throws {
        _ = NSApplication.shared
        let renderer = StatusItemContentView()
        var brightness: [CGFloat] = []
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            renderer.apply(display: self.display(mode: .speedOnly), appearance: try XCTUnwrap(NSAppearance(named: appearanceName)))
            let bitmap = try self.bitmap(try XCTUnwrap(renderer.image))
            var values: [CGFloat] = []
            for row in 0..<bitmap.pixelsHigh {
                for column in 0..<bitmap.pixelsWide {
                    let color = try XCTUnwrap(bitmap.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB))
                    if color.alphaComponent > 0.8 {
                        values.append((color.redComponent + color.greenComponent + color.blueComponent) / 3)
                    }
                }
            }
            XCTAssertFalse(values.isEmpty)
            brightness.append(values.reduce(0, +) / CGFloat(max(values.count, 1)))
        }
        XCTAssertGreaterThan(brightness[1] - brightness[0], 0.5)
    }

    private func display(
        mode: StatusBarDisplayMode = .iconOnly,
        running: Bool = true,
        proxy: Bool = true,
        tun: Bool = false,
        hasWarning: Bool = false) -> MenuBarDisplay
    {
        MenuBarDisplay(
            mode: mode,
            symbolName: "bolt.horizontal.circle.fill",
            speedLines: mode == .iconOnly ? nil : MenuBarSpeedLines(up: "12K↑", down: "34K↓"),
            isRunning: running,
            isSystemProxyEnabled: proxy,
            isTunEnabled: tun,
            hasWarning: hasWarning)
    }

    private func bitmap(_ image: NSImage) throws -> NSBitmapImageRep {
        try XCTUnwrap(image.representations.compactMap { $0 as? NSBitmapImageRep }.last)
    }

    private func coloredPixelCount(_ image: NSImage) throws -> Int {
        let bitmap = try self.bitmap(image)
        var count = 0
        for row in 0..<bitmap.pixelsHigh {
            for column in 0..<bitmap.pixelsWide {
                let color = try XCTUnwrap(bitmap.colorAt(x: column, y: row)?.usingColorSpace(.deviceRGB))
                let components = [color.redComponent, color.greenComponent, color.blueComponent]
                if color.alphaComponent > 0.5,
                   (components.max() ?? 0) - (components.min() ?? 0) > 0.02
                {
                    count += 1
                }
            }
        }
        return count
    }

    private func savePreview(_ image: NSImage, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["CLASHBAR_ICON_PREVIEW_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try XCTUnwrap(try self.bitmap(image).representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
