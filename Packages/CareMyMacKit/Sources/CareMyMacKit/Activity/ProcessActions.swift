import AppKit
import Darwin

public enum ProcessActionError: Error, Equatable, LocalizedError {
    /// The process belongs to another user or is protected.
    case notPermitted(pid: Int32, name: String)
    /// The process already exited.
    case noSuchProcess(pid: Int32, name: String)
    /// The app declined or could not receive the quit request.
    case quitRefused(name: String)
    case failed(pid: Int32, name: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case let .notPermitted(pid, name):
            "You don't have permission to stop \(Self.label(pid, name))."
        case let .noSuchProcess(pid, name):
            "\(Self.label(pid, name)) is no longer running."
        case let .quitRefused(name):
            "“\(name)” didn't accept the request to quit."
        case let .failed(pid, name, code):
            "Couldn't stop \(Self.label(pid, name)): \(String(cString: strerror(code)))."
        }
    }

    private static func label(_ pid: Int32, _ name: String) -> String {
        name.isEmpty ? "process \(pid)" : "“\(name)” (pid \(pid))"
    }
}

/// Quit, force quit, and reveal actions for apps and processes.
public enum ProcessActions {
    /// Asks the app to quit gracefully; unbundled groups get SIGTERM.
    public static func quit(app: AppActivity) throws(ProcessActionError) {
        if let pid = app.mainPID, let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated {
            guard running.terminate() else { throw .quitRefused(name: app.name) }
            return
        }
        try signal(SIGTERM, targets: app.processes.map { ($0.pid, $0.name) })
    }

    /// Kills every process of the app immediately.
    public static func forceQuit(app: AppActivity) throws(ProcessActionError) {
        var remaining = app.processes
        if let pid = app.mainPID, let running = NSRunningApplication(processIdentifier: pid), !running.isTerminated,
           running.forceTerminate() {
            remaining.removeAll { $0.pid == pid }
            if remaining.isEmpty { return }
        }
        try signal(SIGKILL, targets: remaining.map { ($0.pid, $0.name) })
    }

    public static func terminate(pid: Int32) throws(ProcessActionError) {
        try send(SIGTERM, to: pid, name: processName(pid))
    }

    public static func forceTerminate(pid: Int32) throws(ProcessActionError) {
        try send(SIGKILL, to: pid, name: processName(pid))
    }

    /// SIGTERM to each process, e.g. everything holding a port.
    public static func terminate(pids: [Int32]) throws(ProcessActionError) {
        try signal(SIGTERM, targets: pids.map { ($0, processName($0)) })
    }

    public static func forceTerminate(pids: [Int32]) throws(ProcessActionError) {
        try signal(SIGKILL, targets: pids.map { ($0, processName($0)) })
    }

    public static func revealInFinder(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    /// Signals all targets. Exited ones are skipped unless none were running; other failures win.
    private static func signal(_ signal: Int32, targets: [(pid: Int32, name: String)]) throws(ProcessActionError) {
        var failure: ProcessActionError?
        var exited: ProcessActionError?
        var delivered = false
        for target in targets {
            do {
                try send(signal, to: target.pid, name: target.name)
                delivered = true
            } catch {
                if case .noSuchProcess = error {
                    exited = exited ?? error
                } else {
                    failure = failure ?? error
                }
            }
        }
        if let failure { throw failure }
        if !delivered, let exited { throw exited }
    }

    private static func send(_ signal: Int32, to pid: Int32, name: String) throws(ProcessActionError) {
        // Never signal the kernel, launchd, or a process group.
        guard pid > 1 else { throw .notPermitted(pid: pid, name: name) }
        guard kill(pid, signal) != 0 else { return }
        let code = errno
        switch code {
        case EPERM: throw .notPermitted(pid: pid, name: name)
        case ESRCH: throw .noSuchProcess(pid: pid, name: name)
        default: throw .failed(pid: pid, name: name, code: code)
        }
    }

    /// Name for messages; empty when the process is gone. Works for other users' processes too.
    static func processName(_ pid: Int32) -> String {
        if let path = executablePath(pid) {
            return ProcessSampler.displayName(path: path, fallback: "")
        }
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size else { return "" }
        return ProcessSampler.string(fromTuple: info.pbsi_comm)
    }

    static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
