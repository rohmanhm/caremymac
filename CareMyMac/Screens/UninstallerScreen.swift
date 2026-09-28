import AppKit
import CareMyMacKit
import CareMyMacUI
import SwiftUI

/// Installed apps beside the selected app, its leftovers in your Library, and what uninstalling moves to the Trash.
struct UninstallerScreen: View {
    @State private var model = UninstallerModel()
    @State private var sort: UninstallerModel.Sort = .size
    @State private var search = ""

    var body: some View {
        let apps = model.visibleApps(sort: sort, query: search)
        HStack(spacing: 0) {
            UninstallerList(model: model, apps: apps, sort: $sort, search: $search)
                .frame(width: 300)
            Divider()
            UninstallerDetailPane(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await model.load() }
        .task(id: model.selectedID) { await model.loadLeftovers() }
        .onChange(of: model.hasLoaded) { keepSelection(in: apps) }
    }

    /// Opens on the first listed app, like the app browser.
    private func keepSelection(in apps: [InstalledApp]) {
        if model.selectedID == nil, model.removal == nil, let first = apps.first { model.selectedID = first.id }
    }
}

// MARK: - List

private struct UninstallerList: View {
    @Bindable var model: UninstallerModel
    let apps: [InstalledApp]
    @Binding var sort: UninstallerModel.Sort
    @Binding var search: String

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Applications").font(.headline)
                    Text(Format.integer(apps.count))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer(minLength: 8)
                    Menu {
                        Picker("Sort By", selection: $sort) {
                            ForEach(UninstallerModel.Sort.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } label: {
                        Text("By \(sort.title)")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Sort the list")
                }
                TextField("Filter Apps", text: $search, prompt: Text("Filter Apps"))
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            if !model.hasLoaded {
                ProgressView("Finding apps…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if apps.isEmpty {
                let query = search.trimmingCharacters(in: .whitespaces)
                if let error = model.loadError {
                    EmptyStateView("Couldn’t List Apps", symbol: "exclamationmark.triangle", message: error)
                } else if query.isEmpty {
                    EmptyStateView("No Apps to Uninstall", symbol: "app.dashed", message: "Apps you install in Applications appear here. Apple’s apps aren’t listed.")
                } else {
                    EmptyStateView("No Results for “\(query)”", symbol: "magnifyingglass", message: "Try another name or bundle identifier.")
                }
            } else {
                List(apps, selection: $model.selectedID) { app in
                    UninstallerRow(app: app, bytes: model.sizes[app.id], lastOpened: model.lastOpened[app.id], sort: sort)
                        .contextMenu {
                            Button("Show in Finder") { ProcessActions.revealInFinder(path: app.url.path) }
                        }
                }
                .listStyle(.inset)
                .alternatingRowBackgrounds(.disabled)
            }
        }
        .background(.background)
    }
}

private struct UninstallerRow: View {
    let app: InstalledApp
    let bytes: Int64?
    let lastOpened: Date?
    let sort: UninstallerModel.Sort

    var body: some View {
        HStack(spacing: 10) {
            AppIcon(path: app.url.path, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(bytes.map { Format.bytes(Double($0)) } ?? Format.unavailable)
                .fontWeight(.medium)
                .monospacedDigit()
                .foregroundStyle(bytes == nil ? .secondary : .primary)
        }
        .padding(.vertical, 4)
        .help(app.url.path)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(app.name), \(bytes.map { Format.bytes(Double($0)) } ?? "size not measured yet"), \(detail)")
    }

    /// Version and last-opened date; an unknown date is left out unless the list is sorted by it or nothing else is known.
    private var detail: String {
        let opened = "Opened \(LastOpened.relative(lastOpened))"
        guard sort != .lastOpened, let version = app.version else { return opened }
        return lastOpened == nil ? version : "\(version) · \(opened)"
    }
}

private enum LastOpened {
    static func relative(_ date: Date?) -> String {
        guard let date else { return "Unknown" }
        return date.formatted(.relative(presentation: .named))
    }

    static func full(_ date: Date?) -> String {
        guard let date else { return "Unknown" }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}

// MARK: - Detail

private struct UninstallerDetailPane: View {
    let model: UninstallerModel

