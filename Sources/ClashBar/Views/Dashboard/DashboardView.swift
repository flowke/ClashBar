import AppKit
import SwiftUI

final class DashboardWindow: NSWindow, NSToolbarDelegate {
    func installToolbar() {
        let toolbar = NSToolbar(identifier: "DashboardToolbar")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = false
        self.toolbar = toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar]
    }
}

struct DashboardView: View {
    @ObservedObject var appViewModel: AppViewModel
    @ObservedObject private var remoteMachineStore: RemoteMachineStore
    @State private var selection: Page?
    private let initialConfigurationTab: Int

    init(appViewModel: AppViewModel, initialPage: Page = .overview, initialConfigurationTab: Int = 0) {
        self.appViewModel = appViewModel
        self.remoteMachineStore = appViewModel.remoteMachineStore
        self._selection = State(initialValue: initialPage)
        self.initialConfigurationTab = initialConfigurationTab
    }

    enum Page: CaseIterable {
        case overview
        case configuration

        func title(language: AppLanguage) -> String {
            switch self {
            case .overview: language == .zhHans ? "概览" : "Overview"
            case .configuration: language == .zhHans ? "配置" : "Configuration"
            }
        }

        var symbol: String {
            switch self {
            case .overview: "square.grid.2x2"
            case .configuration: "doc.text"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            self.sidebar
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text((self.selection ?? .overview).title(language: self.appViewModel.uiLanguage))
                        .font(.system(size: 26, weight: .semibold))
                    if self.selection == .configuration {
                        Text(self.appViewModel.uiLanguage == .zhHans ? "管理本地配置与远程订阅" : "Manage local configurations and subscriptions")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(red: 0.32, green: 0.40, blue: 0.46))
                            .padding(.top, -14)
                    }
                    switch self.selection ?? .overview {
                    case .overview:
                        DashboardOverviewView(appViewModel: self.appViewModel)
                    case .configuration:
                        DashboardConfigurationView(appViewModel: self.appViewModel, initialTab: self.initialConfigurationTab)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(32)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var sidebar: some View {
        List(selection: self.$selection) {
            ForEach(Page.allCases, id: \.self) { page in
                Label(page.title(language: self.appViewModel.uiLanguage), systemImage: page.symbol)
                    .frame(minHeight: 22, alignment: .leading)
                    .tag(page)
                    .listRowInsets(EdgeInsets(top: 1, leading: 8, bottom: 1, trailing: 8))
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.sidebar)
        .environment(\.sidebarRowSize, .small)
        // Keep the active core visible at the bottom while the workspace list
        // remains independently scrollable. The inset is part of the native
        // sidebar, so its material and spacing follow macOS automatically.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(self.targetName)
                    .font(.body)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Circle()
                        .fill(self.appViewModel.runtimeVisualStatus.color)
                        .frame(width: 8, height: 8)
                    Text(self.appViewModel.proxyEndpointDisplay)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(self.runtimeStatusDescription), \(self.appViewModel.proxyEndpointDisplay)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(.regularMaterial)
        }
        .navigationSplitViewColumnWidth(min: 180, ideal: 220)
    }

    private var runtimeStatusDescription: String {
        let chinese = self.appViewModel.uiLanguage == .zhHans
        switch self.appViewModel.runtimeVisualStatus {
        case .runningHealthy: return chinese ? "运行正常" : "Running normally"
        case .runningDegraded: return chinese ? "运行异常" : "Running with degraded status"
        case .starting: return chinese ? "正在启动" : "Starting"
        case .failed: return chinese ? "运行失败" : "Failed"
        case .stopped: return chinese ? "已停止" : "Stopped"
        }
    }

    private var targetName: String {
        switch self.remoteMachineStore.activeTarget {
        case .local: self.appViewModel.uiLanguage == .zhHans ? "本地核心" : "Local core"
        case .remote(let machine): machine.name
        }
    }
}
