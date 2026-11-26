import SwiftUI

private struct RoutingRuleChoice: Identifiable, Sendable {
    let selector: String
    let rule: String
    let summary: String
    let targetLabel: String
    let isAssignable: Bool
    let searchableRule: String

    var id: String { selector }

    static func summary(for rule: String) -> String {
        let parts = rule.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return rule }
        return "\(parts[0]) · \(parts[1])"
    }

    private static func policyLabel(_ name: String) -> String {
        switch name {
        case "DIRECT": "DIRECT · 直连"
        case "REJECT": "REJECT · 拒绝"
        default: name
        }
    }

    init(rule: String, selector: String, originalTarget: String?, assignedTarget: String?) {
        self.selector = selector
        self.rule = rule
        summary = Self.summary(for: rule)
        targetLabel = (assignedTarget ?? originalTarget).map(Self.policyLabel) ?? "—"
        isAssignable = originalTarget != nil
        searchableRule = "\(rule) \(targetLabel)".lowercased()
    }

    @concurrent
    static func matching(_ choices: [Self], query: String) async throws -> [Self] {
        try choices.filter { choice in
            try Task.checkCancellation()
            return choice.searchableRule.contains(query)
        }
    }
}

private struct RoutingRulePreview: Sendable {
    var count = 0
    var examples: [String] = []

    mutating func append(_ rule: String) {
        count += 1
        if examples.count < 4, !examples.contains(rule) { examples.append(rule) }
    }
}

private struct RoutingGroupsSnapshot: Sendable {
    let id = UUID()
    let groups: [CustomRoutingGroup]
    let existingGroups: [ConfigRuleMerger.ProxyGroupDefinition]
    let availableRoutes: Set<String>
    let sortedRoutes: [String]
    let choices: [RoutingRuleChoice]
    let rulesByTarget: [String: RoutingRulePreview]
    let missingRuleCounts: [UUID: Int]

    @concurrent
    static func load(source: URL, changes: [CustomRuleChange], store: CustomRoutingGroupStore) async throws -> Self {
        let groups = try store.groups(for: source.lastPathComponent)
        let configuration = try ConfigRuleMerger().routingConfiguration(in: Data(contentsOf: source), changes: changes)
        let availableRoutes = configuration.proxyNames.union(configuration.proxyGroups.map(\.name)).union(["DIRECT", "REJECT"])
        var assignedTargets: [String: String] = [:]
        for group in groups {
            for selector in group.ruleSelectors where assignedTargets[selector] == nil {
                assignedTargets[selector] = group.name
            }
        }

        var selectors = Set<String>()
        var choices: [RoutingRuleChoice] = []
        var rulesByTarget: [String: RoutingRulePreview] = [:]
        for rule in configuration.rules {
            try Task.checkCancellation()
            let selector = RuleRoute.selector(for: rule)
            let originalTarget = RuleRoute.target(in: rule)
            let assignedTarget = assignedTargets[selector]
            if let target = assignedTarget ?? originalTarget {
                rulesByTarget[target, default: RoutingRulePreview()].append(rule)
            }
            if selectors.insert(selector).inserted {
                choices.append(RoutingRuleChoice(rule: rule, selector: selector,
                                                 originalTarget: originalTarget, assignedTarget: assignedTarget))
            }
        }
        let missingRuleCounts = Dictionary(uniqueKeysWithValues: groups.map { group in
            (group.id, group.ruleSelectors.count(where: { !selectors.contains($0) }))
        })
        return Self(groups: groups, existingGroups: configuration.proxyGroups, availableRoutes: availableRoutes,
                    sortedRoutes: availableRoutes.sorted(), choices: choices, rulesByTarget: rulesByTarget,
                    missingRuleCounts: missingRuleCounts)
    }
}

struct DashboardRoutingGroupsView: View {
    @ObservedObject var appViewModel: AppViewModel
    let configurationName: String

    private struct LoadRequest: Equatable {
        var source: URL?
        var effectiveFileName: String?
        var updatedAt: Date?
        var selectedConfigName: String
        var isRemoteTarget: Bool
        var revision: Int
    }

