import Foundation
import Testing
@testable import CareMyMacKit

private func proc(
    _ pid: Int32, ppid: Int32 = 1, path: String?, uid: UInt32 = 501, cpu: Double = 0, restricted: Bool = false,
    responsible: Int32? = nil
) -> ProcessStats {
    ProcessStats(
        pid: pid, ppid: ppid, name: path.map { ($0 as NSString).lastPathComponent } ?? "p\(pid)", executablePath: path,
        cpu: cpu, memory: 0, threads: 1, uid: uid, startDate: nil,
        diskReadBytesPerSecond: 0, diskWriteBytesPerSecond: 0, isRestricted: restricted, responsiblePID: responsible
    )
}

@Suite struct ActivityTests {
    // MARK: Delta math

    @Test func rateClampsResetsAndZeroElapsed() {
        #expect(ProcessSampler.rate(previous: 1_000, current: 3_000, elapsed: 2) == 1_000)
        #expect(ProcessSampler.rate(previous: 3_000, current: 1_000, elapsed: 2) == 0)
        #expect(ProcessSampler.rate(previous: 0, current: 1_000, elapsed: 0) == 0)
        #expect(ProcessSampler.rate(previous: 0, current: 1_000, elapsed: -1) == 0)
    }

    @Test func cpuShareConvertsMachTicks() {
        // Apple Silicon timebase 125/3: 24M ticks = 1 s of CPU time.
        let share = ProcessSampler.cpuShare(previousTicks: 0, currentTicks: 48_000_000, ticksToNanos: 125.0 / 3.0, elapsed: 2)
        #expect(abs(share - 1.0) < 1e-9)
        let twoCores = ProcessSampler.cpuShare(previousTicks: 1_000, currentTicks: 2_000_001_000, ticksToNanos: 1, elapsed: 1)
        #expect(abs(twoCores - 2.0) < 1e-9)
    }

    // MARK: App attribution

    private let chrome = RunningAppInfo(pid: 100, bundleIdentifier: "com.google.Chrome", bundlePath: "/Applications/Google Chrome.app",
                                        name: "Google Chrome", activationPolicy: .regular)
    private let terminal = RunningAppInfo(pid: 200, bundleIdentifier: "com.apple.Terminal", bundlePath: "/System/Applications/Utilities/Terminal.app/",
                                          name: "Terminal", activationPolicy: .regular)

