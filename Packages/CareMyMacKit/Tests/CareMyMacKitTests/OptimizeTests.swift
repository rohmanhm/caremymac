import Foundation
import Testing
@testable import CareMyMacKit

private func plist(_ dictionary: [String: Any], format: PropertyListSerialization.PropertyListFormat = .xml) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: dictionary, format: format, options: 0)
}

private func parse(_ dictionary: [String: Any]) throws -> LaunchItem? {
    LaunchItem.parse(try plist(dictionary), plistPath: "/tmp/x.plist", domain: .user)
}

@Suite struct OptimizeLaunchPlistTests {
    @Test func programWinsOverProgramArguments() throws {
        let item = try #require(try parse(["Label": "com.example.a", "Program": "/usr/local/bin/a", "ProgramArguments": ["/usr/bin/b", "--flag"]]))
        #expect(item.program == "/usr/local/bin/a")
        #expect(item.arguments == ["/usr/bin/b", "--flag"])
    }

    @Test func programArgumentsFirstElementIsTheProgram() throws {
        let item = try #require(try parse(["Label": "com.example.a", "ProgramArguments": ["/opt/homebrew/bin/watchman", "--foreground"]]))
        #expect(item.program == "/opt/homebrew/bin/watchman")
    }

    @Test func emptyProgramFallsBackToArguments() throws {
        let item = try #require(try parse(["Label": "com.example.a", "Program": "", "ProgramArguments": ["/bin/b"]]))
        #expect(item.program == "/bin/b")
    }

    @Test func noProgramAtAll() throws {
        let item = try #require(try parse(["Label": "com.example.a", "MachServices": ["com.example.a": true]]))
        #expect(item.program == nil)
    }

    @Test func missingOrEmptyLabelIsSkipped() throws {
        #expect(try parse(["Program": "/bin/a"]) == nil)
        #expect(try parse(["Label": "", "Program": "/bin/a"]) == nil)
        #expect(try parse(["Label": 42, "Program": "/bin/a"]) == nil)
    }

    @Test func malformedPlistIsSkipped() {
        let garbage = Data("<?xml version=\"1.0\"?><plist><dict><key>Label</key>".utf8)
        #expect(LaunchItem.parse(garbage, plistPath: "/tmp/x.plist", domain: .user) == nil)
        let array = try? PropertyListSerialization.data(fromPropertyList: ["Label"], format: .xml, options: 0)
        #expect(LaunchItem.parse(array ?? Data(), plistPath: "/tmp/x.plist", domain: .user) == nil)
    }

    @Test func binaryPlistParses() throws {
        let data = try plist(["Label": "com.example.bin", "Program": "/bin/a"], format: .binary)
        #expect(LaunchItem.parse(data, plistPath: "/tmp/x.plist", domain: .system)?.label == "com.example.bin")
    }

    @Test func runAtLoadKeepAliveAndDisabled() throws {
        let plain = try #require(try parse(["Label": "a", "Program": "/bin/a"]))
        #expect(!plain.runAtLoad)
        #expect(plain.keepAlive == .never)
        #expect(plain.isEnabled)

        let always = try #require(try parse(["Label": "a", "Program": "/bin/a", "RunAtLoad": true, "KeepAlive": true, "Disabled": true]))
        #expect(always.runAtLoad)
        #expect(always.keepAlive == .always)
        #expect(always.disabledInPlist)
        #expect(!always.isEnabled)

        let conditional = try #require(try parse(["Label": "a", "Program": "/bin/a", "KeepAlive": ["SuccessfulExit": false]]))
        #expect(conditional.keepAlive == .conditional)
    }

    @Test func associatedBundleIdentifiersAcceptStringOrArray() throws {
        #expect(try parse(["Label": "a", "AssociatedBundleIdentifiers": "com.example.app"])?.associatedBundleIdentifiers == ["com.example.app"])
        #expect(try parse(["Label": "a", "AssociatedBundleIdentifiers": ["x.y", "z.w"]])?.associatedBundleIdentifiers == ["x.y", "z.w"])
    }