    private enum GroupID: Hashable {
        case existing(String)
        case custom(UUID)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var snapshot: RoutingGroupsSnapshot?
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var revision = 0
    @State private var loadError: String?
    @State private var editorError: String?
    @State private var isEditing = false
    @State private var editingID: UUID?
    @State private var draftName = ""
    @State private var draftProxies: Set<String> = []
    @State private var routeSearch = ""
    @State private var draftRuleSelectors: Set<String> = []
    @State private var expandedGroups: Set<GroupID> = []

    private let ink = Color(red: 0.13, green: 0.20, blue: 0.25)
    private let muted = Color(red: 0.32, green: 0.42, blue: 0.49)
    private let accent = Color(red: 0.14, green: 0.37, blue: 0.55)
    private let warning = Color(red: 0.70, green: 0.28, blue: 0.18)
    private let surface = Color(red: 0.96, green: 0.97, blue: 0.975)

    private var baseName: String { configurationName }
    private var isSelectedConfiguration: Bool { appViewModel.selectedConfigName == baseName }
    private var effectiveRecord: EffectiveConfigRecord? {
        guard let record = appViewModel.dashboardEffectiveRecord, record.baseName == baseName else { return nil }
        return record
    }
    private var currentChanges: [CustomRuleChange] { effectiveRecord?.changes ?? [] }
    private var loadRequest: LoadRequest {
        LoadRequest(source: appViewModel.configService.availableConfigs.first { $0.lastPathComponent == baseName },
                    effectiveFileName: effectiveRecord?.fileName,
                    updatedAt: appViewModel.remoteConfigMenuState(for: baseName).updatedAt,
                    selectedConfigName: appViewModel.selectedConfigName, isRemoteTarget: appViewModel.isRemoteTarget,
                    revision: revision)
    }
    private var editingDisabled: Bool {
        isLoading || isSaving || appViewModel.dashboardConfigBusy || appViewModel.isRemoteTarget || loadError != nil
    }
    private var canSave: Bool {
        !editingDisabled && !draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !draftProxies.isEmpty
    }
    private var normalizedSearch: String {
        ruleSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    private var editorRequest: EditorRequest? {
        guard isEditing, let snapshot else { return nil }
        let query = normalizedSearch
        guard !query.isEmpty else { return nil }
        return EditorRequest(snapshotID: snapshot.id, query: query)
    }

    private struct EditorRequest: Equatable, Sendable {
        var snapshotID: UUID
        var query: String
    }

    private struct FilteredChoices: Sendable {
        let request: EditorRequest
        let values: [RoutingRuleChoice]
    }

    @State private var ruleSearch = ""
    @State private var filteredChoices: FilteredChoices?

    var body: some View {
        let request = loadRequest
        let search = editorRequest
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let loadError {
                        issue(loadError)
                    }
                    if let editorError {
                        issue(editorError).padding(.bottom, 18)
                    }
                    if let snapshot, loadError == nil {
                        if isEditing {
                            editor(snapshot, choices: editorChoices(for: snapshot, request: search))
                        } else {
                            groupOverview(snapshot)
                        }
                    } else if isLoading {
                        ProgressView("正在加载线路和规则…")
                            .frame(maxWidth: .infinity).padding(.vertical, 36)
                    }
                }
                .padding(22)
            }
        }
        .frame(minWidth: 760, idealWidth: 900, minHeight: 620, idealHeight: 760)
        .background(.white)
        .onChange(of: appViewModel.selectedConfigName) { _ in
            cancelEditing()
        }
        .task(id: request) { await loadConfiguration(request) }
        .task(id: search) { await updateFilteredChoices(for: search) }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("线路分组").font(.system(size: 18, weight: .semibold)).foregroundStyle(ink)
                Text(baseName).font(.system(size: 11)).foregroundStyle(muted).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if !isEditing {
                Button {
                    beginEditing(nil)
                } label: {
                    Label("新增分组", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .disabled(editingDisabled)
            }
            Button("关闭") { dismiss() }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
    }

    @ViewBuilder
    private func groupOverview(_ snapshot: RoutingGroupsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("实际线路分组").font(.system(size: 14, weight: .semibold)).foregroundStyle(ink)
            Text(isSelectedConfiguration
                ? "自建分组会写入当前配置；订阅更新后保留分组，并按最新可用线路检查缺失项。"
                : "此配置的分组会单独保存，并在应用该配置时合并；订阅更新后仍会保留并检查缺失线路。")
                .font(.system(size: 11)).foregroundStyle(muted)
        }
        .padding(.bottom, 16)

        if snapshot.groups.isEmpty && snapshot.existingGroups.isEmpty {
            emptyState("当前配置还没有线路分组。新建分组后，可选择线路并指定要统一走该组的规则。")
        } else {
            ForEach(snapshot.existingGroups, id: \.name) { group in
                existingGroupRow(group, snapshot: snapshot)
            }
            ForEach(snapshot.groups) { group in
                customGroupRow(group, snapshot: snapshot)
            }
        }

        VStack(alignment: .leading, spacing: 16) {
            Divider()
            Text("当前规则与目标线路").font(.system(size: 14, weight: .semibold)).foregroundStyle(ink)
        }
        .padding(.top, 12)
        .padding(.bottom, 10)

        if snapshot.choices.isEmpty {
            emptyState("当前配置没有可分配的规则。")
        } else {
            ForEach(snapshot.choices) { choice in
                ruleRow(choice)
                    .overlay(alignment: .bottom) { Divider() }
            }
        }
    }