    @Test func helpersInsideRegularAppBundleJoinParentApp() {
        let helper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/"
        let processes = [
            proc(100, path: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", cpu: 0.1),
            proc(101, ppid: 100, path: helper + "Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)", cpu: 0.2),
            proc(102, ppid: 1, path: helper + "Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"),
        ]
        let apps = AppGrouper().group(processes: processes, runningApps: [chrome])
        #expect(apps.count == 1)
        #expect(apps[0].id == "com.google.Chrome")
        #expect(apps[0].kind == .application)
        #expect(apps[0].mainPID == 100)
        #expect(apps[0].processes.map(\.pid) == [101, 100, 102])
    }

    @Test func nestedRegularAppKeepsItsOwnIdentity() {
        let xcode = RunningAppInfo(pid: 10, bundleIdentifier: "com.apple.dt.Xcode", bundlePath: "/Applications/Xcode.app",
                                   name: "Xcode", activationPolicy: .regular)
        let simulator = RunningAppInfo(pid: 20, bundleIdentifier: "com.apple.iphonesimulator",
                                       bundlePath: "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app",
                                       name: "Simulator", activationPolicy: .regular)
        let processes = [
            proc(10, path: "/Applications/Xcode.app/Contents/MacOS/Xcode"),
            proc(20, path: "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator"),
            proc(21, path: "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/XPCServices/R.xpc/Contents/MacOS/R"),
        ]
        let apps = AppGrouper().group(processes: processes, runningApps: [xcode, simulator])
        #expect(Set(apps.map { "\($0.id)=\($0.processes.map(\.pid))" }) == ["com.apple.dt.Xcode=[10]", "com.apple.iphonesimulator=[20, 21]"])
    }

    @Test func childrenInheritNearestAttributedAncestor() {
        let processes = [
            proc(200, path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
            proc(201, ppid: 200, path: "/usr/bin/login", uid: 0),
            proc(202, ppid: 201, path: "/bin/zsh"),
            proc(203, ppid: 202, path: "/opt/homebrew/bin/node"),
            // A bundled tool launched from the shell, and its helper, stay with Terminal.
            proc(204, ppid: 203, path: "/Users/me/Library/Caches/ms-playwright/chrome/Chromium.app/Contents/MacOS/Chromium"),
            proc(205, ppid: 204, path: "/Users/me/Library/Caches/ms-playwright/chrome/Chromium.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper"),
            // Same binary under launchd is not attributed.
            proc(300, ppid: 1, path: "/opt/homebrew/bin/node"),
        ]
        let apps = AppGrouper().group(processes: processes, runningApps: [terminal])
        let terminalApp = apps.first { $0.id == "com.apple.Terminal" }
        #expect(terminalApp?.processes.map(\.pid).sorted() == [200, 201, 202, 203, 204, 205])
        #expect(terminalApp?.bundlePath == "/System/Applications/Utilities/Terminal.app")
        let node = apps.first { $0.id == "/opt/homebrew/bin/node" }
        #expect(node?.processes.map(\.pid) == [300])
        #expect(node?.kind == .background)
    }

    @Test func launchdServicesJoinTheAppResponsibleForThem() {
        let webKit = "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/"
        let dia = RunningAppInfo(pid: 700, bundleIdentifier: "company.thebrowser.dia", bundlePath: "/Applications/Dia.app",
                                 name: "Dia", activationPolicy: .regular)
        let xcode = RunningAppInfo(pid: 800, bundleIdentifier: "com.apple.dt.Xcode", bundlePath: "/Applications/Xcode.app",
                                   name: "Xcode", activationPolicy: .regular)
        let ours = RunningAppInfo(pid: 900, bundleIdentifier: "com.example.CareMyMac", bundlePath: "/Users/me/Build/CareMyMac.app",
                                  name: "CareMyMac", activationPolicy: .regular)
        let processes = [
            proc(700, path: "/Applications/Dia.app/Contents/MacOS/Dia"),
            proc(701, ppid: 700, path: "/Applications/Dia.app/Contents/Frameworks/Helper (Renderer).app/Contents/MacOS/Helper (Renderer)"),
            // Responsible to the app, or to one of its helpers.
            proc(710, path: webKit + "com.apple.WebKit.WebContent.xpc/Contents/MacOS/com.apple.WebKit.WebContent", responsible: 700),
            proc(711, path: "/System/Library/Frameworks/AudioToolbox.framework/XPCServices/SandboxHelper.xpc/Contents/MacOS/SandboxHelper",
                 responsible: 701),
            // A child of a responsibility-attributed service follows it.
            proc(712, ppid: 710, path: "/usr/libexec/webkit-child"),
            // Self-responsible, or responsible to an unattributed process: stays standalone.
            proc(720, path: "/System/Library/PrivateFrameworks/Spotlight.framework/spotlightknowledged", responsible: 720),
            proc(721, path: "/usr/libexec/agent-a", responsible: 722),
            proc(722, path: "/usr/libexec/agent-b"),
            // An app launched from Xcode is responsible to Xcode, yet its children stay with it.
            proc(800, path: "/Applications/Xcode.app/Contents/MacOS/Xcode"),
            proc(900, ppid: 800, path: "/Users/me/Build/CareMyMac.app/Contents/MacOS/CareMyMac", responsible: 800),
            proc(901, ppid: 900, path: "/usr/bin/some-tool", responsible: 800),
        ]
        let apps = AppGrouper().group(processes: processes, runningApps: [dia, xcode, ours])
        let members = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, Set($0.processes.map(\.pid))) })
        #expect(members["company.thebrowser.dia"] == [700, 701, 710, 711, 712])
        #expect(members["com.example.CareMyMac"] == [900, 901])
        #expect(members["com.apple.dt.Xcode"] == [800])
        #expect(apps.first { $0.id.hasSuffix("spotlightknowledged") }?.kind == .system)
        #expect(members["/usr/libexec/agent-a"] == [721])
    }

    @Test func unattachedBundledProcessesBecomeBackgroundAppOfOutermostBundle() {
        let base = "/Applications/Dropbox.app"
        let processes = [
            proc(400, path: base + "/Contents/MacOS/Dropbox"),
            proc(401, ppid: 1, path: base + "/Contents/Library/LoginItems/DropboxHelper.app/Contents/MacOS/DropboxHelper"),
            proc(402, ppid: 1, path: "/Applications/Other.app/Contents/MacOS/Other"),
        ]
        let grouper = AppGrouper(bundleMetadata: { path in
            path == base ? BundleMetadata(name: "Dropbox", bundleIdentifier: "com.getdropbox.dropbox") : nil
        })
        let apps = grouper.group(processes: processes, runningApps: [])
        let dropbox = apps.first { $0.id == "com.getdropbox.dropbox" }
        #expect(dropbox?.kind == .background)
        #expect(dropbox?.name == "Dropbox")
        #expect(dropbox?.mainPID == 400)
        #expect(dropbox?.processes.map(\.pid).sorted() == [400, 401])
        let other = apps.first { $0.id == "/Applications/Other.app" }
        #expect(other?.name == "Other")
        #expect(other?.bundleIdentifier == nil)
    }

    @Test func accessoryAppIsBackgroundWithItsRunningName() {
        let menuBar = RunningAppInfo(pid: 500, bundleIdentifier: "com.example.bar", bundlePath: "/Applications/Bar.app",
                                     name: "Bar Pro", activationPolicy: .accessory)
        let apps = AppGrouper().group(processes: [proc(500, path: "/Applications/Bar.app/Contents/MacOS/Bar")], runningApps: [menuBar])
        #expect(apps.map(\.id) == ["com.example.bar"])
        #expect(apps[0].kind == .background)
        #expect(apps[0].name == "Bar Pro")
        #expect(apps[0].mainPID == 500)
    }

    @Test func standaloneProcessesAreSystemOrBackgroundByOwnerAndPath() {
        let processes = [
            proc(600, path: "/usr/sbin/cfprefsd", uid: 0),
            proc(601, path: "/usr/libexec/trustd"),
            proc(602, path: "/System/Library/CoreServices/Foo"),
            proc(603, path: "/opt/tools/worker", cpu: 0.5),
            proc(604, path: "/opt/tools/worker", cpu: 0.25),
            proc(605, path: nil, uid: 0, restricted: true),
            proc(606, path: "/Users/me/bin/thing", uid: 0),
        ]
        let apps = AppGrouper().group(processes: processes, runningApps: [])
        let kinds = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, $0.kind) })
        #expect(kinds["/usr/sbin/cfprefsd"] == .system)
        #expect(kinds["/usr/libexec/trustd"] == .system)
        #expect(kinds["/System/Library/CoreServices/Foo"] == .system)
        #expect(kinds["/opt/tools/worker"] == .background)
        #expect(kinds["pid:605"] == .system)
        #expect(kinds["/Users/me/bin/thing"] == .system)
        let worker = apps.first { $0.id == "/opt/tools/worker" }
        #expect(worker?.processes.map(\.pid) == [603, 604])
        #expect(worker?.mainPID == nil)
        // Sorted by CPU, highest first.
        #expect(apps.first?.id == "/opt/tools/worker")
    }

    @Test func appBundlesListsEnclosingBundlesOutermostFirst() {
        #expect(AppGrouper.appBundles(in: "/A.app/Contents/Frameworks/B.APP/Contents/MacOS/b") == ["/A.app", "/A.app/Contents/Frameworks/B.APP"])
        #expect(AppGrouper.appBundles(in: "/usr/bin/apple.application/x").isEmpty)
        #expect(AppGrouper.appBundles(in: "/Applications/Tool.app").isEmpty)
    }

    // MARK: Projects

    private func detector(_ tree: [String: [String]]) -> ProjectDetector {
        ProjectDetector(homeDirectory: "/Users/me", directoryEntries: { tree[$0] ?? [] })
    }

    @Test func projectRootIsNearestMarkedAncestorBelowHome() {
        let detector = detector([
            "/Users/me/dev/app": ["package.json", "src"],
            "/Users/me/dev/app/packages/web": ["index.ts"],
            "/Users/me/dev/dotnet": ["Api.csproj"],
            "/Users/me/dev/android/app": ["build.gradle.kts"],
            "/Users/me": [".git"],
            "/tmp/srv": ["pyproject.toml"],
        ])
        #expect(detector.projectRoot(forWorkingDirectory: "/Users/me/dev/app/packages/web/") == "/Users/me/dev/app")
        #expect(detector.projectRoot(forWorkingDirectory: "/Users/me/dev/dotnet/bin") == "/Users/me/dev/dotnet")
        #expect(detector.projectRoot(forWorkingDirectory: "/Users/me/dev/android/app") == "/Users/me/dev/android/app")
        // The home folder's own markers (dotfile repos) don't swallow everything below it.
        #expect(detector.projectRoot(forWorkingDirectory: "/Users/me/scratch/notes") == "/Users/me/scratch/notes")
        #expect(detector.projectRoot(forWorkingDirectory: "/Users/me") == "/Users/me")
        #expect(detector.projectRoot(forWorkingDirectory: "/tmp/srv/static") == "/tmp/srv")
        #expect(detector.projectRoot(forWorkingDirectory: "/") == nil)
        #expect(detector.projectRoot(forWorkingDirectory: "/usr/local/share/dotnet/sdk/8.0/Roslyn/bincore") == nil)
        #expect(detector.projectRoot(forWorkingDirectory: "/Library/Application Support/Tool") == nil)
    }

    @Test func runtimeDetection() {
        #expect(ProjectDetector.runtime(executablePath: "/opt/homebrew/bin/node", name: "node") == .node)
        #expect(ProjectDetector.runtime(executablePath: "/usr/local/bin/python3.12", name: "python3.12") == .python)
        #expect(ProjectDetector.runtime(
            executablePath: "/opt/homebrew/Cellar/python@3.13/3.13.1/Frameworks/Python.framework/Versions/3.13/Resources/Python.app/Contents/MacOS/Python",
            name: "Python") == .python)
        #expect(ProjectDetector.runtime(executablePath: "/private/var/folders/x/T/go-build123/b001/exe/main", name: "main") == .go)
        #expect(ProjectDetector.runtime(executablePath: "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend",
                                        name: "swift-frontend") == .swift)
        #expect(ProjectDetector.runtime(executablePath: "/usr/local/bin/php8.3", name: "php8.3") == .php)
        #expect(ProjectDetector.runtime(executablePath: "/Applications/Foo.app/Contents/Resources/node", name: "node") == nil)
        #expect(ProjectDetector.runtime(executablePath: "/Users/me/Library/Application Support/Zed/node/bin/node", name: "node") == nil)
        #expect(ProjectDetector.runtime(executablePath: "/usr/bin/pythonista", name: "pythonista") == nil)
        #expect(ProjectDetector.runtime(executablePath: "/bin/zsh", name: "zsh") == nil)
    }

    @Test func projectsGroupRuntimesAndDescendantsByRoot() {
        let detector = detector(["/Users/me/dev/web": ["package.json"], "/Users/me/dev/api": ["go.mod"]])
        let processes = [
            proc(10, ppid: 5, path: "/bin/zsh"),
            proc(11, ppid: 10, path: "/opt/homebrew/bin/bun", cpu: 0.1),
            proc(12, ppid: 11, path: "/opt/homebrew/bin/node", cpu: 0.3),
            proc(13, ppid: 12, path: "/Users/me/dev/web/node_modules/@esbuild/darwin-arm64/bin/esbuild"),
            proc(20, ppid: 10, path: "/opt/homebrew/bin/go"),
            proc(21, ppid: 20, path: "/private/var/folders/x/T/go-build1/b001/exe/api"),
            proc(30, ppid: 1, path: "/opt/homebrew/bin/node"),
            proc(40, ppid: 1, path: "/opt/homebrew/bin/node", restricted: true),
        ]
        let cwd: [Int32: String] = [11: "/Users/me/dev/web", 12: "/Users/me/dev/web/src", 20: "/Users/me/dev/api/cmd", 21: "/Users/me/dev/api", 30: "/"]
        var portQueries: [[Int32]] = []
        let projects = detector.projects(processes: processes, workingDirectory: { cwd[$0] }, ports: { pids in
            portQueries.append(pids.sorted())
            return pids.contains(12) ? [ListeningPort(port: 5173, proto: .tcp, address: "*", pid: 12)] : []
        })
        #expect(projects.map(\.id) == ["/Users/me/dev/web", "/Users/me/dev/api"])
        #expect(projects[0].name == "web")
        #expect(projects[0].runtimes == [.node, .bun])
        #expect(projects[0].processes.map(\.pid) == [12, 11, 13])
        #expect(projects[0].ports.map(\.port) == [5173])
        #expect(projects[1].runtimes == [.go])
        #expect(projects[1].processes.map(\.pid).sorted() == [20, 21])
        #expect(Set(portQueries) == [[11, 12, 13], [20, 21]])
    }
}
