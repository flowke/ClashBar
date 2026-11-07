import Darwin
import SwiftUI

struct DashboardOverviewView: View {
    @ObservedObject var appViewModel: AppViewModel
    @ObservedObject private var trafficStore: TrafficStore
    @ObservedObject private var connectionsStore: ConnectionsStore
    private var zh: Bool { appViewModel.uiLanguage == .zhHans }
    private func t(_ chinese: String, _ english: String) -> String { zh ? chinese : english }
    private var unavailable: String { t("不可用", "Unavailable") }

    init(appViewModel: AppViewModel) {
        self.appViewModel = appViewModel
        self.trafficStore = appViewModel.trafficStore
        self.connectionsStore = appViewModel.connectionsStore
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(t("当前目标的运行状态与网络概况", "Current target status and network activity"))
                .foregroundStyle(.secondary)
            self.section(t("运行状态", "Status")) {
                self.metrics([
                    (t("核心状态", "Core status"), self.coreStatus),
                    (t("核心版本", "Core version"), self.appViewModel.apiStatus == .healthy && self.appViewModel.version != "-" ? self.appViewModel.version : unavailable),
                    (t("代理模式", "Proxy mode"), self.appViewModel.apiStatus == .healthy ? self.mode : unavailable),
                    (t("API 健康状态", "API status"), self.apiStatus),
                ])
            }
            self.section(t("网络概况", "Network")) {
                self.metrics([
                    (t("实时下载", "Download"), self.appViewModel.dashboardTrafficAvailable ? ValueFormatter.speed(self.trafficStore.traffic.down) : unavailable),
                    (t("实时上传", "Upload"), self.appViewModel.dashboardTrafficAvailable ? ValueFormatter.speed(self.trafficStore.traffic.up) : unavailable),
                    (t("当前连接", "Connections"), self.appViewModel.dashboardConnectionsAvailable ? "\(self.connectionsStore.connectionsCount)" : unavailable),
                    (t("累计下载", "Downloaded"), self.appViewModel.dashboardConnectionsAvailable ? self.connectionsStore.downloadTotal.map(ValueFormatter.bytesCompact) ?? unavailable : unavailable),
                    (t("累计上传", "Uploaded"), self.appViewModel.dashboardConnectionsAvailable ? self.connectionsStore.uploadTotal.map(ValueFormatter.bytesCompact) ?? unavailable : unavailable),
                ])
            }
            self.section(t("资源占用", "Resources")) {
                self.metrics([
                    (t("核心内存", "Core memory"), self.appViewModel.dashboardMemoryAvailable ? ValueFormatter.bytesCompact(self.trafficStore.memory.inuse) : unavailable),
                    (t("ClashBar 应用内存", "ClashBar memory"), Self.applicationMemory.map(ValueFormatter.bytesCompact) ?? unavailable),
                ])
            }
        }
    }

    private var coreStatus: String {
        if self.appViewModel.isRemoteTarget {
            return self.appViewModel.apiStatus == .healthy ? t("运行中", "Running") : unavailable
        }
        return self.appViewModel.isRuntimeRunning ? t("运行中", "Running") : t("已停止", "Stopped")
    }

    private var apiStatus: String {
        switch self.appViewModel.apiStatus {
        case .healthy: t("正常", "Healthy")
        case .degraded: t("异常", "Degraded")
        case .failed: unavailable
        case .unknown: t("未知", "Unknown")
        }
    }

    private var mode: String {
        switch self.appViewModel.currentMode {
        case .rule: t("规则", "Rule")
        case .global: t("全局", "Global")
        case .direct: t("直连", "Direct")
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title).font(.system(size: 15, weight: .medium))
            content()
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: NSColor(calibratedWhite: 0.965, alpha: 1)), in: RoundedRectangle(cornerRadius: 12))
    }

    private func metrics(_ items: [(String, String)]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 20)], alignment: .leading, spacing: 20) {
            ForEach(items.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 8) {
                    Text(items[index].0).font(.system(size: 12)).foregroundStyle(.secondary)
                    Text(items[index].1).font(.system(size: 18, weight: .medium)).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private static var applicationMemory: Int64? {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Int64(info.resident_size) : nil
    }
}