    private func existingGroupRow(_ group: ConfigRuleMerger.ProxyGroupDefinition, snapshot: RoutingGroupsSnapshot) -> some View {
        groupRow(group.name, id: .existing(group.name)) {
            let rules = snapshot.rulesByTarget[group.name] ?? RoutingRulePreview()
            let missingRoutes = group.routes.filter { !snapshot.availableRoutes.contains($0) }
            Text(group.type).font(.system(size: 10, weight: .medium)).foregroundStyle(muted)
            Text(group.routes.isEmpty ? "未直接列出线路" : group.routes.joined(separator: "、"))
                .font(.system(size: 10)).foregroundStyle(ink).lineLimit(2).help(group.routes.joined(separator: ", "))
            if !group.providers.isEmpty {
                Text("节点提供者：\(group.providers.joined(separator: "、"))")
                    .font(.system(size: 9)).foregroundStyle(muted).lineLimit(1)
            }
            if !missingRoutes.isEmpty {
                warningMessage("组内线路缺失：\(missingRoutes.joined(separator: "、"))")
            }
            Text("\(rules.count) 条规则指向此组")
                .font(.system(size: 10)).foregroundStyle(muted)
            if rules.count == 0 {
                Text("暂未发现指向该组的规则。")
                    .font(.system(size: 10)).foregroundStyle(muted)
            } else {
                ruleSummaryList(rules.examples, count: rules.count)
            }
        }
    }

    private func customGroupRow(_ group: CustomRoutingGroup, snapshot: RoutingGroupsSnapshot) -> some View {
        let missingRules = snapshot.missingRuleCounts[group.id, default: 0]
        let hasWarning = missingRules > 0 || group.routeNames.contains { !snapshot.availableRoutes.contains($0) }
        return groupRow(group.name, id: .custom(group.id), showsWarning: hasWarning) {
            let missingRoutes = group.routeNames.filter { !snapshot.availableRoutes.contains($0) }
            let assignedRules = snapshot.rulesByTarget[group.name] ?? RoutingRulePreview()
            HStack(spacing: 10) {
                Text("\(group.routeNames.count) 条线路 · \(assignedRules.count) 条规则")
                    .font(.system(size: 10)).foregroundStyle(muted)
                Spacer()
                Button { beginEditing(group) } label: { Image(systemName: "pencil") }
                    .buttonStyle(.plain).help("编辑分组").accessibilityLabel("编辑分组")
                    .disabled(editingDisabled)
                Button { delete(group) } label: { Image(systemName: "trash") }
                    .buttonStyle(.plain).foregroundStyle(warning).help("删除分组").accessibilityLabel("删除分组")
                    .disabled(editingDisabled)
            }
            Text(group.routeNames.joined(separator: "、"))
                .font(.system(size: 10)).foregroundStyle(ink).lineLimit(2).help(group.routeNames.joined(separator: ", "))
            if !missingRoutes.isEmpty {
                warningMessage("线路缺失：\(missingRoutes.joined(separator: "、"))")
            }
            if missingRules > 0 {
                warningMessage("规则已不在当前配置中：\(missingRules) 条；若之后重新出现，分组关联仍会保留。")
            }
            if assignedRules.count == 0 {
                Text("尚未选择规则。")
                    .font(.system(size: 10)).foregroundStyle(muted)
            } else {
                ruleSummaryList(assignedRules.examples, count: assignedRules.count)
            }
        }
    }

