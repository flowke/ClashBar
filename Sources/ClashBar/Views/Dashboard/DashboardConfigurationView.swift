import AppKit
import SwiftUI

private struct DashboardSectionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        DashboardHoverButtonLabel(configuration: configuration, isEnabled: isEnabled, filled: true)
    }
}

private struct DashboardHoverButtonLabel: View {
    let configuration: ButtonStyle.Configuration
    let isEnabled: Bool
    let filled: Bool
    @State private var hovered = false

    var body: some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(filled ? Color(red: 0.20, green: 0.35, blue: 0.45) : Color(red: 0.14, green: 0.37, blue: 0.55))
            .padding(.horizontal, filled ? 18 : 3).frame(height: filled ? 32 : 24)
            .background(filled ? Color(red: 0.89, green: 0.93, blue: 0.95).opacity(hovered ? 0.7 : 1) :
                (hovered ? Color.black.opacity(0.06) : .clear), in: RoundedRectangle(cornerRadius: filled ? 9 : 5))
            .opacity(configuration.isPressed ? 0.65 : 1)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
            .onHover { hovered = $0 && isEnabled }
    }
}

private struct DashboardTextButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        DashboardHoverButtonLabel(configuration: configuration, isEnabled: isEnabled, filled: false)
    }
}

private struct DashboardMenuItemStyle: ButtonStyle {
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(hovered ? Color.black.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .opacity(configuration.isPressed ? 0.65 : 1)
            .onHover { hovered = $0 }
    }
}

struct DashboardCustomRuleRequest: Equatable {
    let id = UUID()
    let operation: CustomRuleChange.Operation

    static func == (lhs: DashboardCustomRuleRequest, rhs: DashboardCustomRuleRequest) -> Bool {
        lhs.id == rhs.id
    }
}

private struct DashboardPreviewTextView: NSViewRepresentable {
    let contents: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.backgroundColor = .clear
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.lineBreakMode = .byCharWrapping
        textView.string = contents

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, textView.string != contents else { return }
        textView.string = contents
    }
}

struct DashboardSourcePreview: View {
    let name: String
    let contents: String
    let closeTitle: String
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(name).font(.headline).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button(closeTitle, action: close)
            }
            DashboardPreviewTextView(contents: contents)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(20).frame(width: 620, height: 480)
    }
}

struct DashboardConfigurationView: View {
    @ObservedObject var appViewModel: AppViewModel
    @State private var tab = 0
    @State private var customRuleRequest: DashboardCustomRuleRequest?
    @State private var editingName: String?
    @State private var editingValue = ""
    @State private var editingURL = ""
    @State private var editorError: String?
    @State private var editorSaving = false
    @State private var editingRemote = false
    @State private var viewingSource: SourcePreview?
    @State private var customRuleMenuPresented = false
    @State private var hoveredSource: String?
    @State private var hoveredTab: Int?
    @State private var hoveredMenu: String?
    @State private var cardIssues: [String: CardIssue] = [:]
    @State private var sectionIssues: [Bool: CardIssue] = [:]
    @State private var dismissedSubscriptionIssues: Set<String> = []

    private struct CardIssue {
        let title: String
        let details: String
    }

    private struct SourcePreview: Identifiable {
        let id = UUID()
        let name: String
        let contents: String
    }

    init(appViewModel: AppViewModel, initialTab: Int = 0) {
        self.appViewModel = appViewModel
        self._tab = State(initialValue: initialTab)
    }

