import SwiftUI

struct DashboardServiceStatusView: View {
    @ObservedObject var appViewModel: AppViewModel
    @ObservedObject var model: ServiceStatusViewModel
    @State private var isAdding = false
    @State private var name = ""
    @State private var address = ""
    @State private var addError: String?
    @FocusState private var nameFocused: Bool

    private var chinese: Bool { appViewModel.uiLanguage == .zhHans }
    private func text(_ zh: String, _ en: String) -> String { chinese ? zh : en }
    private let ink = Color(red: 0.13, green: 0.20, blue: 0.25)
    private let muted = Color(red: 0.32, green: 0.42, blue: 0.49)
    private let border = Color(red: 0.85, green: 0.89, blue: 0.91)
    private let rowHeight: CGFloat = 88

    init(appViewModel: AppViewModel, model: ServiceStatusViewModel, initiallyAdding: Bool = false) {
        self.appViewModel = appViewModel
        self.model = model
        self._isAdding = State(initialValue: initiallyAdding)
    }
    private var monitorID: String {
        "\(appViewModel.controller)|\(appViewModel.controllerSecret ?? "")|\(appViewModel.isRemoteTarget)|\(appViewModel.isRuntimeRunning)|\(appViewModel.isDashboardPresented)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 20) { summary; Spacer(minLength: 8); actions }
                VStack(alignment: .leading, spacing: 14) { summary; actions }
            }
            if let error = model.storageError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(.red).textSelection(.enabled)
            }
            if model.hasStaleResults {
                Label(model.routingVerificationFailed
                      ? text("无法核对当前核心的线路配置，旧结果待重新检测。", "Unable to verify the core's routing inputs. Check again.")
                      : text("节点、模式、规则或网络已变更，旧结果待重新检测。", "Routing or network inputs changed. Check again to refresh the previous results."), systemImage: "exclamationmark.circle")
                    .font(.system(size: 12)).foregroundStyle(Color(red: 0.57, green: 0.36, blue: 0.15))
                    .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(red: 0.99, green: 0.96, blue: 0.91), in: RoundedRectangle(cornerRadius: 8))
            }
            GeometryReader { geometry in
                ScrollView(.horizontal) {
                    table(width: max(geometry.size.width, 760))
                }
                .scrollIndicators(geometry.size.width < 760 ? .visible : .hidden)
            }
            .frame(height: 49 + CGFloat(model.services.count) * (rowHeight + 1) + (isAdding ? (addError == nil ? 118 : 146) : 0) + 48)
            .background(.white, in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(border, lineWidth: 1))
            explanation
        }
        .task(id: monitorID) {
            guard appViewModel.isDashboardPresented, !appViewModel.isRemoteTarget, appViewModel.isRuntimeRunning else { return }
            let client = MihomoAPIService(controller: appViewModel.controller, secret: appViewModel.controllerSecret)
            await model.monitor(client: client)
        }
        .onReceive(appViewModel.$isDashboardPresented.removeDuplicates()) { presented in
            if !presented { model.cancel(); closeEditor() }
        }
        .onDisappear { model.cancel(); closeEditor() }
        .onExitCommand { if isAdding { closeEditor() } }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(summaryTitle).font(.system(size: 14, weight: .medium)).foregroundStyle(ink)
            HStack(spacing: 6) {
                if model.isRunning {
                    ProgressView().controlSize(.small).scaleEffect(0.75).frame(width: 12, height: 12)
                    Text(text("已完成 \(model.completedCount) / \(model.services.count) 项", "Completed \(model.completedCount) / \(model.services.count)"))
                    if let active = model.activeServiceName { Text("· \(active)").lineLimit(1) }
                } else {
                    Text(lastCheckText)
                    Text("· \(text("当前模式", "Mode"))：\(modeText)")
                }
            }
            .font(.system(size: 12)).foregroundStyle(muted)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var summaryTitle: String {
        if model.isRunning { return text("\(model.services.count) 项服务 · 检测中", "\(model.services.count) services · Checking") }
        if model.hasStaleResults {
            return model.routingVerificationFailed
                ? text("线路配置无法核对 · 待重新检测", "Route unverified · Check again")
                : text("线路配置已变更 · 待重新检测", "Route changed · Check again")
        }
        let suffix = model.lastRunCompleted ? text("已完成检测", "Checked") : text("待检测", "Ready to check")
        return text("\(model.services.count) 项服务 · \(suffix)", "\(model.services.count) services · \(suffix)")
    }

    private var lastCheckText: String {
        guard let date = model.lastCheckedAt else { return text("尚未检测", "Not checked yet") }
        return text("上次检测 ", "Last checked ") + date.formatted(date: .abbreviated, time: .standard)
    }

    private var modeText: String {
        switch appViewModel.currentMode {
        case .rule: text("规则", "Rule")
        case .global: text("全局", "Global")
        case .direct: text("直连", "Direct")
        }
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                isAdding = true
                nameFocused = true
            } label: { Label(text("新增", "Add"), systemImage: "plus") }
                .buttonStyle(ServiceStatusButtonStyle(primary: false))
                .disabled(model.isRunning || isAdding)
            Button {
                if model.isRunning { model.cancel() }
                else {
                    closeEditor()
                    let client = MihomoAPIService(controller: appViewModel.controller, secret: appViewModel.controllerSecret)
                    let checker = ServiceStatusChecker(client: client,
                                                       binary: appViewModel.resolvedMihomoBinaryPath().map { URL(fileURLWithPath: $0) } ?? appViewModel.workingDirectoryManager.managedMihomoBinaryURL,
                                                       local: !appViewModel.isRemoteTarget, running: appViewModel.isRuntimeRunning)
                    model.start(checker: checker, routingClient: !appViewModel.isRemoteTarget && appViewModel.isRuntimeRunning ? client : nil)
                }
            } label: {
                Label(model.isRunning ? text("取消检测", "Cancel Check") : text("检测全部", "Check All"),
                      systemImage: model.isRunning ? "xmark" : "arrow.clockwise")
            }
            .buttonStyle(ServiceStatusButtonStyle(primary: true))
            .disabled(model.isCancelling)
        }.fixedSize()
    }

    private func table(width: CGFloat) -> some View {
        let serviceWidth = (width - 40 - 72 - 60) * 0.27
        let currentWidth = (width - 40 - 72 - 60) * 0.44
        let directWidth = (width - 40 - 72 - 60) * 0.29
        return VStack(spacing: 0) {
            HStack(spacing: 24) {
                Text(text("服务 / 测试地址", "Service / URL")).frame(width: serviceWidth, alignment: .leading)
                Text(text("当前线路", "Current Route")).frame(width: currentWidth, alignment: .leading)
                Text(text("直连对照", "Direct Comparison")).frame(width: directWidth, alignment: .leading)
                Text(text("操作", "Actions")).frame(width: 60)
            }
            .font(.system(size: 12)).foregroundStyle(muted)
            .padding(.horizontal, 20).frame(height: 48)
            .background(Color(red: 0.956, green: 0.968, blue: 0.974))
            if isAdding { separator; editor }
            ForEach(model.services) { service in
                separator
                HStack(spacing: 24) {
                    serviceInfo(service).frame(width: serviceWidth, alignment: .leading)
                    ServiceStatusMeasurementView(result: model.results[service.id]?.current ?? ServiceProbeResult(), kind: .current, chinese: chinese)
                        .frame(width: currentWidth, alignment: .leading)
                    ServiceStatusMeasurementView(result: model.results[service.id]?.direct ?? ServiceProbeResult(), kind: .direct, chinese: chinese)
                        .frame(width: directWidth, alignment: .leading)
                    operation(service).frame(width: 60)
                }
                .padding(.horizontal, 20).frame(height: rowHeight)
                .accessibilityElement(children: .contain).accessibilityLabel(service.name)
            }
            separator
            Label(text("内置服务不可删除；新增服务可在操作栏直接删除。", "Built-in services are permanent. Custom services can be deleted in their row."), systemImage: "info.circle")
                .font(.system(size: 11)).foregroundStyle(muted)
                .frame(maxWidth: .infinity, minHeight: 47, alignment: .leading).padding(.horizontal, 20)
                .background(Color(red: 0.97, green: 0.979, blue: 0.983))
        }.frame(width: width)
    }

    private var separator: some View { border.frame(height: 1) }

    private func serviceInfo(_ service: ServiceEndpoint) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: service.id == "builtin.youtube" ? "play.rectangle" : service.id == "builtin.github" ? "chevron.left.forwardslash.chevron.right" : "globe")
                    .font(.system(size: 20)).foregroundStyle(Color(red: 0.20, green: 0.31, blue: 0.38))
                    .frame(width: 22).accessibilityHidden(true)
                Text(service.name).font(.system(size: 16, weight: .medium)).foregroundStyle(ink)
                    .lineLimit(2).help(service.name)
            }
            Text(service.url).font(.system(size: 11)).foregroundStyle(muted)
                .lineLimit(2).help(service.url).textSelection(.enabled)
        }
    }

    @ViewBuilder private func operation(_ service: ServiceEndpoint) -> some View {
        if service.isBuiltIn {
            Label(text("内置", "Built-in"), systemImage: "lock")
                .font(.system(size: 11)).foregroundStyle(muted)
        } else {
            Button(role: .destructive) { model.delete(service) } label: {
                Label(text("删除", "Delete"), systemImage: "trash").font(.system(size: 12))
            }
            .buttonStyle(.plain).foregroundStyle(Color(red: 0.67, green: 0.25, blue: 0.21))
            .accessibilityLabel(text("删除服务 \(service.name)", "Delete service \(service.name)"))
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(text("服务名称", "Service Name"))
                    TextField(text("例如：公司官网", "For example: Company"), text: $name)
                        .focused($nameFocused).accessibilityLabel(text("服务名称", "Service Name"))
                }.frame(width: 170)
                VStack(alignment: .leading, spacing: 6) {
                    Text(text("检测网址（http / https）", "Full HTTP / HTTPS URL"))
                    TextField("https://example.com/", text: $address)
                        .accessibilityLabel(text("检测网址", "Service URL"))
                }
                Button(text("取消", "Cancel"), action: closeEditor).buttonStyle(ServiceStatusButtonStyle(primary: false))
                Button(text("添加", "Add"), action: add).buttonStyle(ServiceStatusButtonStyle(primary: true))
                    .disabled(!validInput)
            }
            .font(.system(size: 12)).foregroundStyle(muted).textFieldStyle(.roundedBorder)
            .onSubmit { if validInput { add() } }
            Text(addError ?? text("输入名称与完整网址，添加后可在此列表检测。", "Enter a name and full URL, then check the service in this list."))
                .font(.system(size: 11)).foregroundStyle(addError == nil ? muted : .red)
        }
        .padding(20).frame(height: addError == nil ? 117 : 145)
        .background(Color(red: 0.95, green: 0.974, blue: 0.988))
        .onAppear { nameFocused = true }
    }

    private var validInput: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.count <= 80 && ServiceEndpoint.validatedURL(address) != nil
    }

    private func add() {
        do { try model.add(name: name, url: address); closeEditor() }
        catch { addError = text("未能添加，请检查名称、完整网址和本地文件权限。", "Could not add the service. Check its name, full URL, and local file permissions.") }
    }

    private func closeEditor() { isAdding = false; name = ""; address = ""; addError = nil }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(model.isRunning ? text("取消检测会停止尚未完成的请求", "Cancel stops unfinished requests") : text("有响应不一定代表服务可正常使用", "A response does not guarantee full service availability"))
                .font(.system(size: 13, weight: .medium)).foregroundStyle(ink)
            Text(model.isRunning
                 ? text("已完成结果会保留，未完成的检测显示为「已取消」，稍后可再次检测全部。", "Completed results are kept. Unfinished checks show Canceled and can be checked again.")
                 : text("HTTP 403 / 429 单独显示为「访问受限」。检测不代表登录、地区解锁或具体功能可用。", "HTTP 403 / 429 show Access Restricted. Checks do not establish login, region access, or feature availability."))
                .font(.system(size: 12)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
        }.padding(.top, 2)
    }
}