    var body: some View {
        if let app = model.selectedApp {
            UninstallerDetail(model: model, app: app)
                .id(app.id)
        } else if let removal = model.removal, removal.removedApp {
            RemovalSummary(removal: removal, dismiss: model.dismissRemoval)
        } else {
            EmptyStateView("No App Selected", symbol: "app.dashed", message: "Pick an app to see its size and the files it keeps in your Library.")
        }
    }
}

private struct UninstallerDetail: View {
    let model: UninstallerModel
    let app: InstalledApp
    @Environment(LiveMonitor.self) private var monitor
    @State private var pending: PendingRemoval?

    var body: some View {
        let leftovers = model.leftovers?.appID == app.id ? model.leftovers : nil
        let selected = model.selectedLeftovers(for: app)
        let appBytes = model.sizes[app.id]
        let leftoverBytes = selected.reduce(0) { $0 + $1.bytes }
        let isRunning = monitor.apps.contains { $0.bundlePath == app.url.path || ($0.bundleIdentifier != nil && $0.bundleIdentifier == app.bundleIdentifier) }
        let ready = leftovers != nil && appBytes != nil && !model.isRemoving

        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                header

                if let removal = model.removal, removal.appID == app.id {
                    RemovalResultCard(
                        removal: removal,
                        canMoveAsAdministrator: ready && !isRunning,
                        moveAsAdministrator: { Task { await model.removeAsAdministrator(app) } },
                        dismiss: model.dismissRemoval
                    )
                }

                HStack(spacing: Metrics.gap) {
                    StatTile("App", value: appBytes.map { Format.bytes(Double($0)) } ?? Format.unavailable, detail: app.isAppStore ? "From the App Store" : "Bundle size")
                    StatTile("Leftovers", value: leftovers == nil ? Format.unavailable : Format.bytes(Double(leftoverBytes)), detail: leftovers.map { "\(Format.integer(selected.count)) of \(Format.integer($0.rows.count)) selected" })
                    StatTile("To Remove", value: ready || model.isRemoving ? Format.bytes(Double((appBytes ?? 0) + leftoverBytes)) : Format.unavailable, detail: "App and selected leftovers")
                    StatTile("Last Opened", value: LastOpened.full(model.lastOpened[app.id]), detail: model.lastOpened[app.id] == nil ? "Not recorded by Spotlight" : LastOpened.relative(model.lastOpened[app.id]))
                }
                .fixedSize(horizontal: false, vertical: true)

                if isRunning {
                    RunningNotice(name: app.name) { model.quit(app) }
                }

                actions(isRunning: isRunning, ready: ready, selected: selected, appBytes: appBytes ?? 0, leftoverBytes: leftoverBytes)

                LeftoverList(model: model, app: app, leftovers: leftovers)

                Text("Leftovers are matched in your home folder’s Library by the app’s exact bundle identifier (and those of its helpers and extensions) or its exact name. Everything goes to the Trash, so you can put it back. Launch agents stay loaded until you log out.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                PageFooter()
            }
            .padding(Metrics.pagePadding)
        }
        .pageBackground()
        .confirmationDialog(pending?.title ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), presenting: pending) { removal in
            Button(removal.includingApp ? "Move to Trash" : "Move Leftovers to Trash", role: .destructive) {
                Task { await model.remove(app, includingApp: removal.includingApp) }
            }
        } message: { removal in
            Text(removal.message)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            AppIcon(path: app.url.path, size: 56)
            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.title.weight(.bold))
                    .lineLimit(1)
                    .help(app.name)
                Text([app.version.map { "Version \($0)" }, app.bundleIdentifier].compactMap(\.self).joined(separator: " · "))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(app.url.path)
            }
            Spacer(minLength: 12)
            Button("Show in Finder") { ProcessActions.revealInFinder(path: app.url.path) }
        }
    }

