import AppKit
import SwiftUI

@MainActor
final class DashboardSidebarState: ObservableObject {
    @Published var columnVisibility: NavigationSplitViewVisibility = .all
}

final class DashboardWindow: NSWindow {
    let sidebarState = DashboardSidebarState()

    func configureTitlebar() {
        self.titleVisibility = .hidden
        self.titlebarAppearsTransparent = true
        self.toolbarStyle = .unified
        self.titlebarSeparatorStyle = .none
        // NavigationSplitView owns the toolbar, its sidebar section and its
        // toggle action. Replacing that toolbar here loses that integration.
    }
}

struct DashboardView: View {
    @ObservedObject var appViewModel: AppViewModel
    @ObservedObject private var remoteMachineStore: RemoteMachineStore
    @ObservedObject private var sidebarState: DashboardSidebarState
    @State private var selection: Page?
    private let initialConfigurationTab: Int
    private let sidebarBackground = Color(red: 238 / 255, green: 238 / 255, blue: 238 / 255)

    init(appViewModel: AppViewModel, sidebarState: DashboardSidebarState = DashboardSidebarState(), initialPage: Page = .overview, initialConfigurationTab: Int = 0) {
        self.appViewModel = appViewModel
        self.remoteMachineStore = appViewModel.remoteMachineStore
        self.sidebarState = sidebarState
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
        NavigationSplitView(columnVisibility: self.$sidebarState.columnVisibility) {
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
            .background {
                Color.white.ignoresSafeArea()
            }
        }
        .modifier(DashboardToolbarAppearance())
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            VStack(spacing: 4) {
                ForEach(Page.allCases, id: \.self) { page in
                    SidebarNavigationItem(
                        title: page.title(language: self.appViewModel.uiLanguage),
                        symbol: page.symbol,
                        isSelected: (self.selection ?? .overview) == page)
                    {
                        self.selection = page
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 6) {
                Text(self.targetName)
                    .font(.system(size: 14))
                    .foregroundStyle(Color(red: 34 / 255, green: 51 / 255, blue: 63 / 255))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    Circle()
                        .fill(self.appViewModel.runtimeVisualStatus.color)
                        .frame(width: 8, height: 8)
                    Text(self.appViewModel.proxyEndpointDisplay)
                        .font(.system(size: 12))
                        .foregroundStyle(Color(red: 76 / 255, green: 93 / 255, blue: 105 / 255))
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(self.runtimeStatusDescription), \(self.appViewModel.proxyEndpointDisplay)")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .frame(height: 60)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            self.sidebarBackground.ignoresSafeArea(edges: .top)
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 236)
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

private struct DashboardToolbarAppearance: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content
                .toolbarVisibility(.visible, for: .windowToolbar)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content
                .toolbar(.visible, for: .windowToolbar)
                .toolbarBackground(.hidden, for: .windowToolbar)
        }
    }
}

private struct SidebarNavigationItem: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    private let accent = Color(red: 22 / 255, green: 133 / 255, blue: 245 / 255)

    var body: some View {
        Button(action: self.action) {
            HStack(spacing: 12) {
                Image(systemName: self.symbol)
                    .font(.system(size: 16))
                    .frame(width: 16, height: 16)
                    .foregroundStyle(self.isSelected ? Color.white : self.accent)
                Text(self.title)
                    .font(.system(size: 15))
                    .foregroundStyle(self.isSelected ? Color.white : Color(red: 27 / 255, green: 41 / 255, blue: 51 / 255))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36)
            .background {
                RoundedRectangle(cornerRadius: 6)
                    .fill(self.isSelected ? self.accent : (self.isHovered ? Color(red: 213 / 255, green: 229 / 255, blue: 244 / 255) : .clear))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { self.isHovered = $0 }
        .accessibilityAddTraits(self.isSelected ? .isSelected : [])
    }
}