    private var isChinese: Bool { appViewModel.uiLanguage == .zhHans }
    private func text(_ zh: String, _ en: String) -> String { isChinese ? zh : en }
    private var changes: [CustomRuleChange] { appViewModel.dashboardEffectiveRecord?.changes ?? [] }
    private var local: [String] { appViewModel.availableConfigFileNames.filter { appViewModel.remoteConfigSubscriptions[$0] == nil } }
    private var remote: [String] { appViewModel.availableConfigFileNames.filter { appViewModel.remoteConfigSubscriptions[$0] != nil } }
    private let ink = Color(red: 0.13, green: 0.20, blue: 0.25)
    private let muted = Color(red: 0.32, green: 0.42, blue: 0.49)
    private let link = Color(red: 0.14, green: 0.37, blue: 0.55)
    private let card = Color(red: 0.96, green: 0.97, blue: 0.975)
    private let accent = Color(red: 0.11, green: 0.48, blue: 0.32)

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 12) {
                configurationTabs.frame(maxWidth: 451)
                if tab == 1 {
                    Spacer(minLength: 12)
                    Button {
                        customRuleRequest = nil
                        customRuleMenuPresented.toggle()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                            Text(text("新增规则", "Add rule"))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                        }
                    }
                    .buttonStyle(DashboardSectionButtonStyle())
                    .disabled(appViewModel.dashboardConfigBusy || appViewModel.isRemoteTarget)
                    .popover(isPresented: $customRuleMenuPresented, arrowEdge: .bottom) {
                        customRuleMenu
                    }
                }
            }
            if tab != 1, let error = appViewModel.dashboardConfigError {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            if appViewModel.isRemoteTarget {
                Text(text("配置管理仅适用于本地核心。", "Configuration management is available for the local core."))
                    .foregroundStyle(.secondary)
            }
            switch tab {
            case 0: effectiveView
            case 1: DashboardCustomRulesView(appViewModel: appViewModel, request: $customRuleRequest)
            default: sourcesView
            }
        }
        .onAppear { appViewModel.refreshDashboardEffectiveConfig() }
        .onChange(of: tab) { newTab in
            if newTab != 1 {
                customRuleMenuPresented = false
                customRuleRequest = nil
            }
        }
        .onChange(of: appViewModel.isRemoteTarget) { _ in
            cardIssues.removeAll()
            sectionIssues.removeAll()
            dismissedSubscriptionIssues.removeAll()
        }
        .onChange(of: appViewModel.remoteConfigMenuStates) { states in
            for (name, state) in states where state.phase == .refreshing {
                dismissedSubscriptionIssues.remove(name)
            }
        }
        .sheet(isPresented: Binding(get: { editingName != nil }, set: { if !$0 { editingName = nil } })) { sourceEditor }
        .sheet(item: $viewingSource) { source in
            DashboardSourcePreview(name: source.name, contents: source.contents, closeTitle: text("关闭", "Close")) { viewingSource = nil }
        }
    }

    private var customRuleMenu: some View {
        VStack(alignment: .leading, spacing: 2) {
            customRuleMenuItem(.add)
            customRuleMenuItem(.replace)
            customRuleMenuItem(.delete)
        }
        .padding(6)
        .frame(width: 164)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func customRuleMenuItem(_ operation: CustomRuleChange.Operation) -> some View {
        Button {
            customRuleMenuPresented = false
            customRuleRequest = DashboardCustomRuleRequest(operation: operation)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: operation == .add ? "plus" : operation == .replace ? "arrow.triangle.2.circlepath" : "minus.circle")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 16)
                Text(operationMenuLabel(operation))
                Spacer(minLength: 0)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(operation == .delete ? Color(red: 0.62, green: 0.28, blue: 0.22) : ink)
            .padding(.horizontal, 9)
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(DashboardMenuItemStyle())
    }

    private func operationMenuLabel(_ operation: CustomRuleChange.Operation) -> String {
        switch operation {
        case .add: return text("新增规则", "Add rule")
        case .replace: return text("替换规则", "Replace rule")
        case .delete: return text("删除规则", "Delete rule")
        }
    }

    private var configurationTabs: some View {
        HStack(spacing: 0) {
            ForEach(Array([text("生效的配置", "Effective"), text("自定义配置", "Custom rules"), text("选择的配置", "Sources")].enumerated()), id: \.offset) { index, title in
                Button { tab = index } label: {
                    Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        .frame(maxWidth: .infinity).frame(height: 32)
                        .background(tab == index ? Color.white : hoveredTab == index ? Color.white.opacity(0.45) : .clear, in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoveredTab = $0 ? index : (hoveredTab == index ? nil : hoveredTab) }
                .foregroundStyle(tab == index ? ink : muted)
                .accessibilityAddTraits(tab == index ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Color(red: 0.89, green: 0.92, blue: 0.94), in: RoundedRectangle(cornerRadius: 10))
    }

    private var effectiveView: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let record = appViewModel.dashboardEffectiveRecord {
                VStack(alignment: .leading, spacing: 5) {
                    Text(text("配置已生成", "Configuration generated"))
                        .font(.system(size: 13, weight: .medium))
                    Text("\(record.baseName)  ·  \(record.changes.count) \(text("项自定义变更", "custom changes"))")
                        .font(.caption)
                }
                .foregroundStyle(Color(red: 0.11, green: 0.39, blue: 0.28))
                .frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .background(Color(red: 0.91, green: 0.96, blue: 0.93), in: RoundedRectangle(cornerRadius: 12))
            }
            HStack {
                Text(text("最终生效规则", "Effective rules")).font(.headline)
                Spacer()
                Button(text("导出配置", "Export configuration")) { exportEffective() }
                    .buttonStyle(DashboardSectionButtonStyle())
                    .disabled(effectiveURL == nil)
            }
            if let url = effectiveURL, let data = try? Data(contentsOf: url) {
                if let rules = try? ConfigRuleMerger().rules(in: data) {
                    let origins = ruleOrigins(effectiveRules: rules)
                    if rules.isEmpty { Text(text("没有规则", "No rules")).foregroundStyle(.secondary) }
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rules.enumerated()), id: \.offset) { index, rule in
                            HStack(alignment: .top, spacing: 12) {
                                Text(rule).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(ruleSource(origins?[index])).font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 10)
                            if index < rules.count - 1 { Divider() }
                        }
                    }.padding(16).background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                } else {
                    Text(text("无法读取规则", "Unable to read rules")).foregroundStyle(.secondary)
                }
                if let contents = String(data: data, encoding: .utf8) {
                    DisclosureGroup(text("完整配置（只读）", "Full configuration (read-only)")) {
                        Text(contents).font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 12)
                    }
                    .padding(16).background(Color.black.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                }
            } else {
                Text(text("暂无生效配置", "No effective configuration")).foregroundStyle(.secondary)
            }
        }
    }

    private func ruleOrigins(effectiveRules: [String]) -> [ConfigRuleMerger.ResolvedRule]? {
        guard let record = appViewModel.dashboardEffectiveRecord,
              let source = appViewModel.configService.availableConfigs.first(where: { $0.lastPathComponent == record.baseName }),
              let data = try? Data(contentsOf: source),
              let baseRules = try? ConfigRuleMerger().rules(in: data),
              let resolved = try? ConfigRuleMerger().resolve(rules: baseRules, changes: record.changes),
              resolved.map(\.value) == effectiveRules else { return nil }
        return resolved
    }

    private func ruleSource(_ rule: ConfigRuleMerger.ResolvedRule?) -> String {
        guard let rule else { return text("来源未知", "Unknown") }
        switch rule.origin {
        case .add: return text("自定义 · 新增", "Custom · added")
        case .replace: return text("自定义 · 覆盖", "Custom · replaced")
        default: return text("基础配置", "Base")
        }
    }

    private func previewSource(_ name: String) {
        guard let url = appViewModel.configService.availableConfigs.first(where: { $0.lastPathComponent == name }) else {
            cardIssues[name] = CardIssue(title: text("查看失败", "Unable to open"), details: text("配置文件不存在", "Configuration file not found"))
            return
        }
        do {
            viewingSource = SourcePreview(name: name, contents: try String(contentsOf: url, encoding: .utf8))
        } catch {
            cardIssues[name] = CardIssue(title: text("查看失败", "Unable to open"), details: error.localizedDescription)
        }
    }

    private var effectiveURL: URL? {
        if appViewModel.dashboardEffectiveRecord != nil {
            return appViewModel.effectiveConfigURL(for: appViewModel.selectedConfigName)
        }
        return appViewModel.effectiveConfigURL(for: appViewModel.selectedConfigName) ?? appViewModel.configService.selectedConfig
    }

    private var sourcesView: some View {
        VStack(alignment: .leading, spacing: 28) {
            sourceSection(text("本地配置", "Local configurations"), names: local, remote: false)
            sourceSection(text("远程订阅", "Subscriptions"), names: remote, remote: true)
        }
    }

    private func sourceSection(_ title: String, names: [String], remote: Bool) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.system(size: 16, weight: .medium)).foregroundStyle(ink)
                Spacer()
                Button(remote ? text("添加订阅", "Add subscription") : text("导入配置", "Import")) {
                    Task {
                        sectionIssues[remote] = nil
                        let previousError = appViewModel.dashboardConfigError
                        appViewModel.dashboardConfigError = nil
                        if remote { await appViewModel.importRemoteConfigFile(manualOnly: true, dashboardErrors: true) }
                        else { appViewModel.importLocalConfigFile(dashboardErrors: true) }
                        if let details = appViewModel.dashboardConfigError {
                            sectionIssues[remote] = CardIssue(title: remote ? text("添加失败", "Add failed") : text("导入失败", "Import failed"), details: details)
                        }
                        appViewModel.dashboardConfigError = previousError
                    }
                }
                .buttonStyle(DashboardSectionButtonStyle())
                .disabled(appViewModel.dashboardConfigBusy || appViewModel.isRemoteTarget)
            }
            if let issue = sectionIssues[remote] {
                cardIssueView(issue) { sectionIssues[remote] = nil }.frame(maxWidth: 400, alignment: .leading)
            }
            if names.isEmpty { Text(text("暂无配置", "No configurations")).foregroundStyle(.secondary) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 299), spacing: 16)], alignment: .leading, spacing: 16) {
                ForEach(names, id: \.self) { name in
                    let selected = name == appViewModel.selectedConfigName
                    let canApply = !selected && !appViewModel.dashboardConfigBusy && !appViewModel.isRemoteTarget && (appViewModel.remoteConfigSubscriptions[name]?.isEnabled ?? true)
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 6) {
                            Text(name).font(.system(size: 15, weight: .semibold)).foregroundStyle(ink).lineLimit(1).truncationMode(.middle)
                                .allowsHitTesting(false)
                            Spacer(minLength: 0)
                            if selected { Label(text("当前基础配置", "Current"), systemImage: "checkmark").foregroundStyle(accent).font(.system(size: 11)).fixedSize().allowsHitTesting(false) }
                            if remote {
                                let updating = appViewModel.remoteConfigMenuState(for: name).phase == .refreshing
                                Button {
                                    cardIssues[name] = nil
                                    dismissedSubscriptionIssues.remove(name)
                                    Task { await appViewModel.refreshRemoteConfigFile(named: name) }
                                } label: {
                                    if updating {
                                        ProgressView().controlSize(.small).frame(width: 18, height: 18)
                                    } else {
                                        Image(systemName: "arrow.clockwise").frame(width: 18, height: 18)
                                    }
                                }
                                .buttonStyle(DashboardTextButtonStyle())
                                .help(text("更新订阅", "Update subscription"))
                                .accessibilityLabel(text("更新订阅", "Update subscription"))
                                .disabled(appViewModel.dashboardConfigBusy || appViewModel.isRemoteTarget || !(appViewModel.remoteConfigSubscriptions[name]?.isEnabled ?? true) || updating)
                            }
                        }
                        if remote {
                            subscriptionDetails(name)
                                .allowsHitTesting(false)
                        } else if let url = appViewModel.configService.availableConfigs.first(where: { $0.lastPathComponent == name }) {
                            if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                                Text("\(text("本地文件 · 修改于", "Local file · Modified")) \(modified.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.system(size: 11)).foregroundStyle(muted).lineLimit(2)
                                    .allowsHitTesting(false)
                            }
                        }
                        if let issue = cardIssues[name] {
                            cardIssueView(issue) { cardIssues[name] = nil }
                        } else if remote, appViewModel.remoteConfigMenuState(for: name).phase == .failed,
                                  !dismissedSubscriptionIssues.contains(name) {
                            cardIssueView(CardIssue(title: text("更新失败", "Update failed"),
                                                    details: appViewModel.dashboardSubscriptionErrors[name] ?? text("无法更新订阅。", "Unable to update subscription."))) {
                                dismissedSubscriptionIssues.insert(name)
                            }
                        }
                        Spacer(minLength: 0)
                        HStack(spacing: 10) {
                            Button(text("查看", "View")) { previewSource(name) }
                            if remote {
                                Button(text("编辑", "Edit")) {
                                    editingRemote = true
                                    editingValue = name
                                    editingURL = appViewModel.remoteConfigSubscriptions[name]?.urlString ?? ""
                                    editorError = nil
                                    editingName = name
                                }.disabled(appViewModel.dashboardConfigBusy || appViewModel.isRemoteTarget || appViewModel.remoteConfigMenuState(for: name).phase == .refreshing)
                                let enabled = appViewModel.remoteConfigSubscriptions[name]?.isEnabled ?? true
                                Button(enabled ? text("停用", "Disable") : text("启用", "Enable")) {
                                    Task {
                                        await cardOperation(name, title: enabled ? text("停用失败", "Disable failed") : text("启用失败", "Enable failed")) {
                                            await appViewModel.setDashboardSubscriptionEnabled(!enabled, name: name)
                                        }
                                    }
                                }.disabled(appViewModel.dashboardConfigBusy || appViewModel.isRemoteTarget)
                            } else {
                                Button(text("导出", "Export")) { exportSource(name) }
                                    .disabled(appViewModel.dashboardConfigBusy || appViewModel.isRemoteTarget)
                            }
                            sourceMenu(name, remote: remote)
                        }
                        .buttonStyle(DashboardTextButtonStyle()).font(.system(size: 12))
                    }
                    .padding(20).frame(maxWidth: .infinity, minHeight: remote ? 227 : 126, alignment: .topLeading)
                    .background {
                        Button { applyBase(name) } label: {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(hoveredSource == name && canApply ? Color(red: 0.92, green: 0.95, blue: 0.96) : card)
                                .contentShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .disabled(!canApply)
                        .accessibilityLabel("\(text("应用配置", "Apply configuration")) \(name)")
                    }
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(selected ? accent.opacity(0.75) : .clear, lineWidth: 1).allowsHitTesting(false))
                    .onHover { hoveredSource = $0 ? name : (hoveredSource == name ? nil : hoveredSource) }
                    .help(!remote ? (appViewModel.configService.availableConfigs.first(where: { $0.lastPathComponent == name })?.path ?? name) + " · " + text("有效性未知", "Validity unknown") : name)
                }
            }
        }
    }

    private func sourceMenu(_ name: String, remote: Bool) -> some View {
        Menu {
            if !remote {
                Button(text("显示文件位置", "Show in Finder")) {
                    if let url = appViewModel.configService.availableConfigs.first(where: { $0.lastPathComponent == name }) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                Button(text("重命名", "Rename")) {
                    editingRemote = false
                    editingValue = name
                    editorError = nil
                    editingName = name
                }
                Divider()
            }
            Button(text("删除", "Delete"), role: .destructive) {
                Task { await cardOperation(name, title: text("删除失败", "Delete failed")) { await appViewModel.deleteDashboardConfig(name) } }
            }
        } label: {
            Text(text("更多", "More")).foregroundStyle(link)
                .padding(.horizontal, 3).frame(height: 24)
                .background(hoveredMenu == name && !appViewModel.dashboardConfigBusy && !appViewModel.isRemoteTarget ? Color.black.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 5))
        }
        .menuStyle(.borderlessButton).fixedSize().foregroundStyle(link)
        .onHover { hoveredMenu = $0 ? name : (hoveredMenu == name ? nil : hoveredMenu) }
        .disabled(appViewModel.dashboardConfigBusy || appViewModel.isRemoteTarget)
    }

    @ViewBuilder
    private func subscriptionDetails(_ name: String) -> some View {
        let subscription = appViewModel.remoteConfigSubscriptions[name]
        let state = appViewModel.remoteConfigMenuState(for: name)
        if subscription?.isEnabled == false { Text(text("已停用", "Disabled")).font(.caption).foregroundStyle(.secondary) }
        if state.phase == .refreshing {
            Text(text("正在更新", "Updating")).font(.caption).foregroundStyle(.secondary)
        } else if let updated = state.updatedAt {
            Text("\(text("更新于", "Updated")) \(updated.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
        }
        if let usage = subscription?.usage, let used = usage.used, let total = usage.total, total > 0 {
            Text("\(text("剩余", "Remaining")) \(ValueFormatter.bytesCompact(max(0, total - used)))")
                .font(.system(size: 14, weight: .semibold)).foregroundStyle(ink)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color(red: 0.85, green: 0.93, blue: 0.88))
                    Capsule().fill(Color(red: 0.16, green: 0.73, blue: 0.46))
                        .frame(width: geometry.size.width * min(1, Double(used) / Double(total)))
                }
            }
            .frame(height: 7)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text("流量已用", "Traffic used"))
            .accessibilityValue("\(Int(min(1, Double(used) / Double(total)) * 100))%")
            Text("\(text("已用", "Used")) \(ValueFormatter.bytesCompact(used)) / \(ValueFormatter.bytesCompact(total)) · \(Int(min(1, Double(used) / Double(total)) * 100))%")
                .font(.system(size: 11)).foregroundStyle(muted)
        } else {
            Text(text("暂无流量信息", "No traffic information")).font(.caption).foregroundStyle(.secondary)
        }
        if let expiry = subscription?.usage?.expiresAt {
            Text("\(text("到期", "Expires")) \(expiry.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var sourceEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(editingRemote ? text("编辑订阅", "Edit subscription") : text("重命名配置", "Rename configuration")).font(.headline)
            VStack(alignment: .leading, spacing: 5) {
                Text(text("名称", "Name")).font(.caption).foregroundStyle(.secondary)
                TextField(text("名称", "Name"), text: $editingValue)
            }
            if editingRemote {
                VStack(alignment: .leading, spacing: 5) {
                    Text(text("订阅地址", "Subscription URL")).font(.caption).foregroundStyle(.secondary)
                    TextField(text("订阅地址", "Subscription URL"), text: $editingURL)
                }
            }
            if let editorError { Text(editorError).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button(text("取消", "Cancel")) { editingName = nil }.disabled(editorSaving)
                Button(text("保存", "Save")) {
                    guard let name = editingName else { return }
                    let next = editingValue
                    if editingRemote {
                        let url = editingURL
                        editorSaving = true
                        editorError = nil
                        Task {
                            let previousError = appViewModel.dashboardConfigError
                            let saved = await appViewModel.editDashboardSubscription(name: name, newName: next, urlString: url)
                            editorError = appViewModel.dashboardConfigError
                            appViewModel.dashboardConfigError = previousError
                            editorSaving = false
                            if saved { editingName = nil }
                        }
                    } else {
                        editingName = nil
                        Task { await cardOperation(name, title: text("重命名失败", "Rename failed")) { await appViewModel.renameDashboardConfig(name, to: next) } }
                    }
                }.keyboardShortcut(.defaultAction).disabled(editorSaving)
            }
        }.padding(24).frame(width: 460)
    }

    private func applyBase(_ name: String) {
        Task {
            await cardOperation(name, title: text("应用失败", "Apply failed")) {
                await appViewModel.applyDashboardConfiguration(baseName: name, changes: changes)
            }
        }
    }

    private func cardOperation(_ name: String, title: String, operation: () async -> Void) async {
        cardIssues[name] = nil
        let previousError = appViewModel.dashboardConfigError
        appViewModel.dashboardConfigError = nil
        await operation()
        captureCardIssue(name, title: title)
        appViewModel.dashboardConfigError = previousError
    }

    private func captureCardIssue(_ name: String, title: String) {
        guard let details = appViewModel.dashboardConfigError else { return }
        cardIssues[name] = CardIssue(title: title, details: details)
        appViewModel.dashboardConfigError = nil
    }

    private func cardIssueView(_ issue: CardIssue, dismiss: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(Color(red: 0.68, green: 0.29, blue: 0.16))
                Text(issue.title).fontWeight(.semibold)
                Spacer(minLength: 4)
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(DashboardTextButtonStyle())
                    .help(text("关闭提示", "Dismiss"))
            }
            Text(text("操作未完成，请查看详情后重试。", "The operation did not complete. Check details and try again."))
                .foregroundStyle(muted)
            DisclosureGroup(text("查看详情", "Details")) {
                Text(issue.details).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 4)
            }
            .tint(link)
        }
        .font(.system(size: 11))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(red: 0.99, green: 0.95, blue: 0.92), in: RoundedRectangle(cornerRadius: 8))
    }

    private func exportEffective() {
        guard let url = effectiveURL else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "ClashBar-effective.yaml"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try Data(contentsOf: url).write(to: destination, options: .atomic) }
        catch { appViewModel.dashboardConfigError = error.localizedDescription }
    }

    private func exportSource(_ name: String) {
        guard let url = appViewModel.configService.availableConfigs.first(where: { $0.lastPathComponent == name }) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do { try Data(contentsOf: url).write(to: destination, options: .atomic) }
        catch { cardIssues[name] = CardIssue(title: text("导出失败", "Export failed"), details: error.localizedDescription) }
    }
}
