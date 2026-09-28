import Foundation
import Testing
@testable import CareMyMacKit

/// Scratch folder, removed on deinit.
private final class Fixture {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("UninstallerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func folder(_ relative: String) throws -> URL {
        let folder = url.appending(path: relative, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @discardableResult
    func file(_ relative: String) throws -> URL {
        let file = url.appending(path: relative, directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: file)
        return file
    }

    /// Writes a minimal bundle with an Info.plist.
    @discardableResult
    func app(_ relative: String, id: String?, name: String? = nil, displayName: String? = nil, version: String? = "1.0") throws -> URL {
        let bundle = try folder(relative)
        var info: [String: Any] = [:]
        if let id { info["CFBundleIdentifier"] = id }
        if let name { info["CFBundleName"] = name }
        if let displayName { info["CFBundleDisplayName"] = displayName }
        if let version { info["CFBundleShortVersionString"] = version }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try folder("\(relative)/Contents")
        try data.write(to: bundle.appending(path: "Contents/Info.plist"))
        return bundle
    }
}

@Suite struct UninstallerTests {
    // MARK: App discovery

    @Test func findsAppsAtTopLevelAndOneFolderDownOnly() throws {
        let fixture = try Fixture()
        try fixture.app("Apps/Top.app", id: "com.example.top")
        try fixture.app("Apps/Suite/Writer.app", id: "com.example.writer")
        try fixture.app("Apps/Deep/Deeper/Hidden.app", id: "com.example.too-deep")
        // Apps nested inside a bundle are the bundle’s helpers, not separate apps.
        try fixture.app("Apps/Top.app/Contents/Library/LoginItems/TopHelper.app", id: "com.example.top.helper")
        try fixture.app("Apps/Suite/Writer.app/Contents/Helpers/Inner.app", id: "com.example.inner")

        let apps = try UninstallAppFinder.apps(in: [fixture.url.appending(path: "Apps")])
        #expect(apps.map(\.bundleIdentifier) == ["com.example.top", "com.example.writer"])
    }

    @Test func excludesAppleAppsExcludedIDsAndSymlinks() throws {
        let fixture = try Fixture()
        try fixture.app("Apps/Notes.app", id: "com.apple.Notes")
        try fixture.app("Apps/Self.app", id: "com.example.caremymac")
        let target = try fixture.app("Elsewhere/Linked.app", id: "com.example.linked")
        try FileManager.default.createSymbolicLink(at: fixture.url.appending(path: "Apps/Linked.app"), withDestinationURL: target)
        try fixture.app("Apps/Kept.app", id: "com.example.kept")

        let apps = try UninstallAppFinder.apps(in: [fixture.url.appending(path: "Apps")], excluding: ["com.example.caremymac"])
        #expect(apps.map(\.bundleIdentifier) == ["com.example.kept"])
    }

    @Test func readsNamesVersionStoreReceiptAndHelpers() throws {
        let fixture = try Fixture()
        let bundle = try fixture.app("Apps/Tool.app", id: "com.example.tool", name: "ToolName", displayName: "Tool Pro", version: "2.3")
        try fixture.file("Apps/Tool.app/Contents/_MASReceipt/receipt")
        try fixture.app("Apps/Tool.app/Contents/Library/LoginItems/Launcher.app", id: "com.example.tool.launcher")
        try fixture.app("Apps/Tool.app/Contents/PlugIns/Share.appex", id: "com.example.tool.share")
        try fixture.file("Apps/Tool.app/Contents/Library/LaunchServices/com.example.tool.privileged")

        let app = try #require(UninstallAppFinder.app(at: bundle))
        #expect(app.name == "Tool Pro")
        #expect(app.version == "2.3")
        #expect(app.isAppStore)
        #expect(app.names == ["Tool Pro", "ToolName", "Tool"])
        #expect(Set(app.helperBundleIdentifiers) == ["com.example.tool.launcher", "com.example.tool.share", "com.example.tool.privileged"])
    }

    @Test func dropsHelpersFromOtherVendorsAndHelpersSharedByApps() throws {
        let fixture = try Fixture()
        try fixture.app("Apps/Fox.app", id: "org.fox.browser")
        try fixture.app("Apps/Fox.app/Contents/Library/LoginItems/Updater.app", id: "org.fox.updater")
        try fixture.app("Apps/Fox.app/Contents/Library/LoginItems/Own.app", id: "org.fox.own")
        try fixture.app("Apps/Fork.app", id: "org.fox.fork")
        try fixture.app("Apps/Fork.app/Contents/Library/LoginItems/Updater.app", id: "org.fox.updater")
        try fixture.app("Apps/Admin.app", id: "org.admin.app")
        try fixture.file("Apps/Admin.app/Contents/Library/LaunchServices/org.chromium.Helper")

        let apps = try UninstallAppFinder.apps(in: [fixture.url.appending(path: "Apps")])
        let helpers = Dictionary(uniqueKeysWithValues: apps.map { ($0.bundleIdentifier ?? "", $0.helperBundleIdentifiers) })
        #expect(helpers == ["org.fox.browser": ["org.fox.own"], "org.fox.fork": [], "org.admin.app": []])
    }

    // MARK: Leftovers

    @Test func matchesEveryLibraryLocationExactly() throws {
        let fixture = try Fixture()
        let id = "com.example.Tool"
        let expected = [
            "Library/Application Support/com.example.tool",
            "Library/Application Support/Tool",
            "Library/Caches/com.example.Tool",
            "Library/Containers/com.example.Tool",
            "Library/Group Containers/ABCDE12345.com.example.Tool",
            "Library/Group Containers/group.com.example.Tool",
            "Library/Preferences/com.example.Tool.plist",
            "Library/Preferences/ByHost/com.example.Tool.0A1B2C3D-0000-1111-2222-333344445555.plist",
            "Library/Saved Application State/com.example.Tool.savedState",
            "Library/Logs/Tool",
            "Library/HTTPStorages/com.example.Tool",
            "Library/HTTPStorages/com.example.Tool.binarycookies",
            "Library/WebKit/com.example.Tool",
            "Library/Cookies/com.example.Tool.binarycookies",
            "Library/LaunchAgents/com.example.Tool.plist",
            "Library/LaunchAgents/com.example.Tool.updater.plist",
            "Library/Application Scripts/com.example.Tool",
        ]
        for path in expected {
            if path.hasSuffix(".plist") || path.hasSuffix(".binarycookies") { try fixture.file(path) } else { try fixture.folder(path) }
        }

        let scan = try UninstallLeftoverFinder.leftovers(bundleIdentifiers: [id], names: ["Tool"], home: fixture.url)
        let found = Set(scan.leftovers.map { $0.url.path })
        #expect(found == Set(expected.map { fixture.url.appending(path: $0).path }))
        #expect(scan.deniedFolders.isEmpty)
        #expect(scan.leftovers.first { $0.url.lastPathComponent.hasSuffix(".savedState") }?.kind == .savedState)
        #expect(scan.leftovers.first { $0.url.path.contains("/ByHost/") }?.kind == .preferences)
    }

    @Test func ignoresLookalikeNamesAndLongerIDs() throws {
        let fixture = try Fixture()
        let others = [
            "Library/Application Support/Code Helper",
            "Library/Application Support/VSCode",
            "Library/Application Support/Codex",
            "Library/Application Support/com.microsoft.VSCodeInsiders",
            "Library/Caches/com.microsoft.VSCodeInsiders",
            "Library/Caches/com.microsoft.VSCode.ShipIt",
            "Library/Containers/com.microsoft.VSCodeInsiders",
            "Library/Group Containers/com.microsoft.VSCodeInsiders",
            "Library/Group Containers/XYZ.com.microsoft.VSCodeInsiders",
            "Library/Logs/Code Helper",
            "Library/Preferences/com.microsoft.VSCodeInsiders.plist",
            "Library/Preferences/com.microsoft.VSCode.helper.plist",
            "Library/Preferences/ByHost/com.microsoft.VSCodeInsiders.0A1B2C3D.plist",
            "Library/Preferences/ByHost/com.microsoft.VSCode.helper.0A1B2C3D.plist",
            "Library/Saved Application State/com.microsoft.VSCodeInsiders.savedState",
            "Library/LaunchAgents/com.microsoft.VSCodeInsiders.plist",
            "Library/LaunchAgents/com.microsoft.VSCodeX.updater.plist",
            "Library/Cookies/com.microsoft.VSCodeInsiders.binarycookies",
        ]
        for path in others {
            if path.hasSuffix(".plist") || path.hasSuffix(".binarycookies") { try fixture.file(path) } else { try fixture.folder(path) }
        }
        try fixture.folder("Library/Application Support/Code")
        try fixture.file("Library/Preferences/com.microsoft.VSCode.plist")

        let scan = try UninstallLeftoverFinder.leftovers(bundleIdentifiers: ["com.microsoft.VSCode"], names: ["Code", "Visual Studio Code"], home: fixture.url)
        #expect(Set(scan.leftovers.map(\.url.lastPathComponent)) == ["Code", "com.microsoft.VSCode.plist"])
    }

    @Test func helperIdentifiersFindTheirOwnLeftovers() throws {
        let fixture = try Fixture()
        let bundle = try fixture.app("Apps/Tool.app", id: "com.example.tool")
        try fixture.app("Apps/Tool.app/Contents/Library/LoginItems/Launcher.app", id: "com.example.launcher")
        try fixture.folder("Library/Containers/com.example.launcher")
        try fixture.folder("Library/Containers/com.example.launcherx")

        let app = try #require(UninstallAppFinder.app(at: bundle))
        let scan = try UninstallLeftoverFinder.leftovers(for: app, home: fixture.url)
        #expect(scan.leftovers.map(\.url.lastPathComponent) == ["com.example.launcher"])
    }

    @Test func reportsDeniedFoldersInsteadOfFailing() throws {
        let fixture = try Fixture()
        let containers = try fixture.folder("Library/Containers")
        try fixture.folder("Library/Containers/com.example.tool")
        try fixture.folder("Library/Caches/com.example.tool")
        chmod(containers.path, 0o000)
        defer { chmod(containers.path, 0o755) }

        let scan = try UninstallLeftoverFinder.leftovers(bundleIdentifiers: ["com.example.tool"], names: [], home: fixture.url)
        #expect(scan.leftovers.map(\.kind) == [.caches])
        #expect(scan.deniedFolders == [containers.path])
    }

    // MARK: Administrator move

    @Test func trashDestinationSkipsTakenNamesLikeFinder() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let date = Date(timeIntervalSince1970: 9 * 3600 + 5 * 60 + 7)
        let bundle = URL(fileURLWithPath: "/Applications/Some App.app")
        let trash = URL(fileURLWithPath: "/Users/me/.Trash", isDirectory: true)
        func destination(taken: Set<String>) -> String? {
            UninstallTrash.trashDestination(for: bundle, in: trash, date: date, calendar: calendar) { !taken.contains($0.lastPathComponent) }?.path
        }

        #expect(destination(taken: []) == "/Users/me/.Trash/Some App.app")
        #expect(destination(taken: ["Some App.app"]) == "/Users/me/.Trash/Some App 09.05.07.app")
        #expect(destination(taken: ["Some App.app", "Some App 09.05.07.app", "Some App 09.05.07 2.app"]) == "/Users/me/.Trash/Some App 09.05.07 3.app")
        #expect(UninstallTrash.trashDestination(for: bundle, in: trash, date: date, calendar: calendar) { _ in false } == nil)
    }

    /// Runs the built script without administrator privileges to prove the path survives AppleScript and shell quoting.
    @Test func administratorMoveQuotesAwkwardPaths() async throws {
        let fixture = try Fixture()
        let source = try fixture.app(#"We'd "Say" $(x) App.app"#, id: "com.example.say")
        let trash = try fixture.folder(".Trash")
        try fixture.folder(#".Trash/We'd "Say" $(x) App.app"#)
        let destination = try #require(UninstallTrash.trashDestination(for: source, in: trash, date: .now) {
            !FileManager.default.fileExists(atPath: $0.path)
        })
        #expect(destination.lastPathComponent != source.lastPathComponent)

        let arguments = UninstallTrash.administratorMoveArguments(from: source, to: destination)
        let suffix = " with administrator privileges"
        #expect(arguments.count == 2 && arguments[1].hasSuffix(suffix))
        let result = try await OptimizeCommand.run(OptimizeCommand.osascript, [arguments[0], String(arguments[1].dropLast(suffix.count))])

        #expect(result.succeeded, "\(result.errorOutput)")
        #expect(!FileManager.default.fileExists(atPath: source.path))
        #expect(FileManager.default.fileExists(atPath: destination.appending(path: "Contents/Info.plist").path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: trash.appending(path: source.lastPathComponent).path).isEmpty)
    }
}
