import Darwin
import Foundation
import ProxyHelperShared
import ServiceManagement

enum ProxyHelperInstaller {
    private struct HelperSource {
        let binaryURL: URL
        let plistURL: URL?
    }

    static func installedHelperVersion() -> Int? {
        guard let raw = try? String(
            contentsOfFile: ProxyHelperConstants.installedVersionPath,
            encoding: .utf8),
            let version = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            return nil
        }
        return version
    }

    static func installedHelperIsCurrent() -> Bool {
        return FileManager.default.isExecutableFile(atPath: ProxyHelperConstants.installedHelperPath)
            && FileManager.default.fileExists(atPath: ProxyHelperConstants.installedPlistPath)
            && self.installedHelperVersion() == ProxyHelperConstants.helperVersion
            && !self.hasQuarantine(atPath: ProxyHelperConstants.installedHelperPath)
            && !self.hasQuarantine(atPath: ProxyHelperConstants.installedPlistPath)
    }

    static func hasQuarantine(atPath path: String) -> Bool {
        getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
    }

    static func helperSourceAvailable() -> Bool {
        self.resolveHelperSource() != nil
    }

    static func helperBinaryURL() -> URL? {
        self.resolveHelperSource()?.binaryURL
    }

    static func installBundledHelper() async throws {
        guard let source = self.resolveHelperSource() else {
            throw SystemProxyServiceError.helperNotBundled
        }

        let temporaryPlistURL: URL?
        let plistURL: URL
        if let sourcePlistURL = source.plistURL {
            temporaryPlistURL = nil
            plistURL = sourcePlistURL
        } else {
            let generatedPlistURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("ClashBar-Helper-\(UUID().uuidString).plist")
            try self.writeDevelopmentHelperPlist(to: generatedPlistURL)
            temporaryPlistURL = generatedPlistURL
            plistURL = generatedPlistURL
        }
        defer {
            if let temporaryPlistURL {
                try? FileManager.default.removeItem(at: temporaryPlistURL)
            }
        }

        let command = self.installShellCommand(
            sourceBinary: source.binaryURL.path,
            sourcePlist: plistURL.path)

        try? await SMAppService.daemon(plistName: ProxyHelperConstants.daemonPlistName).unregister()
        try await Task.detached(priority: .userInitiated) {
            try AdministratorShell.run(
                command,
                cancelled: SystemProxyServiceError.helperAuthorizationCancelled,
                failed: SystemProxyServiceError.helperInstallFailed)
        }.value
    }

    private static func resolveHelperSource() -> HelperSource? {
        let bundleURL = Bundle.main.bundleURL
        let bundledBinaryURL = bundleURL.appendingPathComponent(ProxyHelperConstants.helperBundleProgram)
        let bundledPlistURL = bundleURL.appendingPathComponent(ProxyHelperConstants.helperBundlePlist)
        if FileManager.default.isExecutableFile(atPath: bundledBinaryURL.path),
           FileManager.default.fileExists(atPath: bundledPlistURL.path)
        {
            return HelperSource(binaryURL: bundledBinaryURL, plistURL: bundledPlistURL)
        }

#if DEBUG
        let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent()
        let bundleDirectory = bundleURL.deletingLastPathComponent()
        let workingDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let projectRoots = [
            workingDirectory,
            workingDirectory.deletingLastPathComponent(),
            workingDirectory.deletingLastPathComponent().deletingLastPathComponent(),
        ]
        var developmentCandidates = [bundleDirectory.appendingPathComponent("ClashBarProxyHelper")]
        if let executableDirectory {
            developmentCandidates.append(executableDirectory.appendingPathComponent("ClashBarProxyHelper"))
        }
        developmentCandidates += projectRoots.flatMap { root in
            [
                root.appendingPathComponent(".build/out/Products/Debug/ClashBarProxyHelper"),
                root.appendingPathComponent(".build/arm64-apple-macosx/debug/ClashBarProxyHelper"),
                root.appendingPathComponent(".build/debug/ClashBarProxyHelper"),
            ]
        }

        if let binaryURL = developmentCandidates.compactMap({ $0 }).first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) {
            return HelperSource(binaryURL: binaryURL, plistURL: nil)
        }
#endif

        return nil
    }

    private static func writeDevelopmentHelperPlist(to url: URL) throws {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(ProxyHelperConstants.machServiceName)</string>
            <key>MachServices</key>
            <dict>
                <key>\(ProxyHelperConstants.machServiceName)</key>
                <true/>
            </dict>
            <key>Program</key>
            <string>\(ProxyHelperConstants.installedHelperPath)</string>
        </dict>
        </plist>
        """
        try plist.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func installShellCommand(sourceBinary: String, sourcePlist: String) -> String {
        let binary = AdministratorShell.shellQuoted(sourceBinary)
        let plist = AdministratorShell.shellQuoted(sourcePlist)
        let destBinary = AdministratorShell.shellQuoted(ProxyHelperConstants.installedHelperPath)
        let destPlist = AdministratorShell.shellQuoted(ProxyHelperConstants.installedPlistPath)
        let versionFile = AdministratorShell.shellQuoted(ProxyHelperConstants.installedVersionPath)
        let label = ProxyHelperConstants.machServiceName

        return """
        set -e
        /bin/mkdir -p /Library/PrivilegedHelperTools /Library/LaunchDaemons
        /bin/rm -f \(versionFile)
        /bin/launchctl bootout system/\(label) >/dev/null 2>&1 || true
        /bin/rm -f \(destBinary)
        /bin/cp -X \(binary) \(destBinary)
        /usr/sbin/chown root:wheel \(destBinary)
        /bin/chmod 755 \(destBinary)
        /usr/bin/xattr -c \(destBinary) 2>/dev/null || true
        /usr/bin/xattr -d com.apple.quarantine \(destBinary) 2>/dev/null || true
        /bin/rm -f \(destPlist)
        /bin/cp -X \(plist) \(destPlist)
        /usr/sbin/chown root:wheel \(destPlist)
        /bin/chmod 644 \(destPlist)
        /usr/bin/xattr -c \(destPlist) 2>/dev/null || true
        /usr/bin/xattr -d com.apple.quarantine \(destPlist) 2>/dev/null || true
        if /usr/bin/xattr -p com.apple.quarantine \(destBinary) >/dev/null 2>&1; then
            echo "Failed to remove quarantine attribute from helper binary." >&2
            exit 1
        fi
        if /usr/bin/xattr -p com.apple.quarantine \(destPlist) >/dev/null 2>&1; then
            echo "Failed to remove quarantine attribute from helper plist." >&2
            exit 1
        fi
        /bin/launchctl enable system/\(label) >/dev/null 2>&1 || true
        if ! /bin/launchctl bootstrap system \(destPlist) 2>/dev/null; then
            /bin/sleep 0.1
            /bin/launchctl bootout system/\(label) >/dev/null 2>&1 || true
            /bin/launchctl bootstrap system \(destPlist)
        fi
        /bin/launchctl kickstart -k system/\(label)
        echo \(ProxyHelperConstants.helperVersion) > \(versionFile)
        """
    }
}