    private func actions(isRunning: Bool, ready: Bool, selected: [UninstallerModel.LeftoverRow], appBytes: Int64, leftoverBytes: Int64) -> some View {
        HStack(spacing: 12) {
            if model.isRemoving {
                ProgressView().controlSize(.small)
                Text("Moving to the Trash…").foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Remove Leftovers Only…") {
                pending = PendingRemoval(appName: app.name, includingApp: false, count: selected.count, bytes: leftoverBytes)
            }
            .disabled(!ready || isRunning || selected.isEmpty)
            .help(isRunning ? "Quit \(app.name) first" : "Move the selected leftovers to the Trash and keep the app, for example to reset it")
            Button("Uninstall…") {
                pending = PendingRemoval(appName: app.name, includingApp: true, count: selected.count, bytes: appBytes + leftoverBytes)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!ready || isRunning)
            .help(isRunning ? "Quit \(app.name) first" : "Move \(app.name) and the selected leftovers to the Trash")
        }
    }
}

private struct PendingRemoval: Identifiable {
    let appName: String
    let includingApp: Bool
    /// Selected leftovers, not counting the app.
    let count: Int
    let bytes: Int64
    var id: Bool { includingApp }

    var title: String { includingApp ? "Uninstall \(appName)?" : "Remove \(appName)’s leftovers?" }

    var message: String {
        let size = Format.bytes(Double(bytes))
        let leftovers = count == 1 ? "1 leftover" : "\(Format.integer(count)) leftovers"
        if includingApp {
            let items = count == 0 ? "\(appName)" : "\(appName) and \(leftovers)"
            return "\(items) (\(size)) will be moved to the Trash. You can put them back until you empty it."
        }
        return "\(leftovers) (\(size)) will be moved to the Trash and \(appName) starts fresh next time. You can put them back until you empty the Trash."
    }
}

private struct RunningNotice: View {
    let name: String
    let quit: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Palette.warning)
                .accessibilityHidden(true)
            Text("Quit \(name) to uninstall it.")
                .font(.callout)
            Spacer(minLength: 8)
            Button("Quit \(name)", action: quit)
                .controlSize(.small)
                .help("Asks \(name) to quit so it can save your work first")
        }
        .card(padding: 12)
    }
}

// MARK: - Leftovers

private struct LeftoverList: View {
    @Bindable var model: UninstallerModel
    let app: InstalledApp
    let leftovers: UninstallerModel.Leftovers?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Leftovers").font(.headline)
                if let leftovers {
                    Text(Format.integer(leftovers.rows.count)).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 8)
                if let leftovers, !leftovers.rows.isEmpty {
                    let allSelected = leftovers.rows.allSatisfy { !model.deselected.contains($0.id) }
                    Button(allSelected ? "Deselect All" : "Select All") {
                        model.deselected = allSelected ? Set(leftovers.rows.map(\.id)) : []
                    }
                    .buttonStyle(.link)
                    .disabled(model.isRemoving)
                }
            }

            if model.hasOtherCopy(of: app) {
                Text("Another copy of \(app.name) is installed and shares these files, so none are selected.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Group {
                if let leftovers {
                    if leftovers.rows.isEmpty {
                        Text("No leftovers found in your Library.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Metrics.cardPadding)
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(leftovers.rows) { row in
                                LeftoverRowView(row: row, isOn: Binding(
                                    get: { !model.deselected.contains(row.id) },
                                    set: { on in
                                        if on { model.deselected.remove(row.id) } else { model.deselected.insert(row.id) }
                                    }
                                ))
                                .disabled(model.isRemoving)
                                if row.id != leftovers.rows.last?.id { Divider().padding(.leading, 12) }
                            }
                        }
                    }
                } else {
                    ProgressView("Finding leftovers…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                }
            }
            .card(padding: nil)

            if let leftovers, !leftovers.deniedFolders.isEmpty || leftovers.rows.contains(where: \.isUnreadable) {
                FullDiskAccessNotice()
            }
        }
    }
}

private struct LeftoverRowView: View {
    let row: UninstallerModel.LeftoverRow
    @Binding var isOn: Bool

