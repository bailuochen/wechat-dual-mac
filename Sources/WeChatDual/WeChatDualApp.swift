import AppKit
import SwiftUI
import UniformTypeIdentifiers
import CloneCore

private let projectURL = URL(string: "https://github.com/bailuochen/wechat-dual-mac")!
private let accent = Color(red: 0.05, green: 0.58, blue: 0.37)

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct WeChatDualApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("微信分身助手") {
            MainView().frame(width: 740)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .help) {
                Button("使用说明与源代码") { NSWorkspace.shared.open(projectURL) }
            }
        }
    }
}

@MainActor
final class CloneModel: ObservableObject {
    @Published var source: URL?
    @Published var name = "微信分身"
    @Published var isWorking = false
    @Published var step: CloneStep?
    @Published var result: CloneResult?
    @Published var failure: String?
    @Published var log = ""
    @Published var showDetails = false

    let service = CloneService()

    init() {
        let defaultURL = URL(fileURLWithPath: "/Applications/WeChat.app")
        source = CloneService.sourceVersion(at: defaultURL) != nil ? defaultURL :
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: CloneService.officialBundleID)
    }

    var version: String? { source.flatMap { CloneService.sourceVersion(at: $0) } }
    var destination: String { "~/Applications/\(name).app" }

    func chooseSource() {
        let panel = NSOpenPanel()
        panel.title = "选择已安装的官方微信"
        panel.prompt = "选择微信"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url {
            source = url
            result = nil
            failure = nil
        }
    }

    func create() {
        guard let source, !isWorking else { return }
        let requestedName = name
        let service = service
        isWorking = true
        result = nil
        failure = nil
        step = .checking
        log = ""
        Task {
            do {
                let created = try await Task.detached(priority: .userInitiated) { [weak self] in
                    try service.create(source: source, name: requestedName) { next in
                        Task { @MainActor [weak self] in
                            self?.step = next
                            self?.log += next.title + "\n"
                        }
                    }
                }.value
                result = created
                log += "已创建：\(created.applicationURL.path)\n"
            } catch {
                failure = error.localizedDescription
                log += "失败：\(error.localizedDescription)\n"
            }
            isWorking = false
        }
    }

    func openClone() {
        guard let result else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: result.applicationURL, configuration: configuration) {
            [weak self] _, error in
            if let error {
                Task { @MainActor in
                    self?.failure = "macOS 未能打开分身：\(error.localizedDescription)\n" +
                        "如系统阻止启动，请前往“系统设置 → 隐私与安全性”查看提示。"
                }
            }
        }
    }
}

struct MainView: View {
    @StateObject private var model = CloneModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 16) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 26, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .background(accent.gradient, in: RoundedRectangle(cornerRadius: 17))
                VStack(alignment: .leading, spacing: 6) {
                    Text("微信分身助手").font(.system(size: 26, weight: .bold))
                    Text("多一个微信，少几步操作。")
                        .font(.system(size: 14)).foregroundStyle(.secondary)
                }
                Spacer()
                Text("Mac 版").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary).padding(.horizontal, 11).padding(.vertical, 6)
                    .background(Color.primary.opacity(0.05), in: Capsule())
            }

            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "app.badge.checkmark")
                        .font(.system(size: 25)).foregroundStyle(accent)
                        .frame(width: 38)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text("官方微信").font(.system(size: 14, weight: .semibold))
                            if let version = model.version {
                                Text(version).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                        Text(model.source?.path ?? "请先选择已安装的微信")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).help(model.source?.path ?? "")
                    }
                    Spacer(minLength: 8)
                    Button("选择微信…", action: model.chooseSource)
                }
                Divider()
                VStack(alignment: .leading, spacing: 9) {
                    Text("分身名称").font(.system(size: 12, weight: .medium))
                    TextField("例如：工作微信", text: $model.name)
                        .textFieldStyle(.roundedBorder).font(.system(size: 14))
                        .accessibilityIdentifier("clone-name")
                    Label("保存到 \(model.destination)", systemImage: "folder")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .padding(22)
            .background(Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.07)))
            .disabled(model.isWorking)

            statusArea

            VStack(alignment: .leading, spacing: 6) {
                Label("保留原版应用，不复制或删除聊天记录。", systemImage: "checkmark.shield")
                Text("分身会重新签名，可能需要重新授权；微信更新后可重新创建。")
                    .padding(.leading, 20)
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)

            HStack {
                Link("使用说明 ↗", destination: projectURL).font(.system(size: 12))
                Spacer()
                if let result = model.result {
                    Button("在访达中查看") {
                        NSWorkspace.shared.activateFileViewerSelecting([result.applicationURL])
                    }
                    Button(action: model.openClone) {
                        Label("打开分身", systemImage: "arrow.up.forward.app")
                            .frame(minWidth: 105)
                    }
                    .buttonStyle(.borderedProminent).tint(accent).controlSize(.large)
                } else {
                    Button(action: model.create) {
                        Label(model.isWorking ? "正在创建…" : "创建分身",
                              systemImage: "plus.square.on.square")
                            .frame(minWidth: 105)
                    }
                    .buttonStyle(.borderedProminent).tint(accent).controlSize(.large)
                    .disabled(model.source == nil || model.name.trimmingCharacters(in: .whitespaces).isEmpty || model.isWorking)
                    .keyboardShortcut(.defaultAction)
                }
            }

            if !model.log.isEmpty {
                DisclosureGroup("查看处理详情", isExpanded: $model.showDetails) {
                    ScrollView {
                        Text(model.log).font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(height: 96).padding(.top, 8)
                }.font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .padding(32).padding(.top, 10)
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: model.name) { _ in
            if !model.isWorking { model.result = nil; model.failure = nil }
        }
        .interactiveDismissDisabled(model.isWorking)
    }

    @ViewBuilder private var statusArea: some View {
        if model.isWorking {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    ProgressView().controlSize(.small).padding(.trailing, 4)
                    Text(model.step?.title ?? "准备中").font(.system(size: 13, weight: .medium))
                    Spacer()
                    Text("请保持助手开启").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                ProgressView(value: Double((model.step?.rawValue ?? 0) + 1),
                             total: Double(CloneStep.allCases.count)).tint(accent)
            }.frame(minHeight: 48)
        } else if let failure = model.failure {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(failure).font(.system(size: 12)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        } else if model.result != nil {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 25)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 5) {
                    Text("分身已就绪").font(.system(size: 14, weight: .semibold))
                    Text("打开后，用另一个微信账号扫码登录。")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(14)
                .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
        } else {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(accent)
                Text("选择微信、起个名字，剩下的交给助手。")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }.frame(minHeight: 48)
        }
    }
}