    @Test func definitionsReadEveryPlistInTheUserFolderAndSkipBadOnes() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "OptimizeTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let agents = home.appending(path: "Library/LaunchAgents")
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try plist(["Label": "com.b.agent", "Program": "/bin/b"]).write(to: agents.appending(path: "com.b.agent.plist"))
        try plist(["Label": "com.a.agent", "ProgramArguments": ["/bin/a"]]).write(to: agents.appending(path: "com.a.agent.plist"))
        try plist(["Program": "/bin/nolabel"]).write(to: agents.appending(path: "nolabel.plist"))
        try Data("not a plist".utf8).write(to: agents.appending(path: "broken.plist"))
        try plist(["Label": "com.c.ignored"]).write(to: agents.appending(path: "notes.txt"))

        let items = try LaunchItemScanner(home: home, uid: 501, domains: [.user]).definitions()
        #expect(items.map(\.label) == ["com.a.agent", "com.b.agent"])
        #expect(items.allSatisfy { $0.domain == .user && $0.plistPath.hasSuffix("/Library/LaunchAgents/\($0.label).plist") })
    }
}

@Suite struct OptimizeOwnerTests {
    @Test func outermostAppContainingTheProgram() {
        #expect(LaunchItemOwner.appBundlePath(containing: "/Applications/Docker.app/Contents/Library/LoginItems/Helper.app/Contents/MacOS/helper") == "/Applications/Docker.app")
        #expect(LaunchItemOwner.appBundlePath(containing: "/Users/me/Applications/Zoom.APP/Contents/MacOS/zoom") == "/Users/me/Applications/Zoom.APP")
        #expect(LaunchItemOwner.appBundlePath(containing: "/opt/homebrew/bin/watchman") == nil)
        #expect(LaunchItemOwner.appBundlePath(containing: "/Library/.app/tool") == nil)
        #expect(LaunchItemOwner.appBundlePath(containing: "Foo.app/Contents/MacOS/foo") == nil)
    }

    @Test func labelPrefixesLongestFirst() {
        #expect(LaunchItemOwner.bundleIdentifierCandidates(label: "com.google.keystone.agent") == ["com.google.keystone.agent", "com.google.keystone", "com.google"])
        #expect(LaunchItemOwner.bundleIdentifierCandidates(label: "watchman").isEmpty)
        #expect(LaunchItemOwner.bundleIdentifierCandidates(label: "com..x").isEmpty)
    }

    @Test func programPathBeatsBundleIdentifiers() {
        let owner = LaunchItemOwner.resolve(
            program: "/Applications/Logi Options+.app/Contents/MacOS/agent",
            associatedBundleIdentifiers: ["com.other.app"],
            label: "com.logi.optionsplus",
            appURLForBundleIdentifier: { _ in URL(fileURLWithPath: "/Applications/Wrong.app") }
        )
        #expect(owner == LaunchItemOwner(name: "Logi Options+", appPath: "/Applications/Logi Options+.app"))
    }

    @Test func associatedIdentifiersThenLabelPrefix() {
        let apps = ["com.docker.docker": "/Applications/Docker.app", "com.google.Chrome": "/Applications/Google Chrome.app"]
        let lookup: (String) -> URL? = { apps[$0].map { URL(fileURLWithPath: $0) } }

        let associated = LaunchItemOwner.resolve(program: "/Library/PrivilegedHelperTools/com.docker.vmnetd", associatedBundleIdentifiers: ["com.docker.docker"], label: "com.docker.vmnetd", appURLForBundleIdentifier: lookup)
        #expect(associated?.name == "Docker")

        let prefix = LaunchItemOwner.resolve(program: "/tmp/updater", associatedBundleIdentifiers: [], label: "com.google.Chrome.updater", appURLForBundleIdentifier: lookup)
        #expect(prefix == LaunchItemOwner(name: "Google Chrome", appPath: "/Applications/Google Chrome.app"))

        #expect(LaunchItemOwner.resolve(program: "/opt/homebrew/bin/watchman", associatedBundleIdentifiers: [], label: "com.github.facebook.watchman", appURLForBundleIdentifier: lookup) == nil)
    }
}