    private func groupRow<Details: View>(
        _ name: String, id: GroupID, showsWarning: Bool = false, @ViewBuilder details: () -> Details
    ) -> some View {
        let isExpanded = expandedGroups.contains(id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                if isExpanded {
                    expandedGroups.remove(id)
                } else {
                    expandedGroups.insert(id)
                }
            } label: {
                HStack(spacing: 8) {
                    Text(name).font(.system(size: 13, weight: .semibold)).foregroundStyle(ink).lineLimit(1)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(muted)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "已展开" : "已折叠")
            .accessibilityHint(showsWarning ? "分组需要检查" : "")
            if isExpanded {
                VStack(alignment: .leading, spacing: 8, content: details)
                    .padding(.horizontal, 14).padding(.bottom, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(showsWarning ? Color(red: 1, green: 0.95, blue: 0.93) : surface, in: RoundedRectangle(cornerRadius: 8))
        .padding(.bottom, 6)
    }

    private func editor(_ snapshot: RoutingGroupsSnapshot, choices: [RoutingRuleChoice]?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(editingID == nil ? "新增实际线路分组" : "编辑实际线路分组")
                    .font(.system(size: 15, weight: .semibold)).foregroundStyle(ink)
                Spacer()
                Button("取消") { cancelEditing() }.buttonStyle(.bordered)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("分组名称").font(.system(size: 11, weight: .medium)).foregroundStyle(muted)
                TextField("例如：工作线路", text: $draftName).textFieldStyle(.roundedBorder)
            }
            routePicker(snapshot)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("分配规则").font(.system(size: 11, weight: .medium)).foregroundStyle(muted)
                    Spacer()
                    Text("选择后，这些规则统一走此分组")
                        .font(.system(size: 10)).foregroundStyle(muted)
                }
                if snapshot.choices.isEmpty {
                    emptyState("当前配置没有可分配的规则。")
                } else {
                    TextField("搜索规则或当前线路", text: $ruleSearch).textFieldStyle(.roundedBorder)
                    Group {
                        if let choices {
                            ScrollView {
                                LazyVStack(spacing: 0) {
                                    ForEach(choices) { choice in
                                        ruleSelectionRow(choice)
                                            .overlay(alignment: .bottom) { Divider().allowsHitTesting(false) }
                                    }
                                }
                            }
                        } else {
                            ProgressView("正在搜索规则…")
                                .controlSize(.small)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .frame(height: 230)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(muted.opacity(0.18)))
                    if choices?.isEmpty == true {
                        emptyState("没有匹配的规则。")
                    }
                    Text("相同匹配条件的重复规则会一起分配。")
                        .font(.system(size: 10)).foregroundStyle(muted)
                }
            }
            HStack {
                Spacer()
                Button("保存分组") { saveGroup() }
                    .buttonStyle(.borderedProminent).tint(accent).disabled(!canSave)
            }
        }
        .padding(18).background(surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func routePicker(_ snapshot: RoutingGroupsSnapshot) -> some View {
        let keyword = routeSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let missingRoutes = draftProxies.subtracting(snapshot.availableRoutes).sorted()
        let routes = keyword.isEmpty ? snapshot.sortedRoutes : snapshot.sortedRoutes.filter { $0.localizedCaseInsensitiveContains(keyword) }
        let missing = keyword.isEmpty ? missingRoutes : missingRoutes.filter { $0.localizedCaseInsensitiveContains(keyword) }

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("组内线路").font(.system(size: 11, weight: .medium)).foregroundStyle(muted)
                Spacer()
                Text("可选择节点、已有策略组或直连")
                    .font(.system(size: 10)).foregroundStyle(muted)
            }
            HStack(spacing: 10) {
                TextField("搜索线路名称，例如：经济", text: $routeSearch)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("搜索线路名称")
                if !routeSearch.isEmpty {
                    Button {
                        routeSearch = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(muted)
                    .help("清除线路搜索")
                    .accessibilityLabel("清除线路搜索")
                }
                Text("已选 \(draftProxies.count) 条")
                    .font(.system(size: 10)).foregroundStyle(muted)
            }
            if routes.isEmpty && missing.isEmpty {
                emptyState("没有匹配的线路。")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(routes, id: \.self) { route in
                        selectionButton(route, selected: draftProxies.contains(route)) {
                            toggle(route, in: &draftProxies)
                        }
                    }
                    ForEach(missing, id: \.self) { route in
                        selectionButton("\(route) · 缺失", selected: true, color: warning) {
                            draftProxies.remove(route)
                        }
                    }
                }
            }
        }
    }

