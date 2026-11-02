import Foundation

public enum CloneStep: Int, CaseIterable {
    case checking, copying, configuring, signing, verifying, installing

    public var title: String {
        switch self {
        case .checking: return "检查微信"
        case .copying: return "复制应用"
        case .configuring: return "设置独立标识"
        case .signing: return "重新签名"
        case .verifying: return "校验副本"
        case .installing: return "完成安装"
        }
    }
}

public struct CloneResult {
    public let applicationURL: URL
    public let sourceVersion: String
}

public enum CloneError: LocalizedError {
    case invalidName
    case invalidSource
    case alreadyExists(String)
    case invalidMetadata
    case commandFailed(String, Int32, String)

    public var errorDescription: String? {
        switch self {
        case .invalidName:
            return "请填写有效的分身名称，不能包含斜杠、冒号或控制字符，也不能以句点开头。"
        case .invalidSource:
            return "请选择已安装的官方微信（WeChat.app），不要选择已有分身。"
        case .alreadyExists(let name):
            return "“\(name)”已存在。请换一个名称；助手不会覆盖已有应用。"
        case .invalidMetadata:
            return "无法读取微信的应用信息，请重新安装官方微信后再试。"
        case .commandFailed(let tool, let status, let output):
            return "\(tool)执行失败（\(status)）。\n\(output.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }
}

public protocol CommandRunning {
    @discardableResult
    func run(_ executable: String, arguments: [String]) throws -> String
}

public struct SystemCommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        // Drain the pipe before waiting so a verbose child cannot block on a full pipe.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw CloneError.commandFailed(URL(fileURLWithPath: executable).lastPathComponent,
                                           process.terminationStatus, output)
        }
        return output
    }
}

public struct CloneService {
    public static let officialBundleID = "com.tencent.xinWeChat"
    public let installDirectory: URL
    private let runner: any CommandRunning
    private let files = FileManager.default

    public init(installDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications", isDirectory: true),
                runner: any CommandRunning = SystemCommandRunner()) {
        self.installDirectory = installDirectory
        self.runner = runner
    }

    public static func normalizedName(_ input: String) throws -> String {
        var name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.lowercased().hasSuffix(".app") { name = String(name.dropLast(4)) }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:"))
        guard !name.isEmpty, name.count <= 60, !name.hasPrefix("."),
              name.rangeOfCharacter(from: forbidden) == nil else {
            throw CloneError.invalidName
        }
        return name
    }

    public static func sourceVersion(at source: URL) -> String? {
        guard let info = try? readPlist(source.appendingPathComponent("Contents/Info.plist")),
              info["CFBundleIdentifier"] as? String == officialBundleID else { return nil }
        return info["CFBundleShortVersionString"] as? String
    }

    public func create(source: URL, name input: String,
                       progress: (CloneStep) -> Void = { _ in }) throws -> CloneResult {
        progress(.checking)
        let name = try Self.normalizedName(input)
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        let sourcePlist = source.appendingPathComponent("Contents/Info.plist")
        let info = try Self.readPlist(sourcePlist)
        guard source.pathExtension.lowercased() == "app",
              info["CFBundleIdentifier"] as? String == Self.officialBundleID,
              info["CFBundleExecutable"] as? String == "WeChat",
              files.isExecutableFile(atPath: source.appendingPathComponent("Contents/MacOS/WeChat").path)
        else { throw CloneError.invalidSource }

        let destination = installDirectory.appendingPathComponent(name + ".app", isDirectory: true)
        // attributesOfItem also catches a dangling symlink, which fileExists alone misses.
        guard (try? files.attributesOfItem(atPath: destination.path)) == nil else {
            throw CloneError.alreadyExists(destination.lastPathComponent)
        }
        try runner.run("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", source.path])
        try files.createDirectory(at: installDirectory, withIntermediateDirectories: true)
        let staging = installDirectory.appendingPathComponent(".wechat-dual-" + UUID().uuidString,
                                                              isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }
        let copy = staging.appendingPathComponent(name + ".app", isDirectory: true)

        progress(.copying)
        try runner.run("/usr/bin/ditto", arguments: [source.path, copy.path])

        progress(.configuring)
        let copyPlist = copy.appendingPathComponent("Contents/Info.plist")
        var metadata = try Self.readPlist(copyPlist)
        metadata["CFBundleIdentifier"] = Self.officialBundleID + ".dual." +
            UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        metadata["CFBundleName"] = name
        metadata["CFBundleDisplayName"] = name
        metadata["WeChatDualCreatedBy"] = "wechat-dual-mac"
        try Self.writePlist(metadata, at: copyPlist)
        try updateLocalizedNames(in: copy, name: name)

        progress(.signing)
        // Ad-hoc signing intentionally replaces the copy's original signature. No shell is used.
        try runner.run("/usr/bin/codesign", arguments: ["--force", "--deep", "--sign", "-", copy.path])

        progress(.verifying)
        try runner.run("/usr/bin/codesign", arguments: ["--verify", "--deep", "--strict", copy.path])

        progress(.installing)
        // moveItem fails if something appeared at the destination during the build.
        try files.moveItem(at: copy, to: destination)
        return CloneResult(applicationURL: destination,
                           sourceVersion: info["CFBundleShortVersionString"] as? String ?? "未知")
    }

    private func updateLocalizedNames(in application: URL, name: String) throws {
        let resources = application.appendingPathComponent("Contents/Resources", isDirectory: true)
        guard files.fileExists(atPath: resources.path) else { return }
        for locale in try files.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
            where locale.pathExtension == "lproj" {
            let strings = locale.appendingPathComponent("InfoPlist.strings")
            guard files.fileExists(atPath: strings.path) else { continue }
            var localized = try Self.readPlist(strings)
            localized["CFBundleName"] = name
            localized["CFBundleDisplayName"] = name
            try Self.writePlist(localized, at: strings)
        }
    }

    private static func readPlist(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any] else { throw CloneError.invalidMetadata }
        return info
    }

    private static func writePlist(_ info: [String: Any], at url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: url, options: .atomic)
    }
}
