import AppKit
import SwiftUI

final class DashboardWindow: NSWindow {
    func installContent<Content: View>(_ view: Content) {
        let container = NSView(frame: contentView?.bounds ?? .zero)
        let hosting = NSHostingView(rootView: view.ignoresSafeArea())
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        container.addSubview(hosting)
        contentView = container

        let controls = NSView()
        controls.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(controls)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 29),
            controls.topAnchor.constraint(equalTo: container.topAnchor, constant: 29),
            controls.widthAnchor.constraint(equalToConstant: 54),
            controls.heightAnchor.constraint(equalToConstant: 14)
        ])
        for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = standardWindowButton(type) else { continue }
            button.removeFromSuperview()
            controls.addSubview(button)
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: CGFloat(index * 20)),
                button.centerYAnchor.constraint(equalTo: controls.centerYAnchor)
            ])
        }
    }
}

struct DashboardView: View {
    @ObservedObject var appViewModel: AppViewModel
    @ObservedObject private var remoteMachineStore: RemoteMachineStore
    @State private var selection: Page
    @State private var hoveredPage: Page?
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
        HStack(spacing: 0) {
            self.sidebar
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text(self.selection.title(language: self.appViewModel.uiLanguage))
                        .font(.system(size: 26, weight: .semibold))
                    if self.selection == .configuration {
                        Text(self.appViewModel.uiLanguage == .zhHans ? "管理本地配置与远程订阅" : "Manage local configurations and subscriptions")
                            .font(.system(size: 12))
                            .foregroundStyle(Color(red: 0.32, green: 0.40, blue: 0.46))
                            .padding(.top, -14)
                    }
                    switch self.selection {
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
        .background(Color.white)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("ClashBar")
                .font(.system(size: 22, weight: .semibold))
                .padding(.horizontal, 12)
                .padding(.top, 58)

            Text(self.appViewModel.uiLanguage == .zhHans ? "工作区" : "Workspace")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 30)
                .padding(.bottom, 10)

            ForEach(Page.allCases, id: \.self) { page in
                Button {
                    self.selection = page
                } label: {
                    Label(page.title(language: self.appViewModel.uiLanguage), systemImage: page.symbol)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .frame(height: 42)
                        .background(self.selection == page ? Color.black.opacity(0.06) :
                            self.hoveredPage == page ? Color.black.opacity(0.035) : .clear,
                                    in: RoundedRectangle(cornerRadius: 9))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { isHovering in
                    if isHovering {
                        self.hoveredPage = page
                    } else if self.hoveredPage == page {
                        self.hoveredPage = nil
                    }
                }
            }

            Spacer(minLength: 24)

            Text(self.appViewModel.uiLanguage == .zhHans ? "当前目标" : "Current target")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 10)
            VStack(alignment: .leading, spacing: 5) {
                Text(self.targetName)
                Text(self.appViewModel.externalControllerDisplay)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            .padding(.bottom, 12)
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: NSColor(calibratedWhite: 0.97, alpha: 1)),
                    in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.black.opacity(0.10), lineWidth: 1))
        .shadow(color: .black.opacity(0.10), radius: 4, y: 2)
        .padding(10)
        .frame(width: 236)
    }

    private var targetName: String {
        switch self.remoteMachineStore.activeTarget {
        case .local: self.appViewModel.uiLanguage == .zhHans ? "本地核心" : "Local core"
        case .remote(let machine): machine.name
        }
    }
}