    var body: some View {
        let path = (row.leftover.url.path as NSString).abbreviatingWithTildeInPath
        HStack(spacing: 10) {
            Toggle(isOn: $isOn) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("\(row.leftover.kind.label), \(path)")
            VStack(alignment: .leading, spacing: 1) {
                Text(row.leftover.kind.label)
                    .lineLimit(1)
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(row.leftover.url.path)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if row.isUnreadable {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                    .help("Size is incomplete: macOS needs Full Disk Access to look inside")
                    .accessibilityLabel("Size incomplete")
            }
            Text(Format.bytes(Double(row.bytes)))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("Show in Finder", systemImage: "magnifyingglass.circle") {
                ProcessActions.revealInFinder(path: row.leftover.url.path)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Show in Finder")
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Show in Finder") { ProcessActions.revealInFinder(path: row.leftover.url.path) }
        }
    }
}

private struct FullDiskAccessNotice: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "lock.fill")
                .foregroundStyle(Palette.warning)
                .accessibilityHidden(true)
            Text("Some app data is protected. To find and measure all of it, turn on CareMyMac in Privacy & Security › Full Disk Access, then pick the app again.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Open Full Disk Access") { FullDiskAccess.openSystemSettings() }
            .controlSize(.small)
        }
    }
}

// MARK: - Results

/// Outcome of a removal for an app that is still installed: leftovers removed, or the bundle refused to move.
private struct RemovalResultCard: View {
    let removal: UninstallerModel.Removal
    let canMoveAsAdministrator: Bool
    let moveAsAdministrator: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Label(title, systemImage: removal.failures.isEmpty ? "checkmark.circle" : "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(removal.failures.isEmpty ? AnyShapeStyle(.primary) : AnyShapeStyle(Palette.warningText))
                Spacer(minLength: 8)
                Button("Dismiss", action: dismiss).buttonStyle(.link)
            }
            if removal.needsAdministrator {
                administratorPrompt
            } else {
                if removal.bundleFailed {
                    Text("macOS didn’t let CareMyMac move \(removal.appName) to the Trash. Its leftovers weren’t touched. Show it in Finder below and drag it to the Trash.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                FailureList(failures: removal.failures)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// The bundle is owned by the system: offer the administrator move, with Finder as the manual route.
    private var administratorPrompt: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("An installer put \(removal.appName) in place as the system, so moving it to the Trash needs an administrator password. Its leftovers weren’t touched; the selected ones follow once the app is in the Trash.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(removal.failures) { failure in
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                if let path = removal.failures.first?.path {
                    Button("Show in Finder") { ProcessActions.revealInFinder(path: path) }
                }
                Button("Move to Trash as Administrator…", action: moveAsAdministrator)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canMoveAsAdministrator)
                    .help("macOS asks for an administrator password, then CareMyMac moves \(removal.appName) to your Trash")
            }
        }
    }

    private var title: String {
        if removal.bundleFailed { return "\(removal.appName) Wasn’t Uninstalled" }
        let moved = "\(Format.integer(removal.movedCount)) \(removal.movedCount == 1 ? "item" : "items") (\(Format.bytes(Double(removal.movedBytes)))) moved to the Trash"
        return removal.failures.isEmpty ? moved : "\(moved), \(Format.integer(removal.failures.count)) couldn’t be moved"
    }
}

/// Shown after an app was uninstalled and left the list.
private struct RemovalSummary: View {
    let removal: UninstallerModel.Removal
    let dismiss: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                EmptyStateView(
                    "\(removal.appName) Uninstalled",
                    symbol: "trash",
                    message: "\(Format.integer(removal.movedCount)) \(removal.movedCount == 1 ? "item" : "items") (\(Format.bytes(Double(removal.movedBytes)))) moved to the Trash. Open the Trash to put anything back."
                ) {
                    Button("Done", action: dismiss)
                }
                if !removal.failures.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("\(Format.integer(removal.failures.count)) \(removal.failures.count == 1 ? "item" : "items") couldn’t be moved", systemImage: "exclamationmark.triangle.fill")
                            .font(.headline)
                            .foregroundStyle(Palette.warningText)
                        FailureList(failures: removal.failures)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card()
                }
            }
            .padding(Metrics.pagePadding)
        }
        .pageBackground()
    }
}

private struct FailureList: View {
    let failures: [CareFailure]

    var body: some View {
        ForEach(failures) { failure in
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text((failure.path as NSString).abbreviatingWithTildeInPath)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(failure.path)
                    Text(failure.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Show in Finder") { ProcessActions.revealInFinder(path: failure.path) }
                    .controlSize(.small)
            }
        }
    }
}
