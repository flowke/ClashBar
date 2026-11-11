import Combine
import Foundation

@MainActor
final class ServiceStatusViewModel: ObservableObject {
    @Published private(set) var services = ServiceEndpoint.builtIns
    @Published private(set) var results: [String: ServiceStatusRow] = [:]
    @Published private(set) var isRunning = false
    @Published private(set) var isCancelling = false
    @Published private(set) var activeServiceName: String?
    @Published private(set) var lastCheckedAt: Date?
    @Published private(set) var lastRunCompleted = false
    @Published private(set) var routingVerificationFailed = false
    @Published var storageError: String?
    private let storageURL: URL
    private var storageReadFailed = false
    private var task: Task<Void, Never>?
    private var subscriptions: Set<AnyCancellable> = []
    private var localRoutingInputs: RoutingInputs?
    private var routingFingerprint: ServiceRoutingFingerprint?

    init(storageURL: URL) {
        self.storageURL = storageURL
        do {
            guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
            let saved = try JSONDecoder().decode([ServiceEndpoint].self, from: Data(contentsOf: storageURL))
            var identifiers = Set(services.map(\.id))
            for service in saved {
                guard !service.id.hasPrefix("builtin."), !service.id.isEmpty,
                      identifiers.insert(service.id).inserted,
                      !service.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      service.name.count <= 80, ServiceEndpoint.validatedURL(service.url) != nil else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
            services += saved
        } catch {
            storageReadFailed = true
            storageError = "无法读取已保存的服务；请检查本地文件。 / Cannot read saved services. \(error.localizedDescription)"
        }
    }

    isolated deinit { task?.cancel() }

    var hasStaleResults: Bool { results.values.contains { $0.current.isStale || $0.direct.isStale } }
    var completedCount: Int {
        services.filter { service in
            guard let row = results[service.id] else { return false }
            return ServiceProbeKind.allCases.allSatisfy { ![.pending, .checking, .cancelled].contains(row[$0].state) }
        }.count
    }

    func add(name: String, url: String) throws {
        guard !isRunning else { return }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let validated = ServiceEndpoint.validatedURL(url) else { throw CocoaError(.validationMissingMandatoryProperty) }
        let service = ServiceEndpoint(id: UUID().uuidString, name: name, url: validated.absoluteString)
        let updated = services + [service]
        try persist(updated)
        services = updated
        lastRunCompleted = false
    }

    func delete(_ service: ServiceEndpoint) {
        guard !service.isBuiltIn else { return }
        let updated = services.filter { $0.id != service.id }
        do {
            try persist(updated)
            services = updated
            results[service.id] = nil
        } catch {
            storageError = "未能删除服务，请检查本地文件权限后重试。 / Could not delete the service. \(error.localizedDescription)"
        }
    }

    private func persist(_ services: [ServiceEndpoint]) throws {
        guard !storageReadFailed else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(services.filter { !$0.isBuiltIn }).write(to: storageURL, options: .atomic)
        storageError = nil
    }

    func start(checker: any ServiceStatusChecking, routingClient: (any MihomoAPITransporting)? = nil) {
        guard task == nil else { return }
        let snapshot = services
        results = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, ServiceStatusRow()) })
        isRunning = true
        isCancelling = false
        lastRunCompleted = false
        routingVerificationFailed = false
        task = Task { [weak self] in
            guard let self else { await checker.close(); return }
            do {
                let baseline: ServiceRoutingFingerprint?
                if let routingClient {
                    // Establish a fresh baseline before making any requests.
                    do {
                        baseline = try await ServiceRoutingFingerprint.load(client: routingClient)
                        self.routingFingerprint = baseline
                    }
                    catch {
                        try Task.checkCancellation()
                        baseline = nil
                        self.routingFingerprint = nil
                        self.routingVerificationFailed = true
                    }
                } else { baseline = nil }
                try await checker.prepare()
                for service in snapshot {
                    try Task.checkCancellation()
                    guard self.services.contains(where: { $0.id == service.id }) else { continue }
                    self.activeServiceName = service.name
                    self.results[service.id] = ServiceStatusRow(current: ServiceProbeResult(state: .checking), direct: ServiceProbeResult(state: .checking))
                    try await withThrowingTaskGroup(of: (ServiceProbeKind, ServiceProbeResult).self) { group in
                        for kind in ServiceProbeKind.allCases {
                            group.addTask { (kind, try await checker.measure(service, kind: kind)) }
                        }
                        for try await (kind, result) in group {
                            try Task.checkCancellation()
                            guard self.results[service.id] != nil else { continue }
                            self.results[service.id]?[kind] = result
                            self.lastCheckedAt = result.checkedAt ?? self.lastCheckedAt
                        }
                    }
                }
                if let routingClient {
                    let final = try await ServiceRoutingFingerprint.load(client: routingClient)
                    if let baseline {
                        if final != baseline { self.invalidate() }
                    } else {
                        self.invalidate(cannotVerifyRouting: true)
                    }
                }
                try Task.checkCancellation()
                self.lastRunCompleted = true
            } catch {
                if Task.isCancelled {
                    self.markUnfinished(as: .cancelled)
                } else {
                    self.markUnfinished(as: .unavailable, detail: error.localizedDescription)
                    // A failed final snapshot cannot certify old routes as current.
                    self.markResultsStale()
                    self.routingVerificationFailed = true
                }
            }
            await checker.close()
            self.activeServiceName = nil
            self.isRunning = false
            self.isCancelling = false
            self.task = nil
        }
    }

    func cancel() {
        guard task != nil else { return }
        isCancelling = true
        task?.cancel()
        markUnfinished(as: .cancelled)
    }

    func invalidate(cannotVerifyRouting: Bool = false) {
        cancel()
        markResultsStale()
        routingVerificationFailed = cannotVerifyRouting
        lastRunCompleted = false
    }

    private func markResultsStale() {
        for id in Array(results.keys) {
            for kind in ServiceProbeKind.allCases where results[id]?[kind].checkedAt != nil {
                results[id]?[kind].isStale = true
            }
        }
    }

    private func markUnfinished(as state: ServiceProbeState, detail: String? = nil) {
        for id in Array(results.keys) {
            for kind in ServiceProbeKind.allCases {
                if let existing = results[id]?[kind], [.pending, .checking].contains(existing.state) {
                    results[id]?[kind] = ServiceProbeResult(state: state, detail: detail)
                }
            }
        }
    }

    func acceptRoutingFingerprint(_ fingerprint: ServiceRoutingFingerprint) {
        if let previous = routingFingerprint, previous != fingerprint { invalidate() }
        routingFingerprint = fingerprint
    }

    func monitor(client: any MihomoAPITransporting) async {
        while !Task.isCancelled {
            do {
                let fingerprint = try await ServiceRoutingFingerprint.load(client: client)
                try Task.checkCancellation()
                acceptRoutingFingerprint(fingerprint)
                try await Task.sleep(for: .seconds(2))
            } catch {
                guard !Task.isCancelled else { return }
                // API failure does not make the independent DIRECT request
                // invalid. Let measurements finish, but do not certify them
                // against a routing snapshot we cannot read.
                markResultsStale()
                routingVerificationFailed = true
                lastRunCompleted = false
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
    }

    /// Keep invalidation alive when another dashboard page is selected. These
    /// app inputs complement live core snapshots; no selected node is used as
    /// evidence of the route taken by a request.
    func observe(app: AppViewModel) {
        guard subscriptions.isEmpty else { return }
        localRoutingInputs = Self.routingInputs(app)
        let changed: () -> Void = { [weak self, weak app] in
            Task { @MainActor [weak self, weak app] in
                guard let self, let app else { return }
                let inputs = Self.routingInputs(app)
                if self.localRoutingInputs != inputs { self.invalidate(); self.localRoutingInputs = inputs }
            }
        }
        app.objectWillChange.sink { changed() }.store(in: &subscriptions)
        app.proxyStore.objectWillChange.sink { changed() }.store(in: &subscriptions)
        app.remoteMachineStore.objectWillChange.sink { changed() }.store(in: &subscriptions)
    }

    private struct RoutingInputs: Equatable {
        let mode: String
        let config: String
        let controller: String
        let secret: String?
        let remote: Bool
        let running: Bool
        let tun: Bool
        let network: NetworkReachabilityStatus
        let effective: EffectiveConfigRecord?
        let configSignatures: [String: String]
        let selections: [String]
    }

    private static func routingInputs(_ app: AppViewModel) -> RoutingInputs {
        RoutingInputs(mode: app.currentMode.rawValue, config: app.selectedConfigName, controller: app.controller,
                      secret: app.controllerSecret, remote: app.isRemoteTarget, running: app.isRuntimeRunning,
                      tun: app.isTunEnabled, network: app.networkReachabilityStatus,
                      effective: app.dashboardEffectiveRecord, configSignatures: app.configFileSignatureSnapshot,
                      selections: app.proxyGroups.map { "\($0.name):\($0.now ?? "")" }.sorted())
    }
}
