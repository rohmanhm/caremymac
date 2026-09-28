import Foundation

public struct ActivitySample: Sendable {
    public var processes: [ProcessStats]
    public var apps: [AppActivity]
    /// Empty unless requested; project detection scans file descriptors.
    public var projects: [ProjectActivity]

    public init(processes: [ProcessStats], apps: [AppActivity], projects: [ProjectActivity]) {
        self.processes = processes
        self.apps = apps
        self.projects = projects
    }
}

/// Processes, their app grouping, and optionally dev projects, in one pass.
public final class ActivitySampler {
    private let processSampler = ProcessSampler()
    private let appGrouping = LiveAppGrouping()
    private let projectDetector = ProjectDetector()
    private let portScanner = PortScanner()

    public init() {}

    public func sample(now: Date = .now, includeProjects: Bool) -> ActivitySample {
        let processes = processSampler.sample(now: now)
        let apps = appGrouping.group(processes)
        let projects = includeProjects
            ? projectDetector.projects(
                processes: processes,
                now: now,
                workingDirectory: ProjectDetector.workingDirectory(of:),
                ports: { portScanner.ports(for: $0) }
            )
            : []
        return ActivitySample(processes: processes, apps: apps, projects: projects)
    }
}
