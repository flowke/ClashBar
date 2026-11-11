import Foundation
import AppKit
import ProxyHelperShared
import Security
import SystemConfiguration

enum SystemProxyStatus: Equatable {
    case disabled
    case active
    case overridden
    case unknown

    var needsAttention: Bool { self == .overridden || self == .unknown }
}

struct SystemProxyTarget: Codable, Equatable, Sendable {
    let host: String
    let ports: SystemProxyPorts
}

/// A read-only snapshot; observing proxy changes never launches the privileged helper.
struct SystemProxySnapshot: Equatable, Sendable {
    struct Configuration: Equatable, Sendable {
        struct Endpoint: Equatable, Sendable {
            let host: String
            let port: Int

            var display: String { host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)" }
        }

        let http: Endpoint?
        let https: Endpoint?
        let socks: Endpoint?
        let automatic: Bool

        init(dictionary: [String: Any]) {
            func endpoint(_ enabled: CFString, _ host: CFString, _ port: CFString) -> Endpoint? {
                guard (dictionary[enabled as String] as? NSNumber)?.boolValue == true else { return nil }
                return Endpoint(host: dictionary[host as String] as? String ?? "",
                                port: (dictionary[port as String] as? NSNumber)?.intValue ?? 0)
            }
            self.http = endpoint(kSCPropNetProxiesHTTPEnable, kSCPropNetProxiesHTTPProxy, kSCPropNetProxiesHTTPPort)
            self.https = endpoint(kSCPropNetProxiesHTTPSEnable, kSCPropNetProxiesHTTPSProxy, kSCPropNetProxiesHTTPSPort)
            self.socks = endpoint(kSCPropNetProxiesSOCKSEnable, kSCPropNetProxiesSOCKSProxy, kSCPropNetProxiesSOCKSPort)
            self.automatic = [kSCPropNetProxiesProxyAutoConfigEnable, kSCPropNetProxiesProxyAutoDiscoveryEnable]
                .contains { (dictionary[$0 as String] as? NSNumber)?.boolValue == true }
        }

        var isEnabled: Bool { self.automatic || self.http != nil || self.https != nil || self.socks != nil }

        func matches(_ target: SystemProxyTarget) -> Bool {
            func normalized(_ host: String) -> String {
                let host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if host == "localhost" { return "127.0.0.1" }
                return host == "[::1]" ? "::1" : host
            }
            func matches(_ endpoint: Endpoint?, _ port: Int?) -> Bool {
                guard let port else { return endpoint == nil }
                guard let endpoint else { return false }
                return endpoint.port == port && normalized(endpoint.host) == normalized(target.host)
            }
            return !self.automatic && matches(self.http, target.ports.httpPort)
                && matches(self.https, target.ports.httpsPort) && matches(self.socks, target.ports.socksPort)
        }
    }

    let configurations: [Configuration]

    var isEnabled: Bool { self.configurations.contains(where: \.isEnabled) }
    var hasAutomaticProxy: Bool { self.configurations.contains(where: \.automatic) }
    var activeDisplays: [String] {
        Array(Set(self.configurations.flatMap { [$0.http, $0.https, $0.socks].compactMap { $0?.display } })).sorted()
    }

    func matches(_ target: SystemProxyTarget) -> Bool {
        !self.configurations.isEmpty && self.configurations.allSatisfy { $0.matches(target) }
    }

    static func read() throws -> SystemProxySnapshot {
        guard let preferences = SCPreferencesCreate(nil, "ClashBar proxy status" as CFString, nil),
              let currentSet = SCNetworkSetCopyCurrent(preferences),
              let services = SCNetworkSetCopyServices(currentSet) as? [SCNetworkService]
        else { throw SystemProxyServiceError.configurationUnavailable }

        var configurations = services.filter { SCNetworkServiceGetEnabled($0) }.compactMap { service -> Configuration? in
            guard let proxy = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else { return nil }
            return Configuration(dictionary: SCNetworkProtocolGetConfiguration(proxy) as? [String: Any] ?? [:])
        }
        guard !configurations.isEmpty else { throw SystemProxyServiceError.configurationUnavailable }
        // Also check the effective configuration, including transient changes by VPNs/tools.
        if let store = SCDynamicStoreCreate(nil, "ClashBar proxy status" as CFString, nil, nil),
           ["IPv4", "IPv6"].contains(where: {
               (SCDynamicStoreCopyValue(store, "State:/Network/Global/\($0)" as CFString) as? [String: Any])?["PrimaryService"] != nil
           }),
           let effective = SCDynamicStoreCopyProxies(store) as? [String: Any]
        {
            configurations.append(Configuration(dictionary: effective))
        }
        return SystemProxySnapshot(configurations: configurations)
    }
}

