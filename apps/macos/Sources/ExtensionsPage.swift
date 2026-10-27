import SwiftUI

// ExtensionsPage.swift - 扩展: installed plugins and the official catalog. Plugins are data
// (styles); before anything is installed the user sees where its data goes.

private enum ExtensionsTab: Hashable { case installed, market }

struct ExtensionsPage: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var plugins: PluginController
    @State private var tab: ExtensionsTab = .installed

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: L10n.text("扩展"), subtitle: "") {
                Button(L10n.text("导入插件文件…")) { plugins.chooseFile() }.buttonStyle(SecondaryButtonStyle())
            }
            HStack {
                ChipPicker(options: [(ExtensionsTab.installed, L10n.text("已安装")), (.market, L10n.text("插件市场"))], selection: $tab)
                Spacer()
                if let message = plugins.message {
                    Text(message).font(.system(size: 12)).foregroundColor(Theme.warning).lineLimit(2)
                }
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch tab {
                    case .installed: installed
                    case .market: MarketList(plugins: plugins)
                    }
                }
                .padding(.horizontal, 36)
                .padding(.bottom, 36)
            }
        }
        .onAppear { plugins.refresh() }
        .sheet(item: $plugins.pending) { pending in
            InstallSheet(pending: pending, cancel: { plugins.pending = nil }, confirm: { plugins.confirm(enable: $0) })
        }
    }

    @ViewBuilder private var installed: some View {
        if plugins.state.plugins.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "puzzlepiece.extension").font(.system(size: 28)).foregroundColor(Theme.tertiary)
                Text(L10n.text("没有插件")).foregroundColor(Theme.secondary)
                HStack(spacing: 8) {
                    Button(L10n.text("打开插件市场")) { tab = .market }.buttonStyle(PrimaryButtonStyle())
                    Button(L10n.text("导入插件文件…")) { plugins.chooseFile() }.buttonStyle(SecondaryButtonStyle())
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 60)
        } else {
            ForEach(plugins.state.plugins) { plugin in
                InstalledCard(plugin: plugin, selectedStyle: plugins.state.style,
                              setEnabled: { plugins.setEnabled(plugin.id, $0) },
                              selectStyle: { plugins.selectStyle($0 ? plugin.id : nil) },
                              remove: { plugins.remove(plugin.id) })
            }
            if let problems = plugins.state.problems, !problems.isEmpty {
                Text(L10n.text("{0} 个插件文件已损坏并停用：{1}", problems.count, problems.joined(separator: "、")))
                    .font(.system(size: 12)).foregroundColor(Theme.warning)
            }
        }
    }
}

/// Type, version, author and source on one line.
private struct PluginMeta: View {
    let plugin: PluginSummary
    var body: some View {
        HStack(spacing: 8) {
            Badge(text: L10n.text("风格"), tint: plugin.isStyle ? Theme.style : Theme.accent)
            Text("v" + plugin.version + " · " + plugin.author).font(.system(size: 11.5)).foregroundColor(Theme.secondary)
            if let source = plugin.source {
                Text(source == "bundled" ? L10n.text("随应用提供") : (source == "catalog" ? L10n.text("官方目录") : L10n.text("本地导入，未审核。")))
                    .font(.system(size: 11.5)).foregroundColor(source == "file" ? Theme.warning : Theme.secondary)
            }
        }
    }
}

private struct InstalledCard: View {
    let plugin: PluginSummary
    let selectedStyle: String?
    let setEnabled: (Bool) -> Void
    let selectStyle: (Bool) -> Void
    let remove: () -> Void

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(plugin.title).font(.system(size: 14, weight: .semibold))
                    PluginMeta(plugin: plugin)
                    Text(plugin.summary).font(.system(size: 12.5)).foregroundColor(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !plugin.isStyle, let count = plugin.termCount {
                        Text(L10n.text("{0} 个词", count)).font(.system(size: 11.5)).foregroundColor(Theme.tertiary)
                    }
                    if let count = plugin.aliasCount, count > 0 {
                        Text(L10n.text("{0} 条读音提示", count)).font(.system(size: 11.5)).foregroundColor(Theme.tertiary)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    if plugin.isStyle {
                        let using = selectedStyle == plugin.id
                        Button(using ? L10n.text("停用") : L10n.text("使用此风格")) { selectStyle(!using) }
                            .buttonStyle(SecondaryButtonStyle())
                    } else {
                        Toggle("", isOn: Binding(get: { plugin.enabled == true }, set: setEnabled))
                            .toggleStyle(StateSwitchStyle()).labelsHidden()
                    }
                    IconButton(symbol: "trash", help: L10n.text("卸载"), role: .destructive, action: remove)
                }
            }
        }
    }
}

