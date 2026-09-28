import Foundation
import Testing
@testable import CareMyMacKit

/// Scratch home folder, removed on deinit.
private final class Home {
    let url: URL

    init() throws {
        let base = URL(fileURLWithPath: FileManager.default.temporaryDirectory.path).resolvingSymlinksInPath()
        url = base.appending(path: "CleanupTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func folder(_ relative: String) throws {
        try FileManager.default.createDirectory(at: url.appending(path: relative), withIntermediateDirectories: true)
    }

    func file(_ relative: String, size: Int = 16) throws {
        let file = url.appending(path: relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: size).write(to: file)
    }

    func path(_ relative: String) -> String {
        url.appending(path: relative).path
    }

    func discover(running: [String: String] = [:], apps: [String: String] = [:]) -> CleanupDiscovery {
        CleanupScanner.discover(CleanupEnvironment(home: url, runningApps: running) { apps[$0] })
    }
}

private extension CleanupDiscovery {
    func item(_ path: String) -> CleanupItem? {
        items.first { $0.url.path == path }
    }

    func paths(in category: CleanupCategory) -> Set<String> {
        Set(items.filter { $0.category == category }.map(\.url.path))
    }
}

@Suite struct CleanupTests {
    @Test func assignsEachLocationToItsCategory() throws {
        let home = try Home()
        try home.folder("Library/Caches/org.example.Reader")
        try home.file("Library/Logs/DiagnosticReports/crash.ips")
        try home.file("Library/Logs/install.log")
        try home.folder("Library/Developer/Xcode/DerivedData/App-abc")
        try home.file("Downloads/Tool.dmg")

        let found = home.discover()

        #expect(found.paths(in: .userCaches) == [home.path("Library/Caches/org.example.Reader")])
        #expect(found.paths(in: .logs) == [home.path("Library/Logs/DiagnosticReports"), home.path("Library/Logs/install.log")])
        #expect(found.paths(in: .developer) == [home.path("Library/Developer/Xcode/DerivedData")])
        #expect(found.paths(in: .installers) == [home.path("Downloads/Tool.dmg")])
        #expect(found.items.allSatisfy { $0.category != .logs || $0.isSelectedByDefault })
        #expect(found.blocked.isEmpty)
    }

    @Test func skipsAppleCachesHiddenEntriesAndSymlinks() throws {
        let home = try Home()
        try home.folder("Library/Caches/com.apple.Safari")
        try home.folder("Library/Caches/Com.Apple.Mixed")
        try home.file("Library/Caches/.DS_Store")
        try home.folder("Elsewhere/Big")
        try FileManager.default.createSymbolicLink(atPath: home.path("Library/Caches/linked"), withDestinationPath: home.path("Elsewhere/Big"))
        try home.folder("Library/Caches/com.applesauce.Juice")

        let found = home.discover()

        #expect(found.paths(in: .userCaches) == [home.path("Library/Caches/com.applesauce.Juice")])
    }

    @Test func runningAppCachesAreListedButUnselected() throws {
        let home = try Home()
        try home.folder("Library/Caches/com.example.Editor")
        try home.folder("Library/Caches/com.example.Editor.ShipIt")
        try home.folder("Library/Caches/com.example.Idle")
        try home.folder("Library/Caches/some-tool")
        try home.folder("Library/Caches/editor")

        let found = home.discover(
            running: ["COM.EXAMPLE.EDITOR": "Editor"],
            apps: ["com.example.Editor": "Editor", "com.example.Idle": "Idle App"]
        )

        let editor = try #require(found.item(home.path("Library/Caches/com.example.Editor")))
        #expect(editor.name == "Editor")
        #expect(!editor.isSelectedByDefault)
        #expect(editor.note == "In use by Editor")

        let shipIt = try #require(found.item(home.path("Library/Caches/com.example.Editor.ShipIt")))
        #expect(!shipIt.isSelectedByDefault)
        #expect(shipIt.note == "In use by Editor")

        let idle = try #require(found.item(home.path("Library/Caches/com.example.Idle")))
        #expect(idle.name == "Idle App")
        #expect(idle.isSelectedByDefault)
        #expect(idle.note == nil)

        let byName = try #require(found.item(home.path("Library/Caches/editor")))
        #expect(!byName.isSelectedByDefault)
        #expect(byName.note == "In use by Editor")

        #expect(found.item(home.path("Library/Caches/some-tool"))?.name == "some-tool")
    }

    @Test(arguments: ["Yarn", "Homebrew", "pip", "go-build", "CocoaPods"])
    func developerCachesInsideCachesAppearOnlyInDeveloperJunk(folder: String) throws {
        let home = try Home()
        try home.file("Library/Caches/\(folder)/blob", size: 64)
        try home.folder("Library/Caches/org.example.Reader")

        let found = home.discover()
        let path = home.path("Library/Caches/\(folder)")

        #expect(found.items.filter { $0.url.path == path }.map(\.category) == [.developer])
        #expect(found.item(path)?.isSelectedByDefault == true)
        #expect(found.item(path)?.note != nil)
        #expect(found.paths(in: .userCaches) == [home.path("Library/Caches/org.example.Reader")])
    }