private struct ServiceStatusMeasurementView: View {
    let result: ServiceProbeResult
    let kind: ServiceProbeKind
    let chinese: Bool
    private func text(_ zh: String, _ en: String) -> String { chinese ? zh : en }
    private let muted = Color(red: 0.32, green: 0.42, blue: 0.49)

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                if result.state == .checking {
                    ProgressView().controlSize(.small).scaleEffect(0.7).frame(width: 8, height: 8)
                } else { Circle().fill(statusColor).frame(width: 6, height: 6) }
                Text(result.isStale ? text("待重新检测", "Check Again") : statusTitle)
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(statusColor).lineLimit(1)
                Spacer(minLength: 2)
                Text(elapsedText).font(.system(size: 12)).monospacedDigit().foregroundStyle(muted).fixedSize()
            }
            Text(routeText).font(.system(size: 12))
                .foregroundStyle(result.isStale ? muted : Color(red: 0.13, green: 0.38, blue: 0.56))
                .lineLimit(2).help(routeText)
            Text(detailText).font(.system(size: 11)).foregroundStyle(muted)
                .lineLimit(2).help(detailText).textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
    }

    private var elapsedText: String {
        guard let duration = result.elapsed, !result.isStale || result.checkedAt != nil else { return "—" }
        return duration >= 1 ? String(format: "%.1f s", duration) : "\(Int((duration * 1000).rounded())) ms"
    }

    private var statusTitle: String {
        switch result.state {
        case .pending: text("待检测", "Not Checked")
        case .checking: text("检测中", "Checking")
        case .reachable: text("可达", "Reachable")
        case .restricted: text("访问受限", "Restricted")
        case .httpError: text("HTTP 异常", "HTTP Error")
        case .timedOut: text("超时", "Timed Out")
        case .connectionFailed: text("连接失败", "Connection Failed")
        case .tlsFailed: text("TLS 失败", "TLS Failed")
        case .cancelled: text("已取消", "Canceled")
        case .unavailable: text("无法检测", "Unavailable")
        }
    }

    private var statusColor: Color {
        if result.isStale { return Color(red: 0.57, green: 0.36, blue: 0.15) }
        switch result.state {
        case .reachable: return Color(red: 0.09, green: 0.42, blue: 0.29)
        case .restricted, .httpError: return Color(red: 0.57, green: 0.36, blue: 0.15)
        case .timedOut, .connectionFailed, .tlsFailed: return Color(red: 0.70, green: 0.26, blue: 0.21)
        default: return muted
        }
    }

    private var routeText: String {
        let prefix = result.isStale ? text("上次：", "Previous: ") : ""
        if let route = result.routeDescription { return prefix + route + (route == "DIRECT" ? text(" · 直连", " · Direct") : "") }
        switch result.state {
        case .pending, .checking, .cancelled:
            return kind == .direct ? text("DIRECT · 直连对照", "DIRECT · Comparison") : text("检测后显示实际线路", "Actual route appears after checking")
        default:
            return prefix + text("线路无法确认", "Route Unconfirmed")
        }
    }

    private var detailText: String {
        var parts: [String] = []
        if result.isStale { parts.append(text("上次：\(statusTitle)", "Previous: \(statusTitle)")) }
        if let code = result.statusCode { parts.append("HTTP \(code)") }
        if let rule = result.rule, !rule.isEmpty { parts.append(rule) }
        if let detail = result.detail, !detail.isEmpty {
            let translations = detail.components(separatedBy: " / ")
            parts.append(translations.count == 2 ? translations[chinese ? 0 : 1] : detail)
        }
        if !parts.isEmpty { return parts.joined(separator: " · ") }
        switch result.state {
        case .pending, .checking:
            return kind == .current ? text("按当前模式与规则发起请求", "Uses the current mode and rules") : text("与当前线路使用同一完整网址", "Uses the same full URL")
        case .cancelled: return text("请求已停止，可再次检测全部", "Request stopped; check all to retry")
        case .timedOut: return text("连接超时，未收到响应", "Timed out without a response")
        default: return text("未收到 HTTP 响应", "No HTTP response received")
        }
    }
}

private struct ServiceStatusButtonStyle: ButtonStyle {
    let primary: Bool
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13))
            .foregroundStyle(primary ? .white : Color(red: 0.13, green: 0.38, blue: 0.56))
            .padding(.horizontal, 13).frame(height: 34)
            .background(primary ? Color(red: 0.15, green: 0.38, blue: 0.55) : Color(red: 0.90, green: 0.935, blue: 0.958),
                        in: RoundedRectangle(cornerRadius: 7))
            .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }
}
