import SwiftUI

private enum RuleMatchType: String, CaseIterable {
    case domain = "DOMAIN", suffix = "DOMAIN-SUFFIX", keyword = "DOMAIN-KEYWORD"
    case ip4 = "IP-CIDR", ip6 = "IP-CIDR6", geoip = "GEOIP", process = "PROCESS-NAME"

    func label(_ chinese: Bool) -> String {
        switch self {
        case .domain: return chinese ? "完整域名" : "Exact domain"
        case .suffix: return chinese ? "域名及其子域名" : "Domain and subdomains"
        case .keyword: return chinese ? "域名关键词" : "Domain keyword"
        case .ip4: return "IPv4 CIDR"
        case .ip6: return "IPv6 CIDR"
        case .geoip: return chinese ? "IP 地区代码" : "IP country code"
        case .process: return chinese ? "进程名称" : "Process name"
        }
    }
}

struct DashboardCustomRulesView: View {
    @ObservedObject var appViewModel: AppViewModel
    @Binding var request: DashboardCustomRuleRequest?
    @State private var operation: CustomRuleChange.Operation = .add
    @State private var type: RuleMatchType = .suffix
    @State private var match = ""
    @State private var policy = "DIRECT"
    @State private var original = ""
    @State private var raw = ""
    @State private var advanced = false
    @State private var editingIndex: Int?
    @State private var editingOriginal: CustomRuleChange?
    @State private var baseRules: [String] = []
    @State private var ruleSearch = ""
    @State private var choosingBaseRule = false
    @State private var choosingType = false
    @State private var choosingPolicy = false
    @State private var policies: [String] = ["DIRECT", "REJECT"]
    @State private var localError: String?