    private func ruleSelectionRow(_ choice: RoutingRuleChoice) -> some View {
        let selected = draftRuleSelectors.contains(choice.selector)
        return Button {
            toggle(choice.selector, in: &draftRuleSelectors)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(selected ? accent : muted)
                VStack(alignment: .leading, spacing: 3) {
                    Text(choice.summary).font(.system(size: 11, weight: .medium)).foregroundStyle(ink)
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text("\(choice.targetLabel) · \(choice.rule)")
                        .font(.system(size: 9)).foregroundStyle(muted).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 9).padding(.vertical, 7).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!choice.isAssignable)
    }

    private func selectionButton(_ title: String, selected: Bool, color: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                Text(title).lineLimit(1)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(color ?? (selected ? accent : ink))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(.white, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
    }

    private func ruleRow(_ choice: RoutingRuleChoice) -> some View {
        HStack(spacing: 10) {
            Text(choice.summary)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1).help(choice.rule)
            Text(choice.targetLabel)
                .font(.system(size: 10, weight: .medium)).foregroundStyle(accent)
                .lineLimit(1).frame(maxWidth: 180, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private func ruleSummaryList(_ rules: [String], count: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(rules, id: \.self) { rule in
                Text("• \(RoutingRuleChoice.summary(for: rule))")
                    .font(.system(size: 10)).foregroundStyle(muted).lineLimit(1).help(rule)
            }
            if count > rules.count {
                Text("还有 \(count - rules.count) 条")
                    .font(.system(size: 9)).foregroundStyle(muted)
            }
        }
    }

    private func issue(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11)).foregroundStyle(warning)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12).background(Color(red: 1.0, green: 0.95, blue: 0.93), in: RoundedRectangle(cornerRadius: 9))
    }

    private func warningMessage(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 10, weight: .medium)).foregroundStyle(warning)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func emptyState(_ message: String) -> some View {
        Text(message).font(.system(size: 11)).foregroundStyle(muted)
            .frame(maxWidth: .infinity, alignment: .leading).padding(13)
            .background(surface, in: RoundedRectangle(cornerRadius: 9))
    }

    private func editorChoices(for snapshot: RoutingGroupsSnapshot, request: EditorRequest?) -> [RoutingRuleChoice]? {
        guard let request else { return snapshot.choices }
        guard let filteredChoices, filteredChoices.request == request else { return nil }
        return filteredChoices.values
    }

    private func updateFilteredChoices(for request: EditorRequest?) async {
        guard let request, let snapshot, snapshot.id == request.snapshotID else { return }
        do {
            let values = try await RoutingRuleChoice.matching(snapshot.choices, query: request.query)
            try Task.checkCancellation()
            guard editorRequest == request else { return }
            filteredChoices = FilteredChoices(request: request, values: values)
        } catch {
            return
        }
    }

    private func loadConfiguration(_ request: LoadRequest) async {
        guard !request.isRemoteTarget else {
            loadError = "配置管理仅适用于本地核心。"
            isLoading = false
            return
        }
        guard let source = request.source else {
            loadError = "当前基础配置不存在。"
            isLoading = false
            return
        }
        isLoading = true
        loadError = nil
        do {
            let next = try await RoutingGroupsSnapshot.load(
                source: source,
                changes: request.selectedConfigName == baseName && request.effectiveFileName != nil ? currentChanges : [],
                store: appViewModel.customRoutingGroupStore)
            try Task.checkCancellation()
            snapshot = next
            filteredChoices = nil
            isLoading = false
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
            isLoading = false
        }
    }

    private func beginEditing(_ group: CustomRoutingGroup?) {
        editingID = group?.id
        draftName = group?.name ?? ""
        draftProxies = Set(group?.routeNames ?? [])
        routeSearch = ""
        draftRuleSelectors = Set(group?.ruleSelectors ?? [])
        editorError = nil
        ruleSearch = ""
        filteredChoices = nil
        isEditing = true
    }

    private func cancelEditing() {
        isEditing = false
        editingID = nil
        draftName = ""
        draftProxies = []
        routeSearch = ""
        draftRuleSelectors = []
        editorError = nil
        ruleSearch = ""
        filteredChoices = nil
    }

    private func saveGroup() {
        editorError = nil
        let normalizedName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let snapshot else { return }
        guard !normalizedName.isEmpty else { editorError = "请输入分组名称。"; return }
        guard !draftProxies.isEmpty else { editorError = "至少选择一条线路。"; return }
        guard !snapshot.availableRoutes.contains(normalizedName) else { editorError = "该名称已被线路或内置策略使用。"; return }
        guard !snapshot.groups.contains(where: { $0.name == normalizedName && $0.id != editingID }) else {
            editorError = "已存在同名自建分组。"
            return
        }
        var nextGroups = snapshot.groups
        for index in nextGroups.indices where nextGroups[index].id != editingID {
            nextGroups[index].ruleSelectors.removeAll { draftRuleSelectors.contains($0) }
        }
        let updated = CustomRoutingGroup(id: editingID ?? UUID(), name: normalizedName,
                                         routeNames: draftProxies.sorted(), ruleSelectors: draftRuleSelectors.sorted())
        if let index = nextGroups.firstIndex(where: { $0.id == editingID }) {
            nextGroups[index] = updated
        } else {
            nextGroups.append(updated)
        }
        apply(nextGroups)
    }

    private func delete(_ group: CustomRoutingGroup) {
        guard let snapshot else { return }
        apply(snapshot.groups.filter { $0.id != group.id })
    }

    private func apply(_ nextGroups: [CustomRoutingGroup]) {
        guard !isSaving else { return }
        isSaving = true
        Task {
            do {
                if isSelectedConfiguration {
                    guard await appViewModel.applyDashboardConfiguration(baseName: baseName, changes: currentChanges,
                                                                          routingGroups: nextGroups) else {
                        throw NSError(domain: "DashboardRoutingGroups", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: appViewModel.dashboardConfigError ?? "无法应用分组配置。"])
                    }
                } else {
                    guard let source = appViewModel.configService.availableConfigs.first(where: { $0.lastPathComponent == baseName }) else {
                        throw CocoaError(.fileNoSuchFile)
                    }
                    let sourceData = try Data(contentsOf: source)
                    _ = try ConfigRuleMerger().merge(sourceData, changes: [], routingGroups: nextGroups)
                    try appViewModel.customRoutingGroupStore.save(nextGroups, for: baseName)
                }
                cancelEditing()
                revision += 1
                isSaving = false
            } catch {
                editorError = error.localizedDescription
                isSaving = false
            }
        }
    }

    private func toggle(_ value: String, in values: inout Set<String>) {
        if values.contains(value) { values.remove(value) }
        else { values.insert(value) }
    }
}
