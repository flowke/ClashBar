import Foundation
import SystemConfiguration

public struct SystemProxyBackup: Codable {
    public struct Target: Codable {
        public let host: String
        public let httpPort: Int
        public let httpsPort: Int
        public let socksPort: Int

        public init(host: String, httpPort: Int, httpsPort: Int, socksPort: Int) {
            self.host = host
            self.httpPort = httpPort
            self.httpsPort = httpsPort
            self.socksPort = socksPort
        }
    }

    public struct Entry: Codable {
        let target: Target
        let configuration: Data
    }

    public let configurations: [String: Entry]

    private static let entries = [
        (kSCPropNetProxiesHTTPEnable as String, kSCPropNetProxiesHTTPProxy as String, kSCPropNetProxiesHTTPPort as String),
        (kSCPropNetProxiesHTTPSEnable as String, kSCPropNetProxiesHTTPSProxy as String, kSCPropNetProxiesHTTPSPort as String),
        (kSCPropNetProxiesSOCKSEnable as String, kSCPropNetProxiesSOCKSProxy as String, kSCPropNetProxiesSOCKSPort as String),
    ]
    private static let automaticKeys = [
        kSCPropNetProxiesProxyAutoConfigEnable as String,
        kSCPropNetProxiesProxyAutoDiscoveryEnable as String,
    ]
    private static let savedKeys = entries.flatMap { [$0.0, $0.1, $0.2] } + automaticKeys + [
        kSCPropNetProxiesExceptionsList as String,
        kSCPropNetProxiesExcludeSimpleHostnames as String,
    ]

    public static func prepare(
        previous: SystemProxyBackup?,
        current: [String: [String: Any]],
        target: Target) throws -> SystemProxyBackup
    {
        var configurations = previous?.configurations ?? [:]
        for (identifier, configuration) in current {
            let existing = configurations[identifier]
            let saved: Data
            if let existing, matches(configuration, target: existing.target) {
                saved = existing.configuration
            } else {
                let values = configuration.filter { savedKeys.contains($0.key) }
                saved = try PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0)
            }
            configurations[identifier] = Entry(target: target, configuration: saved)
        }
        return SystemProxyBackup(configurations: configurations)
    }

    public func restoredConfiguration(identifier: String, current: [String: Any]) throws -> [String: Any]? {
        guard let entry = configurations[identifier], Self.matches(current, target: entry.target),
              let saved = try PropertyListSerialization.propertyList(from: entry.configuration, format: nil) as? [String: Any]
        else { return nil }
        var restored = current
        for key in Self.savedKeys {
            restored[key] = saved[key]
        }
        return restored
    }

    private static func matches(_ configuration: [String: Any], target: Target) -> Bool {
        guard automaticKeys.allSatisfy({ (configuration[$0] as? NSNumber)?.boolValue != true }) else { return false }
        let ports = [target.httpPort, target.httpsPort, target.socksPort]
        return zip(entries, ports).allSatisfy { entry, port in
            let enabled = (configuration[entry.0] as? NSNumber)?.boolValue == true
            guard port > 0 else { return !enabled }
            let host = (configuration[entry.1] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return enabled && host == target.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                && (configuration[entry.2] as? NSNumber)?.intValue == port
        }
    }
}