@Suite struct OptimizeLaunchctlTests {
    @Test func printDisabledAcceptsBothVocabularies() {
        let output = """
        \tdisabled services = {
        \t\t"com.docker.helper" => enabled
        \t\t"com.apple.FolderActionsDispatcher" => disabled
        \t\t"com.old.style" => true
        \t\t"com.old.enabled" => false
        \t\t"with space.label" => disabled
        \t}
        """
        #expect(Launchctl.parseDisabled(output) == [
            "com.docker.helper": false,
            "com.apple.FolderActionsDispatcher": true,
            "com.old.style": true,
            "com.old.enabled": false,
            "with space.label": true,
        ])
        #expect(Launchctl.parseDisabled("").isEmpty)
    }

    @Test func listRowsBecomeRunningOrLoaded() {
        let output = "PID\tStatus\tLabel\n1039\t0\tcom.apple.progressd\n-\t0\tcom.apple.quicklook\n-\t-9\tcom.apple.knowledgeconstructiond\n96061\t-9\tcom.apple.stickersd\ngarbage line\n"
        let jobs = Launchctl.parseList(output)
        #expect(jobs.count == 4)
        #expect(jobs["com.apple.progressd"]?.state == .running(pid: 1039))
        #expect(jobs["com.apple.quicklook"]?.state == .loaded(lastExitStatus: 0))
        #expect(jobs["com.apple.knowledgeconstructiond"]?.state == .loaded(lastExitStatus: -9))
        #expect(jobs["com.apple.stickersd"]?.state == .running(pid: 96061))
        #expect(jobs["Label"] == nil)
    }

    @Test func printServicesBlockOnly() {
        let output = """
        system = {
        \ttype = system
        \tservices = {
        \t\t       0      - \tcom.apple.backgroundassets.managed.relay.service
        \t\t   35531      - \tcom.apple.lskdd
        \t\t       0   (pe) \tcom.apple.kernelmanager_helper
        \t\t       0      1 \tcom.apple.wifiFirmwareLoader
        \t}
        \tunmanaged processes = {
        \t\t    4242      - \tcom.not.a.service
        \t}
        }
        """
        let jobs = Launchctl.parsePrintServices(output)
        #expect(jobs.count == 4)
        #expect(jobs["com.apple.lskdd"]?.state == .running(pid: 35531))
        #expect(jobs["com.apple.kernelmanager_helper"]?.state == .loaded(lastExitStatus: nil))
        #expect(jobs["com.apple.wifiFirmwareLoader"]?.state == .loaded(lastExitStatus: 1))
        #expect(jobs["com.not.a.service"] == nil)
    }
}

@Suite struct OptimizeCommandTests {
    @Test func shellQuotingOnlyWhenNeeded() {
        #expect(OptimizeCommand.shellQuoted("/usr/bin/mdutil") == "/usr/bin/mdutil")
        #expect(OptimizeCommand.shellQuoted("local,system,user") == "local,system,user")
        #expect(OptimizeCommand.shellQuoted("a b") == "'a b'")
        #expect(OptimizeCommand.shellQuoted("it's") == #"'it'\''s'"#)
        #expect(OptimizeCommand.shellQuoted("") == "''")
        #expect(OptimizeCommand.shellQuoted("$(rm -rf ~)") == "'$(rm -rf ~)'")
    }