@MainActor
final class SystemProxyMonitor {
    private var store: SCDynamicStore?
    private var wakeObserver: (any NSObjectProtocol)?
    private var onChange: (() -> Void)?

    func start(onChange: @escaping () -> Void) {
        self.stop()
        self.onChange = onChange
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        self.store = SCDynamicStoreCreate(nil, "ClashBar proxy monitor" as CFString, { _, _, info in
            guard let info else { return }
            MainActor.assumeIsolated {
                Unmanaged<SystemProxyMonitor>.fromOpaque(info).takeUnretainedValue().onChange?()
            }
        }, &context)
        if let store {
            let keys = ["State:/Network/Global/Proxies", "State:/Network/Global/IPv4", "State:/Network/Global/IPv6"]
            let patterns = ["Setup:/Network/Service/.*/Proxies", "State:/Network/Service/.*/Proxies", "Setup:/Network/Global/.*"]
            SCDynamicStoreSetNotificationKeys(store, keys as CFArray, patterns as CFArray)
            SCDynamicStoreSetDispatchQueue(store, .main)
        }
        self.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.onChange?() } }
    }

    func stop() {
        if let store { SCDynamicStoreSetDispatchQueue(store, nil) }
        self.store = nil
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        self.wakeObserver = nil
        self.onChange = nil
    }

    isolated deinit { self.stop() }
}

enum SystemProxyHelperFailureReason: String, Equatable, Sendable {
    case helperNotRegistered
    case helperNeedsUpdate
    case helperStartTimedOut
    case helperConnectionFailed
    case helperOperationFailed
    case appNotInApplications
    case helperNotBundled
    case helperAuthorizationCancelled
    case helperInstallFailed
    case unknown
}

struct SystemProxyHelperHealthSnapshot: Equatable, Sendable {
    let helperInstalled: Bool
    let processRunning: Bool
    let installedVersion: Int?
    let expectedVersion: Int
    let failureReason: SystemProxyHelperFailureReason?
    let rawMessage: String?
}

enum SystemProxyServiceError: LocalizedError {
    case configurationUnavailable
    case invalidHost
    case invalidPort
    case helperNotBundled
    case helperRequiresInstallToApplications
    case helperNotRegistered
    case helperNeedsUpdate(installed: Int, expected: Int)
    case helperStartTimedOut
    case helperAuthorizationCancelled
    case helperInstallFailed(String)
    case helperConnectionFailed(String)
    case helperOperationFailed(String)

    var errorDescription: String? {
        switch self {
        case .configurationUnavailable:
            "Unable to read the current macOS proxy configuration."
        case .invalidHost:
            "Invalid proxy host."
        case .invalidPort:
            "Invalid proxy port."
        case .helperNotBundled:
            "Privileged helper not found in app bundle. Please rebuild and run the packaged app."
        case .helperRequiresInstallToApplications:
            "Privileged helper can only be installed from /Applications. " +
                "Move ClashBar.app to /Applications and reopen it."
        case .helperNotRegistered:
            "Privileged helper is not installed."
        case let .helperNeedsUpdate(installed, expected):
            "Privileged helper version is outdated (installed v\(installed), expected v\(expected))."
        case .helperStartTimedOut:
            "Privileged helper did not start. " +
                "Allow it in System Settings > General > Login Items if macOS asks, then try again."
        case .helperAuthorizationCancelled:
            "Administrator authorization was cancelled."
        case let .helperInstallFailed(message):
            "Failed to install privileged helper: \(message)"
        case let .helperConnectionFailed(message):
            "Failed to connect privileged helper: \(message)"
        case let .helperOperationFailed(message):
            "Privileged helper operation failed: \(message)"
        }
    }
}

