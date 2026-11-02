import Foundation
import Testing
@testable import CloneCore

final class RecordingRunner: CommandRunning {
    var commands: [(String, [String])] = []
    var failSigning = false
    var onVerifyCopy: (() throws -> Void)?

    func run(_ executable: String, arguments: [String]) throws -> String {
        commands.append((executable, arguments))
        if executable == "/usr/bin/ditto" {
            try FileManager.default.copyItem(atPath: arguments[0], toPath: arguments[1])
        }
        if arguments.contains("--sign"), failSigning {
            throw CloneError.commandFailed("codesign", 1, "模拟签名失败")
        }
        if arguments.first == "--verify", commands.count > 2 {
            try onVerifyCopy?()
        }
        return ""
    }
}

@Suite
final class CloneServiceTests {
    var root: URL!
    var source: URL!
    var install: URL!
    let files = FileManager.default

    init() throws {
        root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        source = root.appendingPathComponent("Official WeChat.app", isDirectory: true)
        install = root.appendingPathComponent("Applications", isDirectory: true)
        try files.createDirectory(at: source.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let binary = source.appendingPathComponent("Contents/MacOS/WeChat")
        try Data("fixture".utf8).write(to: binary)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        try writePlist(["CFBundleIdentifier": CloneService.officialBundleID,
                        "CFBundleExecutable": "WeChat", "CFBundleShortVersionString": "4.1.11"],
                       at: source.appendingPathComponent("Contents/Info.plist"))
        let locale = source.appendingPathComponent("Contents/Resources/zh-Hans.lproj")
        try files.createDirectory(at: locale, withIntermediateDirectories: true)
        try writePlist(["CFBundleName": "微信", "NSCameraUsageDescription": "视频通话"],
                       at: locale.appendingPathComponent("InfoPlist.strings"))
    }

    deinit { if let root { try? files.removeItem(at: root) } }

    @Test
    func testCreatesIndependentCopyAndPreservesOriginalAndLocalizedPermissions() throws {
        let original = try Data(contentsOf: source.appendingPathComponent("Contents/Info.plist"))
        let runner = RecordingRunner()
        var steps: [CloneStep] = []
        let result = try CloneService(installDirectory: install, runner: runner)
            .create(source: source, name: "工作 微信.app", progress: { steps.append($0) })
        #expect(result.applicationURL.lastPathComponent == "工作 微信.app")
        #expect(result.sourceVersion == "4.1.11")
        #expect(steps == CloneStep.allCases)
        let metadata = try plist(result.applicationURL.appendingPathComponent("Contents/Info.plist"))
        #expect((metadata["CFBundleIdentifier"] as! String).hasPrefix(CloneService.officialBundleID + ".dual."))
        #expect(metadata["CFBundleDisplayName"] as? String == "工作 微信")
        let localized = try plist(result.applicationURL.appendingPathComponent("Contents/Resources/zh-Hans.lproj/InfoPlist.strings"))
        #expect(localized["CFBundleName"] as? String == "工作 微信")
        #expect(localized["NSCameraUsageDescription"] as? String == "视频通话")
        #expect(try Data(contentsOf: source.appendingPathComponent("Contents/Info.plist")) == original)
        #expect(try files.contentsOfDirectory(atPath: install.path) == ["工作 微信.app"])
        #expect(runner.commands.first?.1 == ["--verify", "--deep", "--strict", source.path])
    }

    @Test
    func testRejectsPathTraversalAndControlCharacters() {
        for name in ["", " ", ".hidden", "..", "../微信", "a/b", "a\\b", "a:b", "a\nb", String(repeating: "a", count: 61)] {
            #expect(throws: (any Error).self) { try CloneService.normalizedName(name) }
        }
    }

    @Test
    func testExistingApplicationIsNeverOverwritten() throws {
        let destination = install.appendingPathComponent("已有.app")
        try files.createDirectory(at: destination, withIntermediateDirectories: true)
        let sentinel = destination.appendingPathComponent("sentinel")
        try Data("keep".utf8).write(to: sentinel)
        let runner = RecordingRunner()
        #expect(throws: (any Error).self) {
            try CloneService(installDirectory: install, runner: runner).create(source: source, name: "已有")
        }
        #expect(try String(contentsOf: sentinel) == "keep")
        #expect(runner.commands.isEmpty)
    }

