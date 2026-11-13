import Foundation

@MainActor
struct AppDependencies {
    let processManager: any MihomoControlling
    let configService: ConfigService
    let systemProxyService: any SystemProxyServicing
    let tunPermissionService: TunPermissionService
    let launchAtLoginService: AppLaunchService
    let workingDirectoryManager: WorkingDirectoryManager
    let networkReachabilityMonitor: NetworkReachabilityMonitor
    let ssidMonitorService: SSIDMonitorService
    let remoteMachineStore: RemoteMachineStore
    let proxyGroupIconCache: ProxyGroupIconCache
    let webUIAssetService: WebUIAssetService
    let clashbarLogStore: AppLogStore
    let mihomoLogStore: AppLogStore

    static var live: AppDependencies {
        let workingDirectoryManager = WorkingDirectoryManager()
        let processManager = MihomoProcessManager(workingDirectoryManager: workingDirectoryManager)
        let configManager = ConfigDirectoryManager(workingDirectoryManager: workingDirectoryManager)
        let configService = ConfigService(
            configManager: configManager,
            configImportService: ConfigImportService())
        let sharedSession = URLSessionFactory.makeEphemeralSession(options: .init(
            timeoutIntervalForRequest: 15,
            timeoutIntervalForResource: 30,
            httpMaximumConnectionsPerHost: 4))
        let clashbarLogStore = AppLogStore(
            logFileURL: workingDirectoryManager.logsDirectoryURL.appendingPathComponent(
                "clashbar.log",
                isDirectory: false))
        let mihomoLogStore = AppLogStore(
            logFileURL: workingDirectoryManager.logsDirectoryURL.appendingPathComponent(
                "mihomo.log",
                isDirectory: false))

        return AppDependencies(
            processManager: processManager,
            configService: configService,
            systemProxyService: SystemProxyService(),
            tunPermissionService: TunPermissionService(),
            launchAtLoginService: AppLaunchService(),
            workingDirectoryManager: workingDirectoryManager,
            networkReachabilityMonitor: NetworkReachabilityMonitor(),
            ssidMonitorService: SSIDMonitorService(),
            remoteMachineStore: RemoteMachineStore(
                session: sharedSession,
                storageURL: workingDirectoryManager.stateDirectoryURL.appendingPathComponent(
                    "remote-machines.json",
                    isDirectory: false)),
            proxyGroupIconCache: ProxyGroupIconCache(
                iconDirectory: workingDirectoryManager.iconDirectoryURL,
                session: sharedSession),
            webUIAssetService: WebUIAssetService(
                workingDirectoryManager: workingDirectoryManager,
                session: sharedSession),
            clashbarLogStore: clashbarLogStore,
            mihomoLogStore: mihomoLogStore)
    }
}
