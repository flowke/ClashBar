import AppKit

@MainActor
enum BrandIcon {
    static let image: NSImage? = loadIcon(named: "BrandLogo", fallbackFileName: "logo.png")
    static let appImage: NSImage? = loadIcon(named: "BrandAppIcon", fallbackFileName: "app-icon.png")
    // Sleep and warning panel variants use G artwork with panel-specific rendering.
    private static let headerSleepImage: NSImage? = loadIcon(named: "BrandHeaderSleep", fallbackFileName: "logo-header-sleep.png", isTemplate: true)
    private static let headerRunImage: NSImage? = loadIcon(named: "BrandHeader", fallbackFileName: "logo-header.png")
    private static let headerTunImage: NSImage? = loadIcon(named: "BrandHeaderTun", fallbackFileName: "logo-header-tun.png")
    private static let headerWarningImage: NSImage? = loadIcon(named: "BrandHeaderWarning", fallbackFileName: "logo-header-warning.png")
    static let runImage: NSImage? = loadIcon(named: "BrandRun", fallbackFileName: "icon-run.png", isTemplate: true)
    static let sleepImage: NSImage? = loadIcon(named: "BrandSleep", fallbackFileName: "icon-sleep.png", isTemplate: true)
    static let tunImage: NSImage? = loadIcon(named: "BrandTun", fallbackFileName: "icon-tun.png", isTemplate: true)
    static let warningImage: NSImage? = loadIcon(named: "BrandWarning", fallbackFileName: "icon-warning.png", isTemplate: true)

    static func headerImage(for state: MenuBarIconState) -> NSImage? {
        switch state {
        case .sleep: self.headerSleepImage
        case .run: self.headerRunImage
        case .tun: self.headerTunImage
        case .warning: self.headerWarningImage
        }
    }

    private static func loadIcon(named name: String, fallbackFileName: String, isTemplate: Bool = false) -> NSImage? {
        guard let source = self.loadSourceIcon(named: name, fallbackFileName: fallbackFileName),
              let image = source.copy() as? NSImage else { return nil }
        image.isTemplate = isTemplate
        return image
    }

    private static func loadSourceIcon(named name: String, fallbackFileName: String) -> NSImage? {
        #if SWIFT_PACKAGE
        if let image = Bundle.module.image(forResource: NSImage.Name(name)) {
            return image
        }
        #endif

        for bundle in AppResourceBundleLocator.candidateBundles() {
            if let image = bundle.image(forResource: NSImage.Name(name)) {
                return image
            }
        }

        if let image = NSImage(named: NSImage.Name(name)) {
            return image
        }

        let candidateRelativePaths = [
            "Assets.xcassets/\(name).imageset/\(fallbackFileName)",
            "Resources/Assets.xcassets/\(name).imageset/\(fallbackFileName)",
            fallbackFileName,
        ]

        for root in AppResourceBundleLocator.candidateResourceRoots() {
            for relativePath in candidateRelativePaths {
                let url = root.appendingPathComponent(relativePath, isDirectory: false)
                if let image = NSImage(contentsOf: url) {
                    return image
                }
            }
        }

        for bundle in AppResourceBundleLocator.candidateBundles() {
            for relativePath in candidateRelativePaths {
                let url = bundle.bundleURL.appendingPathComponent(relativePath, isDirectory: false)
                if let image = NSImage(contentsOf: url) {
                    return image
                }
            }
        }

        return nil
    }
}