    @Test func developerCacheClaimIsCaseInsensitive() throws {
        let home = try Home()
        try home.folder("Library/Caches/homebrew/downloads")

        let found = home.discover()

        #expect(found.paths(in: .userCaches).isEmpty)
        #expect(found.paths(in: .developer).count == 1)
    }

    @Test func noPathIsListedTwice() throws {
        let home = try Home()
        for folder in ["Yarn", "Homebrew", "pip", "go-build", "CocoaPods", "org.example.Reader"] {
            try home.folder("Library/Caches/\(folder)")
        }
        try home.folder("Library/Developer/Xcode/DerivedData")
        try home.folder(".npm/_cacache")

        let found = home.discover()
        let paths = found.items.map { $0.url.path.lowercased() }

        #expect(paths.count == Set(paths).count)
        for path in paths {
            #expect(!paths.contains { $0 != path && $0.hasPrefix(path + "/") })
        }
    }

    @Test func missingDeveloperPathsAreOmitted() throws {
        let home = try Home()
        try home.folder(".npm/_cacache")
        try home.folder(".cargo/registry")
        try home.folder("Library/Developer/Xcode/iOS DeviceSupport/18.0")
        try home.folder("Library/Developer/Xcode/watchOS DeviceSupport")
        try home.folder("Library/Developer/Xcode/Archives")
        try home.folder("Elsewhere/DerivedData")
        try home.folder("Library/Developer/Xcode")
        try FileManager.default.createSymbolicLink(atPath: home.path("Library/Developer/Xcode/DerivedData"), withDestinationPath: home.path("Elsewhere/DerivedData"))

        let found = home.discover()
        let developer = found.items.filter { $0.category == .developer }

        #expect(Set(developer.map(\.url.path)) == [
            home.path(".npm/_cacache"),
            home.path("Library/Developer/Xcode/iOS DeviceSupport"),
            home.path("Library/Developer/Xcode/watchOS DeviceSupport"),
        ])
        #expect(found.item(home.path(".npm/_cacache"))?.name == "npm cache")
        #expect(found.item(home.path(".npm/_cacache"))?.isSelectedByDefault == true)
        let iOS = try #require(found.item(home.path("Library/Developer/Xcode/iOS DeviceSupport")))
        #expect(iOS.name == "iOS Device Support")
        #expect(!iOS.isSelectedByDefault)
    }

    @Test func oldInstallersAreTopLevelAndFilteredByExtension() throws {
        let home = try Home()
        for name in ["App.dmg", "Driver.PKG", "Suite.mpkg", "Xcode.xip", "Linux.iso", "notes.txt", "archive.zip", "dmg"] {
            try home.file("Downloads/\(name)")
        }
        try home.file("Downloads/Nested/Inner.dmg")
        try home.file("Downloads/.hidden.dmg")

        let found = home.discover()
        let installers = found.items.filter { $0.category == .installers }

        #expect(Set(installers.map(\.name)) == ["App.dmg", "Driver.PKG", "Suite.mpkg", "Xcode.xip", "Linux.iso"])
        #expect(installers.allSatisfy { !$0.isSelectedByDefault && $0.modified != nil })
    }

    @Test func emptyingTheTrashRemovesItsContentsOnly() throws {
        let home = try Home()
        try home.file(".Trash/old.txt")
        try home.file(".Trash/Folder/inner.bin", size: 4096)
        try home.file("Keep/target.txt")
        try FileManager.default.createSymbolicLink(atPath: home.path(".Trash/link"), withDestinationPath: home.path("Keep/target.txt"))

        guard case .contents(let children) = CleanupTrash.list(home: home.url) else {
            Issue.record("Trash should be listable")
            return
        }
        #expect(Set(children.map(\.lastPathComponent)) == ["old.txt", "Folder", "link"])

        #expect(CleanupTrash.empty(home: home.url).isEmpty)
        #expect(CleanupTrash.list(home: home.url) == .contents([]))
        #expect(FileManager.default.fileExists(atPath: home.path(".Trash")))
        #expect(FileManager.default.fileExists(atPath: home.path("Keep/target.txt")))
    }

    @Test func missingTrashIsEmpty() throws {
        let home = try Home()
        #expect(CleanupTrash.list(home: home.url) == .contents([]))
    }

    @Test func measureReportsEveryURLOnce() async throws {
        let home = try Home()
        var urls: [URL] = []
        for index in 0..<9 {
            try home.file("Items/\(index)/data", size: 5000 * (index + 1))
            urls.append(home.url.appending(path: "Items/\(index)"))
        }
        let expected = try Dictionary(uniqueKeysWithValues: urls.map { ($0.path, try CareFiles.allocatedSize(of: $0)) })
        let reported = Reported()

        try await CleanupScanner.measure(urls, concurrency: 3) { url, size in await reported.add(url.path, size) }

        #expect(await reported.sizes == expected)
        #expect(await reported.count == urls.count)
    }
}

private actor Reported {
    var sizes: [String: Int64] = [:]
    var count = 0

    func add(_ path: String, _ size: Int64) {
        sizes[path] = size
        count += 1
    }
}