    @Test func commandsJoinAndStopAtFirstFailure() {
        #expect(OptimizeCommand.shellCommand([["/usr/bin/dscacheutil", "-flushcache"], ["/usr/bin/killall", "-HUP", "mDNSResponder"]])
            == "/usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder")
    }

    @Test func administratorScriptEscapesQuotesAndBackslashes() {
        #expect(OptimizeCommand.administratorArguments([["/usr/sbin/purge"]])
            == ["-e", #"do shell script "/usr/sbin/purge" with administrator privileges"#])
        let tricky = OptimizeCommand.administratorArguments([["/bin/echo", #"say "hi"\n"#]])
        #expect(tricky == ["-e", #"do shell script "/bin/echo 'say \"hi\"\\n'" with administrator privileges"#])
    }

    @Test func everyMaintenanceTaskUsesAbsoluteExecutables() {
        for task in MaintenanceTask.all {
            for command in task.commands {
                #expect(command.first?.hasPrefix("/") == true, "\(task.title)")
            }
            for invocation in task.invocations {
                #expect(invocation.executable == (task.needsAdministrator ? "/usr/bin/osascript" : task.commands[0][0]))
            }
        }
    }

    @Test func passwordCancelIsRecognized() {
        let cancel = CommandResult(status: 1, output: "", errorOutput: "0:81: execution error: User canceled. (-128)\n")
        #expect(OptimizeCommand.isUserCancel(cancel))
        let failure = CommandResult(status: 1, output: "", errorOutput: "0:81: execution error: mdutil: unknown volume (1)\n")
        #expect(!OptimizeCommand.isUserCancel(failure))
        #expect(OptimizeCommand.scriptErrorMessage(failure) == "mdutil: unknown volume")
        #expect(!OptimizeCommand.isUserCancel(CommandResult(status: 0, output: "(-128)", errorOutput: "(-128)")))
    }

    @Test func runCapturesOutputAndStatus() async throws {
        let result = try await OptimizeCommand.run("/bin/sh", ["-c", "echo out; echo err >&2; exit 3"])
        #expect(result.status == 3)
        #expect(result.output == "out\n")
        #expect(result.errorOutput == "err\n")
        await #expect(throws: CommandError.self) { try await OptimizeCommand.run("/nonexistent/tool", []) }
    }
}

@Suite struct OptimizeMaintenanceTests {
    @Test func localSnapshotListing() {
        #expect(Maintenance.parseLocalSnapshots("Snapshots for disk /:\n").isEmpty)
        #expect(Maintenance.parseLocalSnapshots("Snapshots for disk /:\ncom.apple.TimeMachine.2026-09-01-101010.local\ncom.apple.TimeMachine.2026-09-02-101010.local\n")
            == ["com.apple.TimeMachine.2026-09-01-101010.local", "com.apple.TimeMachine.2026-09-02-101010.local"])
    }

    @Test func thinningSummary() {
        #expect(Maintenance.thinningSummary(before: 3, after: 0) == "Removed 3 snapshots.")
        #expect(Maintenance.thinningSummary(before: 3, after: 1) == "Removed 2 snapshots; Time Machine kept 1.")
        #expect(Maintenance.thinningSummary(before: 1, after: 1) == "Time Machine kept its only snapshot.")
        #expect(Maintenance.thinningSummary(before: 1, after: 0) == "Removed 1 snapshot.")
    }

    @Test func heavyConsumerThresholds() {
        func app(_ id: String, cpu: Double, memory: UInt64) -> AppActivity {
            let process = ProcessStats(pid: 100, ppid: 1, name: id, executablePath: nil, cpu: cpu, memory: memory, threads: 1, uid: 501, startDate: nil, diskReadBytesPerSecond: 0, diskWriteBytesPerSecond: 0, isRestricted: false)
            return AppActivity(id: id, name: id, bundleIdentifier: nil, bundlePath: nil, kind: .application, mainPID: 100, processes: [process])
        }
        let apps = [
            app("idle", cpu: 0.49, memory: HeavyConsumers.memoryThreshold - 1),
            app("big", cpu: 0.01, memory: HeavyConsumers.memoryThreshold),
            app("busy", cpu: 0.5, memory: 1),
            app("busier", cpu: 1.2, memory: 1),
        ]
        #expect(HeavyConsumers.filter(apps).map(\.id) == ["busier", "busy", "big"])
    }
}