private final class ContinuationBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?

    init(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation = continuation
    }

    func resume(with result: Result<Value, Error>) {
        self.lock.lock()
        guard let continuation else {
            self.lock.unlock()
            return
        }
        self.continuation = nil
        self.lock.unlock()

        switch result {
        case let .success(value):
            continuation.resume(returning: value)
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}

protocol SystemProxyServicing: Sendable {
    func readSnapshot() throws -> SystemProxySnapshot
    func apply(enabled: Bool, host: String, ports: SystemProxyPorts) async throws
    func isEnabled() async throws -> Bool
    func readActiveDisplay() async throws -> String?
    func readExceptionsList() async throws -> [String]
    func setExceptionsList(_ exceptions: [String]) async throws
    func installOrUpdateHelper() async throws
    func readHelperHealthSnapshot() async -> SystemProxyHelperHealthSnapshot
    func isConfigured(host: String, ports: SystemProxyPorts) async throws -> Bool
    func clearBlocking(timeout: TimeInterval)
}

struct SystemProxyService: SystemProxyServicing {
    private let helperResponseTimeoutNanoseconds: UInt64 = 4_000_000_000
    private let helperLaunchRetryDelayNanoseconds: UInt64 = 250_000_000
    private let helperLaunchRetryAttempts = 4

    func readSnapshot() throws -> SystemProxySnapshot { try SystemProxySnapshot.read() }

    func apply(enabled: Bool, host: String, ports: SystemProxyPorts) async throws {
        try self.validateHost(host)
        try await self.ensureHelperReadyForUse()

        if enabled {
            let resolvedPorts = try self.validateAndResolvePorts(ports, requiresEnabledPort: true)
            try await self.invokeMutation { helper, completion in
                helper.setSystemProxy(
                    host: host,
                    httpPort: resolvedPorts.httpPort,
                    httpsPort: resolvedPorts.httpsPort,
                    socksPort: resolvedPorts.socksPort,
                    completion: completion)
            }
        } else {
            try await self.invokeMutation { helper, completion in
                helper.clearSystemProxy(completion: completion)
            }
        }
    }

    func isEnabled() async throws -> Bool {
        try await self.ensureHelperReadyForUse()
        return try await self.invokeStateQuery()
    }

    func readActiveDisplay() async throws -> String? {
        try await self.ensureHelperReadyForUse()
        guard let target = try await self.invokeActiveTargetQuery() else {
            return nil
        }
        return self.formatProxyDisplay(host: target.host, port: target.port)
    }

    func readExceptionsList() async throws -> [String] {
        try await self.ensureHelperReadyForUse()
        return try await self.invokeExceptionsQuery()
    }

    func setExceptionsList(_ exceptions: [String]) async throws {
        try await self.ensureHelperReadyForUse()
        let serialized = self.serializeExceptions(exceptions)
        try await self.invokeMutation { helper, completion in
            helper.setSystemProxyExceptions(serializedExceptions: serialized, completion: completion)
        }
    }

    func installOrUpdateHelper() async throws {
        try self.validateHelperEnvironment()
        try await ProxyHelperInstaller.installBundledHelper()
        guard ProxyHelperInstaller.installedHelperIsCurrent() else {
            throw SystemProxyServiceError.helperInstallFailed("Helper version was not recorded.")
        }
        guard try await self.triggerHelperDemandLaunchAndWait() else {
            throw SystemProxyServiceError.helperStartTimedOut
        }
    }

    func readHelperHealthSnapshot() async -> SystemProxyHelperHealthSnapshot {
        var processRunning = (try? self.isHelperProcessRunning()) ?? false
        let installedVersion = ProxyHelperInstaller.installedHelperVersion()
        guard ProxyHelperInstaller.installedHelperIsCurrent() else {
            var error: Error
            if let installedVersion,
               installedVersion != ProxyHelperConstants.helperVersion
            {
                error = SystemProxyServiceError.helperNeedsUpdate(
                    installed: installedVersion,
                    expected: ProxyHelperConstants.helperVersion)
            } else {
                error = SystemProxyServiceError.helperNotRegistered
                do {
                    try self.validateHelperEnvironment()
                } catch let environmentError {
                    error = environmentError
                }
            }
            return self.healthSnapshot(
                helperInstalled: false,
                processRunning: processRunning,
                installedVersion: installedVersion,
                error: error)
        }

        if !processRunning {
            processRunning = await (try? self.triggerHelperDemandLaunchAndWait()) ?? false
        }
        return self.healthSnapshot(
            helperInstalled: true,
            processRunning: processRunning,
            installedVersion: installedVersion,
            error: processRunning ? nil : SystemProxyServiceError.helperStartTimedOut)
    }

    func isConfigured(host: String, ports: SystemProxyPorts) async throws -> Bool {
        try self.validateHost(host)
        let resolvedPorts = try self.validateAndResolvePorts(ports, requiresEnabledPort: true)
        try await self.ensureHelperReadyForUse()
        return try await self.invokeBooleanQuery { helper, completion in
            helper.isSystemProxyConfigured(
                host: host,
                httpPort: resolvedPorts.httpPort,
                httpsPort: resolvedPorts.httpsPort,
                socksPort: resolvedPorts.socksPort,
                completion: completion)
        }
    }

    private func validateHost(_ host: String) throws {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty else {
            throw SystemProxyServiceError.invalidHost
        }
    }

    private func validateAndResolvePorts(
        _ ports: SystemProxyPorts,
        requiresEnabledPort: Bool) throws -> (httpPort: Int, httpsPort: Int, socksPort: Int)
    {
        let httpPort = try self.normalizePort(ports.httpPort)
        let httpsPort = try self.normalizePort(ports.httpsPort)
        let socksPort = try self.normalizePort(ports.socksPort)

        if requiresEnabledPort, httpPort == 0, httpsPort == 0, socksPort == 0 {
            throw SystemProxyServiceError.invalidPort
        }

        return (httpPort: httpPort, httpsPort: httpsPort, socksPort: socksPort)
    }

    private func normalizePort(_ value: Int?) throws -> Int {
        guard let value else { return 0 }
        guard (1...65535).contains(value) else {
            throw SystemProxyServiceError.invalidPort
        }
        return value
    }

    private func validateHelperEnvironment() throws {
        guard ProxyHelperInstaller.helperSourceAvailable() else {
            throw SystemProxyServiceError.helperNotBundled
        }
        guard self.isRunningFromApplicationsDirectory() || self.isDevelopmentBuild() else {
            throw SystemProxyServiceError.helperRequiresInstallToApplications
        }
        try self.validateHelperSigningRequirements()
    }

    private func ensureHelperReadyForUse() async throws {
        guard ProxyHelperInstaller.installedHelperIsCurrent() else {
            if let installedVersion = ProxyHelperInstaller.installedHelperVersion(),
               installedVersion != ProxyHelperConstants.helperVersion
            {
                throw SystemProxyServiceError.helperNeedsUpdate(
                    installed: installedVersion,
                    expected: ProxyHelperConstants.helperVersion)
            }
            throw SystemProxyServiceError.helperNotRegistered
        }
    }

    private func healthSnapshot(
        helperInstalled: Bool,
        processRunning: Bool,
        installedVersion: Int?,
        error: Error?) -> SystemProxyHelperHealthSnapshot
    {
        SystemProxyHelperHealthSnapshot(
            helperInstalled: helperInstalled,
            processRunning: processRunning,
            installedVersion: installedVersion,
            expectedVersion: ProxyHelperConstants.helperVersion,
            failureReason: error.map { self.helperFailureReason(for: $0) },
            rawMessage: error.map { self.helperFailureMessage($0) })
    }

    private func helperFailureReason(for error: Error) -> SystemProxyHelperFailureReason {
        guard let serviceError = error as? SystemProxyServiceError else {
            return .unknown
        }

        switch serviceError {
        case .configurationUnavailable:
            return .unknown
        case .helperNotBundled:
            return .helperNotBundled
        case .helperRequiresInstallToApplications:
            return .appNotInApplications
        case .helperNotRegistered:
            return .helperNotRegistered
        case .helperNeedsUpdate:
            return .helperNeedsUpdate
        case .helperStartTimedOut:
            return .helperStartTimedOut
        case .helperAuthorizationCancelled:
            return .helperAuthorizationCancelled
        case .helperInstallFailed:
            return .helperInstallFailed
        case .helperConnectionFailed:
            return .helperConnectionFailed
        case .helperOperationFailed:
            return .helperOperationFailed
        case .invalidHost, .invalidPort:
            return .unknown
        }
    }

    private func isRunningFromApplicationsDirectory() -> Bool {
        let bundlePath = Bundle.main.bundleURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        return bundlePath.hasPrefix("/Applications/") && bundlePath.hasSuffix(".app")
    }

    private func isDevelopmentBuild() -> Bool {
#if DEBUG
        return ProxyHelperInstaller.helperSourceAvailable()
#else
        return false
#endif
    }

    private func triggerHelperDemandLaunchAndWait() async throws -> Bool {
        do {
            try await self.invokeHelperPing()
        } catch {
            guard self.isHelperConnectionFailure(error) else {
                throw error
            }
        }

        for attempt in 0..<self.helperLaunchRetryAttempts {
            if try self.isHelperProcessRunning() {
                return true
            }
            if attempt < self.helperLaunchRetryAttempts - 1 {
                try await Task.sleep(nanoseconds: self.helperLaunchRetryDelayNanoseconds)
            }
        }

        return false
    }

    private func invokeHelperPing() async throws {
        try await self.invokeHelperOnce { helper, completion in
            helper.ping { success, message in
                completion(Self.mapHelperResult(success: success, message: message, value: ()))
            }
        }
    }

    private static func mapHelperResult<Value>(
        success: Bool,
        message: String?,
        value: @autoclosure () -> Value) -> Result<Value, Error>
    {
        if success {
            return .success(value())
        }
        return .failure(SystemProxyServiceError.helperOperationFailed(message ?? "Unknown helper error."))
    }

    private func isHelperProcessRunning() throws -> Bool {
        let result = try self.runProcessSynchronously(
            executable: "/usr/bin/pgrep",
            arguments: ["-x", ProxyHelperConstants.machServiceName])
        switch result.exitCode {
        case 0:
            return true
        case 1:
            return false
        default:
            throw SystemProxyServiceError.helperOperationFailed(result.combinedOutput)
        }
    }

    private func invokeStateQuery() async throws -> Bool {
        try await self.invokeBooleanQuery { helper, completion in
            helper.getSystemProxyState(completion: completion)
        }
    }

    private func invokeMutation(
        _ invoke: @escaping (ProxyHelperProtocol, @escaping (Bool, String?) -> Void) -> Void) async throws
    {
        try await self.invokeHelper { helper, completion in
            invoke(helper) { success, message in
                completion(Self.mapHelperResult(success: success, message: message, value: ()))
            }
        }
    }

    private func invokeBooleanQuery(
        _ invoke: @escaping (ProxyHelperProtocol, @escaping (Bool, Bool, String?) -> Void) -> Void) async throws
        -> Bool
    {
        try await self.invokeHelper { helper, completion in
            invoke(helper) { success, boolValue, message in
                completion(Self.mapHelperResult(success: success, message: message, value: boolValue))
            }
        }
    }

    private func invokeActiveTargetQuery() async throws -> (host: String, port: Int)? {
        try await self.invokeHelper { helper, completion in
            helper.getSystemProxyActiveTarget { success, host, port, message in
                let target: (host: String, port: Int)? = if let host,
                                                            !host.trimmingCharacters(in: .whitespacesAndNewlines)
                                                                .isEmpty, port > 0
                {
                    (host: host, port: port)
                } else {
                    nil
                }
                completion(Self.mapHelperResult(success: success, message: message, value: target))
            }
        }
    }

    private func invokeExceptionsQuery() async throws -> [String] {
        try await self.invokeHelper { helper, completion in
            helper.getSystemProxyExceptions { success, serialized, message in
                completion(Self.mapHelperResult(
                    success: success,
                    message: message,
                    value: self.deserializeExceptions(serialized)))
            }
        }
    }

    private func formatProxyDisplay(host: String, port: Int) -> String {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedHost.contains(":"), !trimmedHost.hasPrefix("[") {
            return "[\(trimmedHost)]:\(port)"
        }
        return "\(trimmedHost):\(port)"
    }

    private func serializeExceptions(_ exceptions: [String]) -> String {
        exceptions.joined(separator: "\n")
    }

    private func deserializeExceptions(_ serialized: String?) -> [String] {
        guard let serialized else { return [] }

        var result: [String] = []
        var seen: Set<String> = []

        for value in serialized.components(separatedBy: .newlines) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            guard seen.insert(key).inserted else { continue }
            result.append(trimmed)
        }

        return result
    }

    private func helperFailureMessage(_ error: Error) -> String {
        if let serviceError = error as? SystemProxyServiceError {
            return serviceError.localizedDescription
        }
        return error.localizedDescription
    }

    private func isHelperConnectionFailure(_ error: Error) -> Bool {
        if let serviceError = error as? SystemProxyServiceError,
           case .helperConnectionFailed = serviceError
        {
            return true
        }
        return false
    }

    private struct ProcessResult {
        let exitCode: Int32
        let stdout: String
        let stderr: String

        var combinedOutput: String {
            [self.stderr, self.stdout]
                .first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown command error."
        }
    }

    private func runProcessSynchronously(executable: String, arguments: [String]) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            throw SystemProxyServiceError.helperOperationFailed(error.localizedDescription)
        }

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    private func invokeHelper<Value: Sendable>(
        _ invoke: @escaping (ProxyHelperProtocol, @escaping (Result<Value, Error>) -> Void) -> Void) async throws
        -> Value
    {
        do {
            return try await self.invokeHelperOnce(invoke)
        } catch {
            guard self.isHelperConnectionFailure(error) else { throw error }
            _ = try? await self.triggerHelperDemandLaunchAndWait()
            return try await self.invokeHelperOnce(invoke)
        }
    }

    private func invokeHelperOnce<Value: Sendable>(
        _ invoke: @escaping (ProxyHelperProtocol, @escaping (Result<Value, Error>) -> Void) -> Void) async throws
        -> Value
    {
        try await withCheckedThrowingContinuation { continuation in
            let connection = self.makeConnection()
            let box = ContinuationBox<Value>(continuation)
            let timeoutWorkItem = DispatchWorkItem {
                connection.invalidate()
                box.resume(
                    with: .failure(
                        SystemProxyServiceError.helperConnectionFailed("Helper response timed out.")))
            }
            let timeoutInterval = DispatchTimeInterval.nanoseconds(Int(self.helperResponseTimeoutNanoseconds))
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + timeoutInterval,
                execute: timeoutWorkItem)

            guard let helper = connection.remoteObjectProxyWithErrorHandler({ error in
                timeoutWorkItem.cancel()
                connection.invalidate()
                box.resume(with: .failure(SystemProxyServiceError.helperConnectionFailed(error.localizedDescription)))
            }) as? ProxyHelperProtocol else {
                timeoutWorkItem.cancel()
                connection.invalidate()
                box.resume(
                    with: .failure(
                        SystemProxyServiceError.helperConnectionFailed("Unable to create XPC proxy.")))
                return
            }

            invoke(helper) { result in
                timeoutWorkItem.cancel()
                defer { connection.invalidate() }
                box.resume(with: result)
            }
        }
    }

    func clearBlocking(timeout: TimeInterval = 2.0) {
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let connection = self.makeConnection()

            guard let helper = connection.remoteObjectProxyWithErrorHandler({ _ in
                semaphore.signal()
            }) as? ProxyHelperProtocol else {
                connection.invalidate()
                semaphore.signal()
                return
            }

            helper.clearSystemProxy { _, _ in
                connection.invalidate()
                semaphore.signal()
            }
        }

        _ = semaphore.wait(timeout: .now() + timeout)
    }

    private func makeConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(
            machServiceName: ProxyHelperConstants.machServiceName,
            options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: ProxyHelperProtocol.self)
        if let team = self.signingTeamIdentifier(at: Bundle.main.bundleURL) {
            connection.setCodeSigningRequirement(
                "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\"")
        }
        connection.activate()
        return connection
    }

    private func validateHelperSigningRequirements() throws {
        guard let helperURL = ProxyHelperInstaller.helperBinaryURL() else {
            throw SystemProxyServiceError.helperNotBundled
        }
        let appTeam = self.signingTeamIdentifier(at: Bundle.main.bundleURL)
        let helperTeam = self.signingTeamIdentifier(at: helperURL)
        guard appTeam == helperTeam else {
            throw SystemProxyServiceError.helperInstallFailed(
                "App and helper Team ID mismatch (\(appTeam ?? "none") != \(helperTeam ?? "none")).")
        }
    }

    private func signingTeamIdentifier(at url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }

        var info: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &info) == errSecSuccess,
            let dict = info as? [String: Any]
        else { return nil }

        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }
}