    @Test
    func testDanglingSymlinkIsNeverOverwritten() throws {
        try files.createDirectory(at: install, withIntermediateDirectories: true)
        let link = install.appendingPathComponent("链接.app")
        try files.createSymbolicLink(atPath: link.path, withDestinationPath: root.appendingPathComponent("absent").path)
        let runner = RecordingRunner()
        #expect(throws: (any Error).self) {
            try CloneService(installDirectory: install, runner: runner).create(source: source, name: "链接")
        }
        #expect(runner.commands.isEmpty)
    }

    @Test
    func testSigningFailureCleansStagingWithoutTouchingSource() throws {
        let runner = RecordingRunner()
        runner.failSigning = true
        #expect(throws: (any Error).self) {
            try CloneService(installDirectory: install, runner: runner).create(source: source, name: "失败")
        }
        #expect(try files.contentsOfDirectory(atPath: install.path).isEmpty)
        #expect(CloneService.sourceVersion(at: source) == "4.1.11")
    }

    @Test
    func testExistingCloneCannotBeSelectedAsOfficialSource() throws {
        try writePlist(["CFBundleIdentifier": "com.tencent.xinWeChat.dual.test", "CFBundleExecutable": "WeChat"],
                       at: source.appendingPathComponent("Contents/Info.plist"))
        let runner = RecordingRunner()
        #expect(throws: (any Error).self) {
            try CloneService(installDirectory: install, runner: runner).create(source: source, name: "错误来源")
        }
        #expect(runner.commands.isEmpty)
    }

    @Test
    func testDestinationCreatedDuringBuildIsPreserved() throws {
        let runner = RecordingRunner()
        runner.onVerifyCopy = { [self] in
            try files.createDirectory(at: install.appendingPathComponent("竞争.app"), withIntermediateDirectories: false)
            try Data("keep".utf8).write(to: install.appendingPathComponent("竞争.app/sentinel"))
        }
        #expect(throws: (any Error).self) {
            try CloneService(installDirectory: install, runner: runner).create(source: source, name: "竞争")
        }
        #expect(try String(contentsOf: install.appendingPathComponent("竞争.app/sentinel")) == "keep")
        #expect(try files.contentsOfDirectory(atPath: install.path) == ["竞争.app"])
    }

    @Test
    func testShellCharactersArePassedAsLiteralArguments() throws {
        let name = "工作 `literal` $(literal)"
        let runner = RecordingRunner()
        let result = try CloneService(installDirectory: install, runner: runner).create(source: source, name: name)
        #expect(result.applicationURL.lastPathComponent == name + ".app")
        #expect(runner.commands.allSatisfy { $0.0 == "/usr/bin/ditto" || $0.0 == "/usr/bin/codesign" })
    }

    @Test
    func testRealSystemRunnerReportsFailureAndDrainsLargeOutput() throws {
        #expect(throws: (any Error).self) { try SystemCommandRunner().run("/usr/bin/false", arguments: []) }
        let output = try SystemCommandRunner().run("/usr/bin/jot", arguments: ["20000", "1"])
        #expect(output.hasSuffix("20000\n"))
        #expect(output.utf8.count > 64_000)
    }

    // Explicit opt-in: verifies the actual installed WeChat with real ditto and codesign.
    // The resulting copy is placed in a temporary directory and never launched.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["WECHAT_DUAL_LIVE_SOURCE"] != nil,
                   "设置 WECHAT_DUAL_LIVE_SOURCE 才执行本机微信集成测试"))
    func testLiveOfficialWeChat() throws {
        let path = try #require(ProcessInfo.processInfo.environment["WECHAT_DUAL_LIVE_SOURCE"])
        let result = try CloneService(installDirectory: install)
            .create(source: URL(fileURLWithPath: path), name: "集成测试微信")
        #expect(files.isExecutableFile(atPath: result.applicationURL.appendingPathComponent("Contents/MacOS/WeChat").path))
        #expect(try files.contentsOfDirectory(atPath: install.path) == ["集成测试微信.app"])
    }

    private func plist(_ url: URL) throws -> [String: Any] {
        try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as! [String: Any]
    }

    private func writePlist(_ value: [String: Any], at url: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0).write(to: url)
    }
}