    private let ink = Color(red: 0.13, green: 0.20, blue: 0.25)
    private let muted = Color(red: 0.32, green: 0.42, blue: 0.49)
    private let blue = Color(red: 0.14, green: 0.37, blue: 0.55)
    private let surface = Color(red: 0.96, green: 0.97, blue: 0.975)
    private var chinese: Bool { appViewModel.uiLanguage == .zhHans }
    private func text(_ zh: String, _ en: String) -> String { chinese ? zh : en }
    private var changes: [CustomRuleChange] { appViewModel.dashboardEffectiveRecord?.changes ?? [] }
    private var disabled: Bool { appViewModel.dashboardConfigBusy || appViewModel.isRemoteTarget }
    private var generated: String { "\(type.rawValue),\(match.trimmingCharacters(in: .whitespacesAndNewlines)),\(policy)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let error = localError ?? appViewModel.dashboardConfigError {
                errorMessage(error)
            }
            ZStack(alignment: .topTrailing) {
                listPanel.frame(maxHeight: .infinity, alignment: .top)
                if request != nil {
                    Color.clear.contentShape(Rectangle()).onTapGesture(perform: closeEditor)
                    ruleEditor
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color(red: 0.86, green: 0.89, blue: 0.91), lineWidth: 1))
                        .compositingGroup()
                        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                }
            }
        }
        .onAppear(perform: loadOptions)
        .onChange(of: request) { newRequest in
            guard let newRequest else { reset(); return }
            if editingIndex == nil { reset() }
            operation = newRequest.operation
            localError = nil
        }
        .onChange(of: appViewModel.selectedConfigName) { _ in closeEditor(); loadOptions() }
        .onChange(of: appViewModel.isRemoteTarget) { _ in closeEditor(); loadOptions() }
        .onExitCommand { if request != nil { closeEditor() } }
    }

    private func errorMessage(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(text("未能应用规则", "Unable to apply rule"), systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
            Text(text("变更未完成，请检查详情后重试。", "The change did not complete. Check the details and try again."))
            DisclosureGroup(text("查看详情", "Details")) { Text(error).textSelection(.enabled) }
        }
        .font(.system(size: 12)).foregroundStyle(Color(red: 0.55, green: 0.29, blue: 0.12))
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.99, green: 0.95, blue: 0.91), in: RoundedRectangle(cornerRadius: 12))
    }

    private var ruleEditor: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(editingIndex == nil ? operationLabel(operation) : text("编辑规则", "Edit rule"))
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(ink)
                    Text(text("规则条件", "Rule conditions"))
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(muted)
                }
                Spacer()
                Button { closeEditor() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(muted)
                        .frame(width: 24, height: 24).background(Color.black.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain).help(text("关闭", "Close"))
            }

            if operation != .add {
                fieldLabel(text("基础配置中的规则", "Rule in base configuration"))
                Button {
                    ruleSearch = ""
                    choosingBaseRule = true
                } label: {
                    menuLabel(original.isEmpty ? text("选择基础配置中的规则…", "Select a base rule…") : original)
                }.buttonStyle(.plain).disabled(baseRules.isEmpty)
                    .popover(isPresented: $choosingBaseRule, arrowEdge: .bottom) { baseRulePicker }
            }
            if operation != .delete {
                if advanced {
                    fieldLabel(text("原始规则", "Raw rule"))
                    TextField("DOMAIN-SUFFIX,example.com,DIRECT", text: $raw).textFieldStyle(.roundedBorder)
                } else {
                    fieldLabel(text("匹配类型", "Match type"))
                    Button { choosingType = true } label: { menuLabel(type.label(chinese)) }
                        .buttonStyle(.plain).popover(isPresented: $choosingType) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(RuleMatchType.allCases, id: \.self) { item in
                                    Button(item.label(chinese)) { type = item; choosingType = false }
                                        .buttonStyle(RuleOptionStyle())
                                }
                            }.padding(6).frame(width: 240)
                        }
                    fieldLabel(text("匹配内容", "Match value"))
                    TextField(type == .ip4 ? "192.0.2.0/24" : type == .ip6 ? "2001:db8::/32" : "example.com", text: $match)
                        .textFieldStyle(.roundedBorder)
                    fieldLabel(text("处理方式", "Policy"))
                    Button { choosingPolicy = true } label: { menuLabel(policyLabel(policy)) }
                        .buttonStyle(.plain).popover(isPresented: $choosingPolicy) {
                            ScrollView {
                                LazyVStack(alignment: .leading, spacing: 0) {
                                    ForEach(policies, id: \.self) { name in
                                        Button(policyLabel(name)) { policy = name; choosingPolicy = false }
                                            .buttonStyle(RuleOptionStyle())
                                    }
                                }
                            }.frame(width: 240, height: min(CGFloat(policies.count * 30 + 12), 260)).padding(6)
                        }
                }
            }
            Text(previewText)
                .font(.system(size: 11)).foregroundStyle(Color(red: 0.11, green: 0.48, blue: 0.32))
                .textSelection(.enabled).lineLimit(2)

            if operation != .delete {
                Button(advanced ? text("退出高级模式", "Exit advanced mode") : text("高级模式：编辑原始规则", "Advanced: edit raw rule")) {
                    if advanced {
                        let parts = raw.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
                        guard parts.count == 3, let parsed = RuleMatchType(rawValue: parts[0]) else {
                            localError = text("此原始规则无法用简单条件表示，请继续使用高级模式。", "This rule cannot be represented in the simple editor.")
                            return
                        }
                        type = parsed; match = parts[1]; policy = parts[2]
                        if !policies.contains(policy) { policies.append(policy) }
                    } else { raw = generated }
                    localError = nil
                    advanced.toggle()
                }.buttonStyle(RuleLinkStyle())
            }

            if let error = localError {
                Text(error).font(.system(size: 11)).foregroundStyle(Color(red: 0.65, green: 0.28, blue: 0.20))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button(text("取消", "Cancel"), action: closeEditor).buttonStyle(RuleLinkStyle())
                Spacer()
                Button(operation == .delete ? text("删除规则", "Delete rule") : editingIndex == nil ? text("保存规则", "Save rule") : text("保存修改", "Save changes"), action: save)
                    .buttonStyle(RulePrimaryStyle()).disabled(disabled)
            }.padding(.top, 2)
        }
        .padding(18)
        .frame(width: 354, alignment: .leading)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var previewText: String {
        if operation == .delete {
            return original.isEmpty ? text("选择基础规则后预览删除项", "Select a base rule to preview") : "\(text("将从基础配置移除", "Will remove from base")): \(original)"
        }
        if advanced { return raw.isEmpty ? text("输入原始规则", "Enter a raw rule") : "\(text("将生成", "Will generate")): \(raw)" }
        return match.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? text("输入匹配内容后生成规则", "Enter a match value to generate a rule")
            : "\(text("将生成", "Will generate")): \(generated)"
    }

    private var listPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(text("已添加规则", "Custom rules")).font(.system(size: 15, weight: .semibold))
                Spacer()
                Text("\(changes.count) \(text("条 · 按优先级从上到下匹配", "· matched from top to bottom"))")
                    .font(.system(size: 11)).foregroundStyle(muted)
            }
            if changes.isEmpty {
                Text(text("暂无自定义规则", "No custom rules yet")).font(.system(size: 12)).foregroundStyle(muted)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 20)
            }
            ForEach(Array(changes.enumerated()), id: \.offset) { index, change in ruleRow(change, index: index) }
            Text(text("规则会先经过校验，再合并到当前基础配置。", "Rules are validated before merging into the base configuration."))
                .font(.system(size: 10)).foregroundStyle(muted)
        }.padding(16).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func ruleRow(_ change: CustomRuleChange, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                Text(operationShort(change.operation)).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(change.operation == .add ? Color(red: 0.11, green: 0.48, blue: 0.32) : change.operation == .replace ? Color(red: 0.65, green: 0.37, blue: 0.08) : muted)
                    .frame(width: 40, alignment: .leading)
                Text(summary(change)).font(.system(size: 12, weight: .medium)).lineLimit(2)
                Spacer(minLength: 0)
            }
            HStack(alignment: .top, spacing: 8) {
                Text(change.operation == .delete ? text("从基础配置移除", "Removed from base") : change.value)
                    .font(.system(size: 10)).foregroundStyle(muted).lineLimit(2).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(text("编辑", "Edit")) { edit(change, index: index) }.buttonStyle(RuleLinkStyle()).disabled(disabled)
                Button(change.operation == .delete ? text("撤销删除", "Undo") : text("删除", "Remove")) { remove(index: index) }
                    .buttonStyle(RuleLinkStyle()).disabled(disabled)
            }
        }.padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color(red: 0.86, green: 0.89, blue: 0.91), lineWidth: 1))
    }

    private func fieldLabel(_ label: String) -> some View {
        Text(label).font(.system(size: 11)).foregroundStyle(muted).padding(.bottom, -9)
    }

    private func menuLabel(_ value: String) -> some View {
        HStack {
            Text(value).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 4)
            Image(systemName: "chevron.down").font(.system(size: 10))
        }
        .font(.system(size: 12)).foregroundStyle(ink).padding(.horizontal, 12)
        .frame(maxWidth: .infinity).frame(height: 38)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color(red: 0.84, green: 0.88, blue: 0.90), lineWidth: 1))
        .contentShape(Rectangle())
    }

    private var baseRulePicker: some View {
        let filtered = baseRules.filter { ruleSearch.isEmpty || $0.localizedCaseInsensitiveContains(ruleSearch) }
        return VStack(alignment: .leading, spacing: 8) {
            TextField(text("搜索基础规则", "Search base rules"), text: $ruleSearch)
                .textFieldStyle(.roundedBorder)
            if filtered.isEmpty {
                Text(text("没有匹配的规则", "No matching rules")).font(.caption).foregroundStyle(muted)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(filtered.prefix(200).enumerated()), id: \.offset) { _, rule in
                            Button {
                                original = rule
                                choosingBaseRule = false
                            } label: {
                                Text(rule).font(.system(size: 11)).lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(8).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Divider()
                        }
                    }
                }.frame(height: 250)
                if filtered.count > 200 {
                    Text(text("仅显示前 200 条，请搜索以缩小范围。", "Showing the first 200. Search to narrow results."))
                        .font(.system(size: 10)).foregroundStyle(muted)
                }
            }
        }.padding(12).frame(width: 380)
    }

    private func operationLabel(_ op: CustomRuleChange.Operation) -> String {
        switch op { case .add: return text("新增规则", "Add"); case .replace: return text("替换规则", "Replace"); case .delete: return text("删除规则", "Delete") }
    }
    private func operationShort(_ op: CustomRuleChange.Operation) -> String {
        switch op { case .add: return text("新增", "Add"); case .replace: return text("替换", "Replace"); case .delete: return text("删除", "Delete") }
    }
    private func policyLabel(_ name: String) -> String {
        if name == "DIRECT" { return text("DIRECT · 直连", "DIRECT · Direct") }
        if name == "REJECT" { return text("REJECT · 拒绝", "REJECT · Reject") }
        return name
    }
    private func summary(_ change: CustomRuleChange) -> String {
        let rule = change.operation == .delete ? change.original : change.value
        let parts = rule.split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return rule }
        let value = String(parts[1])
        if parts[0] == "DOMAIN-SUFFIX" { return value + text(" 及子域名", " and subdomains") }
        return change.operation == .delete ? text("旧规则 · ", "Base rule · ") + value : value
    }
    private func loadOptions() {
        guard !appViewModel.isRemoteTarget else { baseRules = []; return }
        do {
            let snapshot = try appViewModel.agentRuleSnapshot()
            baseRules = snapshot.baseRules
            policies = snapshot.policies
            if !policies.contains(policy) { policies.append(policy) }
        } catch { baseRules = []; localError = error.localizedDescription }
    }
    private func reset() {
        editingIndex = nil; editingOriginal = nil; match = ""; original = ""; raw = ""; type = .suffix; policy = "DIRECT"; advanced = false
        localError = nil; appViewModel.dashboardConfigError = nil
    }
    private func edit(_ change: CustomRuleChange, index: Int) {
        reset(); editingIndex = index; editingOriginal = change; operation = change.operation; original = change.original
        let parts = change.value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 3, let parsed = RuleMatchType(rawValue: parts[0]) {
            type = parsed; match = parts[1]; policy = parts[2]
            if !policies.contains(policy) { policies.append(policy) }
        } else { advanced = true; raw = change.value }
        request = DashboardCustomRuleRequest(operation: change.operation)
    }

    private func closeEditor() {
        request = nil
        reset()
    }
    private func save() {
        localError = nil
        guard operation == .add || !original.isEmpty else { localError = text("请选择基础规则。", "Select a base rule."); return }
        let nextValue = advanced ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : generated
        guard operation == .delete || (advanced ? !nextValue.isEmpty : !match.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !match.contains(",")) else {
            localError = text("请输入有效的匹配内容。", "Enter a valid match value."); return
        }
        var next = changes
        if let index = editingIndex, !next.indices.contains(index) || next[index] != editingOriginal {
            localError = text("规则列表已变更，请重新编辑。", "The rule list changed. Edit the rule again.")
            return
        }
        let change = CustomRuleChange(id: editingIndex.map { next[$0].id } ?? UUID(), operation: operation, original: operation == .add ? "" : original, value: operation == .delete ? "" : nextValue)
        if let index = editingIndex { next[index] = change } else { next.append(change) }
        Task { if await appViewModel.applyDashboardConfiguration(baseName: appViewModel.selectedConfigName, changes: next) { closeEditor(); loadOptions() } }
    }
    private func remove(index: Int) {
        var next = changes
        guard next.indices.contains(index) else { return }
        next.remove(at: index)
        Task {
            if await appViewModel.applyDashboardConfiguration(baseName: appViewModel.selectedConfigName, changes: next) {
                closeEditor()
                loadOptions()
            }
        }
    }
}

private struct RuleLinkStyle: ButtonStyle {
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color(red: 0.14, green: 0.37, blue: 0.55))
            .padding(.horizontal, 3).padding(.vertical, 4)
            .background(hovered ? Color.black.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .opacity(configuration.isPressed ? 0.6 : 1).contentShape(Rectangle()).onHover { hovered = $0 }
    }
}

private struct RulePrimaryStyle: ButtonStyle {
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
            .padding(.horizontal, 18).frame(height: 34)
            .background(Color(red: 0.15, green: 0.35, blue: 0.49).opacity(hovered ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 9))
            .opacity(configuration.isPressed ? 0.6 : 1).onHover { hovered = $0 }
    }
}

private struct RuleOptionStyle: ButtonStyle {
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12)).lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).frame(height: 30)
            .background(hovered ? Color.black.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle()).onHover { hovered = $0 }
    }
}