struct MarketList: View {
    @ObservedObject var plugins: PluginController
    /// Off only in renders, which show a given catalog.
    var loadOnAppear = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                if plugins.catalogLoading {
                    ProgressView().controlSize(.small)
                    Text(L10n.text("正在读取插件目录…")).font(.system(size: 12)).foregroundColor(Theme.secondary)
                } else if let catalog = plugins.catalog, let time = catalog.fetchedAt {
                    Text((catalog.ok ? L10n.text("目录更新于 ") : L10n.text("离线。目录来自：")) + Self.time(time)
                         + (catalog.mirrored == true ? " · " + L10n.text("来自镜像") : ""))
                        .font(.system(size: 12)).foregroundColor(Theme.secondary)
                }
                Spacer()
                Button(L10n.text("刷新")) { plugins.openMarket() }.buttonStyle(SecondaryButtonStyle()).disabled(plugins.catalogLoading)
            }
            if let catalog = plugins.catalog {
                if catalog.plugins.isEmpty {
                    Text(L10n.text("目录里没有插件")).foregroundColor(Theme.secondary).padding(.top, 40).frame(maxWidth: .infinity)
                }
                ForEach(catalog.plugins) { plugin in
                    Card {
                        HStack(alignment: .top, spacing: 14) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(plugin.title).font(.system(size: 14, weight: .semibold))
                                PluginMeta(plugin: plugin)
                                Text(plugin.summary).font(.system(size: 12.5)).foregroundColor(Theme.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            marketButton(plugin)
                        }
                    }
                }
            }
        }
        // Each time the market tab is opened: one catalog read, nothing in the background.
        .onAppear { if loadOnAppear { plugins.openMarket() } }
    }

    @ViewBuilder private func marketButton(_ plugin: PluginSummary) -> some View {
        if let installed = plugin.installedVersion {
            if installed == plugin.version {
                Text(L10n.text("已安装")).font(.system(size: 12.5)).foregroundColor(Theme.secondary)
            } else {
                Button(L10n.text("更新到 {0}", plugin.version)) { plugins.askToInstall(plugin) }.buttonStyle(PrimaryButtonStyle())
            }
        } else {
            Button(L10n.text("安装")) { plugins.askToInstall(plugin) }.buttonStyle(PrimaryButtonStyle())
        }
    }

    static func time(_ iso: String) -> String {
        guard let date = ISO8601DateFormatter().date(from: iso) else { return iso }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// What a plugin is, what it contains and where its data goes, before it is installed.
struct InstallSheet: View {
    let pending: PendingPlugin
    let cancel: () -> Void
    let confirm: (Bool) -> Void

    private var plugin: PluginSummary { pending.summary }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(pending.installedVersion == nil ? L10n.text("安装「{0}」？", plugin.title) : L10n.text("把「{0}」更新到 {1}？", plugin.title, plugin.version))
                .font(.system(size: 17, weight: .bold))
            Text(plugin.summary).font(.system(size: 13)).foregroundColor(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            Text("v" + plugin.version + " · " + plugin.author + " · " + plugin.license).font(.system(size: 12)).foregroundColor(Theme.secondary)
            Label(!pending.fromCatalog ? L10n.text("来自本地文件，未审核。只安装你信任的人提供的插件。")
                  : pending.mirrored ? L10n.text("来自 TypeLeast 官方目录（镜像），已审核。") : L10n.text("来自 TypeLeast 官方目录，已审核。"),
                  systemImage: pending.fromCatalog ? "checkmark.seal" : "exclamationmark.triangle")
                .font(.system(size: 12.5)).foregroundColor(pending.fromCatalog ? Theme.ink : Theme.warning)
            if plugin.isStyle {
                Text(L10n.text("附加的说明：")).font(.system(size: 12.5, weight: .semibold))
                ScrollView {
                    Text(plugin.instructions ?? "").font(.system(size: 12.5)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 120)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.card))
            } else {
                Text(L10n.text("共 {0} 个词，例如：", plugin.termCount ?? 0)).font(.system(size: 12.5, weight: .semibold))
                Text((plugin.termsPreview ?? []).prefix(12).joined(separator: "、")).font(.system(size: 12.5)).foregroundColor(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let aliases = plugin.aliasesPreview, !aliases.isEmpty {
                    Text(L10n.text("仅在语境明确时使用以下读音提示：")).font(.system(size: 12.5, weight: .semibold))
                    ScrollView {
                        Text(aliases.map { alias in
                            let blocked = (alias.blockers ?? []).isEmpty ? "" : " · " + L10n.text("排除：") + (alias.blockers ?? []).joined(separator: "、")
                            return "\(alias.heard) → \(alias.term) (\(alias.cues.joined(separator: "、"))\(blocked))"
                        }.joined(separator: "\n"))
                            .font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 100)
                }
            }
            Text(plugin.isStyle
                 ? L10n.text("数据去向：选中后，风格说明随听写整理发给你的模型，只影响措辞和格式，不增加一次独立调用。翻译和需求助手不使用。")
                 : L10n.text("数据去向：启用后，与本次听写相关的词和读音提示随整理发给你的模型，其余留在本机。不增加模型调用。"))
                .font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L10n.text("取消"), action: cancel).buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button(L10n.text("仅安装")) { confirm(false) }.buttonStyle(SecondaryButtonStyle())
                Button(plugin.isStyle ? L10n.text("安装并使用") : L10n.text("安装并启用")) { confirm(true) }
                    .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
