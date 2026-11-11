import Foundation

struct ServiceEndpoint: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let url: String

    var isBuiltIn: Bool { Self.builtIns.contains { $0.id == id } }

    static let builtIns = [
        ServiceEndpoint(id: "builtin.google", name: "Google", url: "https://www.google.com/"),
        ServiceEndpoint(id: "builtin.github", name: "GitHub", url: "https://github.com/"),
        ServiceEndpoint(id: "builtin.youtube", name: "YouTube", url: "https://www.youtube.com/"),
    ]

    static func validatedURL(_ input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count <= 4096, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let url = RuleTester.validURL(value), let host = url.host, !host.contains(where: \.isWhitespace),
              url.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        return url
    }
}

enum ServiceProbeKind: CaseIterable, Sendable { case current, direct }

enum ServiceProbeState: Equatable, Sendable {
    case pending, checking, reachable, restricted, httpError, timedOut, connectionFailed, tlsFailed, cancelled, unavailable
}

struct ServiceProbeResult: Equatable, Sendable {
    var state: ServiceProbeState = .pending
    var statusCode: Int?
    var elapsed: TimeInterval?
    // Mihomo reports chains from the final outbound back to the policy group.
    // Only an exactly correlated connection may populate this value.
    var chains: [String]?
    var rule: String?
    var detail: String?
    var checkedAt: Date?
    var isStale = false

    static func unavailable(_ reason: String) -> Self {
        Self(state: .unavailable, detail: reason, checkedAt: Date())
    }

    var routeDescription: String? {
        guard let chains, !chains.isEmpty else { return nil }
        return chains.reversed().joined(separator: " → ")
    }

    static func httpState(_ code: Int) -> ServiceProbeState {
        if code == 403 || code == 429 { return .restricted }
        return (200..<400).contains(code) ? .reachable : .httpError
    }
}

struct ServiceStatusRow: Equatable, Sendable {
    var current = ServiceProbeResult()
    var direct = ServiceProbeResult()

    subscript(kind: ServiceProbeKind) -> ServiceProbeResult {
        get { kind == .current ? current : direct }
        set { if kind == .current { current = newValue } else { direct = newValue } }
    }
}

protocol ServiceStatusChecking: Sendable {
    func prepare() async throws
    func measure(_ endpoint: ServiceEndpoint, kind: ServiceProbeKind) async throws -> ServiceProbeResult
    func close() async
}
