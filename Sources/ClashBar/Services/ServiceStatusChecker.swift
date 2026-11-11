import Darwin
import Foundation

actor ServiceStatusChecker: ServiceStatusChecking {
    private let client: (any MihomoAPITransporting)?
    private let binary: URL
    private let local: Bool
    private let running: Bool
    private var proxy: String?
    private var direct: ServiceDirectSession?
    private var currentReason = "本地核心尚未运行。 / The local core is not running."
    private var directReason = "无法建立强制直连。 / Forced DIRECT is unavailable."

    init(client: (any MihomoAPITransporting)?, binary: URL, local: Bool, running: Bool) {
        self.client = client
        self.binary = binary
        self.local = local
        self.running = running
    }

    func prepare() async throws {
        guard local else {
            currentReason = "远程核心不支持从本机测量其实际线路。 / Remote-core route measurement is unavailable."
            directReason = "无法从本机测量远程核心的直连网络。 / The remote core's direct network cannot be measured locally."
            return
        }
        if running, let client {
            do {
                let config: ConfigSnapshot = try await client.request(.getConfigs)
                if let port = [config.mixedPort, config.port].compactMap({ $0 }).first(where: { (1...65535).contains($0) }) {
                    proxy = "http://127.0.0.1:\(port)"
                } else if let port = config.socksPort, (1...65535).contains(port) {
                    proxy = "socks5h://127.0.0.1:\(port)"
                } else {
                    currentReason = "核心未开启本地 HTTP、SOCKS 或混合代理端口。 / No local proxy port is enabled."
                }
            } catch {
                try Task.checkCancellation()
                currentReason = "无法读取当前核心配置。 / Cannot read the current core configuration. \(error.localizedDescription)"
            }
        }
        do {
            direct = try await ServiceDirectSession.start(binary: binary)
        } catch {
            try Task.checkCancellation()
            directReason = error.localizedDescription
        }
    }

    func close() async {
        let owned = direct
        direct = nil
        await owned?.close()
    }

    func measure(_ endpoint: ServiceEndpoint, kind: ServiceProbeKind) async throws -> ServiceProbeResult {
        try Task.checkCancellation()
        guard let url = ServiceEndpoint.validatedURL(endpoint.url) else {
            return .unavailable("网址必须是完整的 HTTP 或 HTTPS 地址。 / Enter a full HTTP or HTTPS URL.")
        }
        let selectedProxy: String
        switch kind {
        case .current:
            guard let proxy else { return .unavailable(currentReason) }
            selectedProxy = proxy
        case .direct:
            guard let direct, local else { return .unavailable(directReason) }
            guard direct.isRunning else {
                return .unavailable("独立直连核心已停止，未执行直连请求。 / The isolated DIRECT core has stopped.")
            }
            // Revalidate the network before every measurement. A disappeared or
            // replaced interface must never silently fall back to the TUN path.
            guard (try? ServiceDirectSession.Network.physical()) == direct.network else {
                return .unavailable("物理网络已变化，请重新检测。 / The physical network changed; run the check again.")
            }
            selectedProxy = "socks5h://127.0.0.1:\(direct.proxyPort)"
        }
        return try await Self.request(url: url, proxy: selectedProxy, client: kind == .current ? client : nil,
                                      forcedDirect: kind == .direct)
    }

    struct Connections: Decodable {
        let connections: [ConnectionSummary]?
    }

    static func correlatedConnection(_ connections: [ConnectionSummary], baseline: Set<String>, sourcePort: Int,
                                     host: String, startedAt: Date) -> ConnectionSummary? {
        let candidates = connections.filter {
            !baseline.contains($0.id) && $0.metadata?.sourceIP == "127.0.0.1" &&
                $0.metadata?.sourcePort == sourcePort &&
                matchesHost($0.metadata, host: host) &&
                ($0.startTimestamp.map { $0 >= startedAt.timeIntervalSince1970 - 0.1 } ?? false)
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private static func matchesHost(_ metadata: ConnectionMetadata?, host: String) -> Bool {
        if metadata?.host?.caseInsensitiveCompare(host) == .orderedSame { return true }
        // IP literals have no domain in Mihomo metadata. Match their actual
        // destination address; never use a resolved IP to guess a domain route.
        let literal = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var v4 = in_addr()
        var v6 = in6_addr()
        guard inet_pton(AF_INET, literal, &v4) == 1 || inet_pton(AF_INET6, literal, &v6) == 1 else { return false }
        return metadata?.destinationIP == literal
    }

    static func curlArguments(url: URL, proxy: String, sourcePort: Int) -> [String] {
        var args = ["--disable", "--silent", "--show-error", "--proxy", proxy, "--noproxy", "",
                    "--local-port", String(sourcePort), "--connect-timeout", "4", "--max-time", "8",
                    "--max-filesize", "65536", "--range", "0-0", "--output", "/dev/null",
                    "--write-out", "%{http_code}\n%{time_starttransfer}\n%{time_total}\n%{http_connect}"]
        // Tunnel plain HTTP as well. Otherwise an HTTP proxy can synthesize a
        // 502 on dial failure, which is not a response from the tested service.
        if proxy.hasPrefix("http://") { args.append("--proxytunnel") }
        // No redirects, ambient curl config, cookies, credentials, retries, or
        // environment proxy exceptions. Both requests use this exact full URL.
        args += ["--", url.absoluteString]
        return args
    }

    static func parsedResult(output: String, error: String, exit: Int32) -> ServiceProbeResult {
        let fields = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let code = fields.first.flatMap(Int.init).flatMap { (100...599).contains($0) ? $0 : nil }
        let firstByte = fields.count > 1 ? Double(fields[1]) : nil
        let total = fields.count > 2 ? Double(fields[2]) : nil
        let connectCode = fields.count > 3 ? Int(fields[3]) : nil
        if connectCode == 407 {
            return .unavailable("本地代理要求身份认证，未执行服务请求。 / Local proxy authentication is required.")
        }
        if exit == 45 {
            return .unavailable("无法绑定本地检测端口，未执行服务请求。 / Cannot bind the local probe port.")
        }
        if let code {
            // A bounded body download can end with curl 63 (or later time out),
            // but a received HTTP response still establishes reachability.
            return ServiceProbeResult(state: ServiceProbeResult.httpState(code), statusCode: code,
                                      elapsed: firstByte.flatMap { $0 > 0 ? $0 : nil } ?? total, checkedAt: Date())
        }
        let state: ServiceProbeState = exit == 28 ? .timedOut :
            ([35, 51, 58, 60, 64, 66, 77, 80, 82, 83, 90, 91].contains(exit) ? .tlsFailed : .connectionFailed)
        return ServiceProbeResult(state: state, elapsed: total, detail: error, checkedAt: Date())
    }

    static func request(url: URL, proxy: String, client: (any MihomoAPITransporting)?, forcedDirect: Bool) async throws -> ServiceProbeResult {
        let sourcePort = try ServiceDirectSession.unusedLoopbackPort()
        var baseline: Set<String>?
        if let client, let snapshot: Connections = try? await client.request(.connections(interval: nil)) {
            baseline = Set((snapshot.connections ?? []).map(\.id))
        }
        try Task.checkCancellation()
        let output = Pipe()
        let errors = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = curlArguments(url: url, proxy: proxy, sourcePort: sourcePort)
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardOutput = output
        process.standardError = errors
        let terminationObserver = ServiceProbeProcess.terminateOnAppExit(process)
        defer { NotificationCenter.default.removeObserver(terminationObserver) }
        let startedAt = Date()
        try process.run()
        var observed: ConnectionSummary?
        do {
            while process.isRunning {
                try Task.checkCancellation()
                if let client, let baseline,
                   let snapshot: Connections = try? await client.request(.connections(interval: nil)),
                   let connection = correlatedConnection(snapshot.connections ?? [], baseline: baseline,
                                                         sourcePort: sourcePort, host: url.host ?? "", startedAt: startedAt) {
                    // Conflicting observations are not evidence of one route.
                    if let previous = observed, previous.chains != connection.chains { observed = nil; break }
                    observed = connection
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            // If observation ended early, still own the curl until it finishes.
            while process.isRunning { try await Task.sleep(for: .milliseconds(25)) }
            try Task.checkCancellation()
        } catch {
            if process.isRunning { process.terminate() }
            await ServiceProbeProcess.waitForExit(process)
            throw error
        }
        await ServiceProbeProcess.waitForExit(process)
        var result = parsedResult(output: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                                  error: String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                                      .trimmingCharacters(in: .whitespacesAndNewlines), exit: process.terminationStatus)
        if forcedDirect, process.terminationStatus == 7 {
            return .unavailable("无法连接独立直连核心，未完成直连检测。 / Cannot connect to the isolated DIRECT core.")
        }
        if forcedDirect, process.terminationStatus != 45 {
            result.chains = ["DIRECT"]
        } else if ![7, 45, 97].contains(process.terminationStatus), let observed {
            result.chains = observed.chains
            result.rule = [observed.rule, observed.rulePayload].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ",")
        }
        return result
    }
}

/// Compare routing inputs, not latency history / traffic counters. API snapshots
/// also catch changes made by another controller, including provider refreshes.
struct ServiceRoutingFingerprint: Equatable, Sendable {
    let value: String

    static func load(client: any MihomoAPITransporting) async throws -> Self {
        async let configTask: ConfigSnapshot = client.request(.getConfigs)
        async let proxyTask: ProxyGroupsResponse = client.request(.proxies)
        async let rulesTask: FullRules = client.request(.rules)
        async let providersTask: ProviderSummary = client.request(.ruleProviders)
        let (config, proxies, rules, providers) = try await (configTask, proxyTask, rulesTask, providersTask)
        let selections = proxies.proxies.keys.sorted().map { key in
            let p = proxies.proxies[key]!
            return [key, p.type ?? "", p.now ?? "", p.all.joined(separator: "\u{0}")]
        }
        let providerVersions = providers.providers.keys.sorted().map { key in
            [key, providers.providers[key]?.updatedAt ?? "", String(providers.providers[key]?.ruleCount ?? 0)]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let network = try? ServiceDirectSession.Network.physical()
        let data = try JSONSerialization.data(withJSONObject: [
            "config": String(decoding: encoder.encode(config), as: UTF8.self),
            "proxies": selections, "rules": rules.rules.map { [$0.type ?? "", $0.payload ?? "", $0.proxy ?? ""] },
            "providers": providerVersions,
            "network": [network?.interface ?? "", network?.dnsServers.joined(separator: ",") ?? "", network?.signature ?? ""],
        ], options: [.sortedKeys])
        return Self(value: String(decoding: data, as: UTF8.self))
    }

    private struct FullRules: Decodable { let rules: [RuleItem] }
}
