import AppKit
import CareMyMacKit
import CareMyMacUI
import SwiftUI

/// Caches, logs, developer build products and old installers under the home folder, plus the Trash.
struct CleanupScreen: View {
    @State private var model = CleanupModel()
    @State private var pendingRemoval: CleanupModel.Removal?
    @State private var confirmingEmptyTrash = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                PageHeader("Cleanup", subtitle: "Caches, logs and leftovers in your home folder that are safe to clear.") {
                    Button("Rescan") { model.scan() }
                        .disabled(model.isBusy)
                        .help("Look for files to clean again")
                }

                SummaryCard(model: model) { pendingRemoval = model.selectedRemoval() }

                if model.hasListed {
                    ForEach(CleanupCategory.allCases) { category in
                        CategoryCard(model: model, category: category)
                    }
                    TrashCard(model: model) { confirmingEmptyTrash = true }
                } else {
                    ProgressView("Looking for files to clean…")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 48)
                        .card()
                }

                Text("Selected items move to the Trash, so you can put them back until you empty it. Apps and tools recreate caches as they need them. Sizes are allocated space.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                PageFooter()
            }
            .padding(Metrics.pagePadding)
        }
        .pageBackground()
        .onAppear { model.appear() }
        .onDisappear { model.disappear() }
        .confirmationDialog(
            pendingRemoval.map { "Move \(Self.count($0.urls.count)) to the Trash?" } ?? "",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { removal in
            Button("Move to Trash") { model.moveToTrash(removal) }
        } message: { removal in
            Text("\(Format.bytes(Double(removal.bytes))) will move to the Trash. You can put items back from the Trash until you empty it.")
        }
        .confirmationDialog("Empty the Trash?", isPresented: $confirmingEmptyTrash) {
            Button("Empty Trash", role: .destructive) { model.emptyTrash() }
        } message: {
            Text(emptyTrashMessage)
        }
        .alert(
            model.failureReport?.title ?? "",
            isPresented: Binding(get: { model.failureReport != nil }, set: { if !$0 { model.failureReport = nil } }),
            presenting: model.failureReport
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { report in
            Text(Self.describe(report.failures))
        }
    }

    private var emptyTrashMessage: String {
        guard case .contents(let count, let bytes) = model.trash else { return "This can’t be undone." }
        let size = bytes.map { " (\(Format.bytes(Double($0))))" } ?? ""
        return "\(Self.count(count))\(size) will be deleted permanently. This can’t be undone."
    }

    static func count(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(Format.integer(count)) items"
    }

    private static func describe(_ failures: [CareFailure]) -> String {
        let shown = failures.prefix(4).map { "\(($0.path as NSString).abbreviatingWithTildeInPath): \($0.message)" }
        let more = failures.count - shown.count
        return (shown + (more > 0 ? ["And \(Self.count(more)) more."] : [])).joined(separator: "\n\n")
    }
}

// MARK: - Summary

private struct SummaryCard: View {
    let model: CleanupModel
    let moveToTrash: () -> Void

    var body: some View {
        let selected = model.selectedItems.count
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Selected").font(.callout).foregroundStyle(.secondary)
                    Text(Format.bytes(Double(model.selectedBytes)))
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    Text(selected == 0 ? "Nothing selected" : "\(CleanupScreen.count(selected)) selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: 12)
                Button("Move to Trash…", action: moveToTrash)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(selected == 0 || model.isBusy)
                    .help(model.isScanning ? "Available when measuring finishes" : "Move the selected items to the Trash")
            }
            if let status {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var status: String? {
        switch model.activity {
        case .idle: nil
        case .discovering: "Looking for files to clean…"
        case .measuring:
            "Measuring \(model.measuringCategory?.title ?? "items") · \(Format.integer(model.items.count - model.unmeasured.count)) of \(CleanupScreen.count(model.items.count))"
        case .measuringTrash: "Measuring the Trash…"
        case .movingToTrash: "Moving items to the Trash…"
        case .emptyingTrash: "Emptying the Trash…"
        }
    }
}

// MARK: - Categories

private struct CategoryCard: View {
    let model: CleanupModel
    let category: CleanupCategory
    @State private var expanded = false

    static let collapsedCount = 5

    var body: some View {
        let items = sorted(model.items(in: category))
        let total = items.reduce(Int64(0)) { $0 + (model.sizes[$1.id] ?? 0) }
        let measuring = items.contains { model.unmeasured.contains($0.id) } && model.activity == .measuring
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Toggle(sources: items.map { selection(for: $0) }, isOn: \.self) {
                    Text(category.title).font(.headline)
                }
                .toggleStyle(.checkbox)
                .disabled(items.isEmpty)
                .help(items.isEmpty ? "" : "Select or deselect every item in \(category.title)")
                Spacer(minLength: 12)
                if !items.isEmpty {
                    Text(measuring ? "\(Format.bytes(Double(total)))…" : Format.bytes(Double(total)))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .help(measuring ? "Still measuring" : "\(CleanupScreen.count(items.count)) in \(category.title)")
                }
            }
            .padding(.horizontal, Metrics.cardPadding)
            .padding(.top, 12)
            Text(category.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, Metrics.cardPadding + 22)
                .padding(.trailing, Metrics.cardPadding)
                .padding(.top, 2)
                .padding(.bottom, 12)

            Divider()

            if model.blocked.contains(category) {
                FullDiskAccessNotice(message: category.blockedMessage)
                    .padding(.horizontal, Metrics.cardPadding)
                    .padding(.vertical, 12)
            } else if items.isEmpty {
                Text("Nothing to clean")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, Metrics.cardPadding)
                    .padding(.vertical, 12)
            } else {
                let shown = expanded ? items : Array(items.prefix(Self.collapsedCount))
                VStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                        if index > 0 { Divider().padding(.leading, Metrics.cardPadding + 22) }
                        CleanupRow(item: item, size: model.sizes[item.id], isOn: selection(for: item))
                    }
                    if items.count > Self.collapsedCount {
                        Divider()
                        Button(expanded ? "Show fewer" : "Show all \(Format.integer(items.count))") {
                            expanded.toggle()
                        }
                        .buttonStyle(.link)
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Metrics.cardPadding)
                        .padding(.vertical, 10)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: nil)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(category.title)
    }

    /// Largest first; unmeasured items after measured ones, by name.
    private func sorted(_ items: [CleanupItem]) -> [CleanupItem] {
        items.sorted { lhs, rhs in
            let left = model.sizes[lhs.id] ?? -1
            let right = model.sizes[rhs.id] ?? -1
            if left != right { return left > right }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func selection(for item: CleanupItem) -> Binding<Bool> {
        Binding(
            get: { model.selection.contains(item.id) },
            set: { isOn in
                if isOn { model.selection.insert(item.id) } else { model.selection.remove(item.id) }
            }
        )
    }
}

private struct CleanupRow: View {
    let item: CleanupItem
    let size: Int64?
    let isOn: Binding<Bool>

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Toggle(isOn: isOn) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.name)
                    Text((item.url.path as NSString).abbreviatingWithTildeInPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(item.url.path)
                    if let note {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.leading, 4)
            }
            .toggleStyle(.checkbox)
            Spacer(minLength: 12)
            Text(size.map { Format.bytes(Double($0)) } ?? Format.unavailable)
                .monospacedDigit()
                .foregroundStyle(size == nil ? .secondary : .primary)
                .frame(minWidth: 72, alignment: .trailing)
                .help(size == nil ? "Measuring" : "Allocated size")
            Button("Reveal") { ProcessActions.revealInFinder(path: item.url.path) }
                .buttonStyle(.link)
                .help("Show \(item.name) in Finder")
        }
        .font(.callout)
        .padding(.horizontal, Metrics.cardPadding)
        .padding(.vertical, 8)
        .contextMenu {
            Button("Reveal in Finder") { ProcessActions.revealInFinder(path: item.url.path) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url.path, forType: .string)
            }
        }
    }

    private var note: String? {
        if let modified = item.modified {
            return "Modified \(modified.formatted(date: .abbreviated, time: .omitted))"
        }
        return item.note
    }
}

// MARK: - Trash

private struct TrashCard: View {
    let model: CleanupModel
    let empty: () -> Void

    var body: some View {
        SectionCard("Trash", subtitle: "Emptying the Trash deletes its items permanently.") {
            if case .contents(let count, let bytes) = model.trash, count > 0 {
                Text(bytes.map { Format.bytes(Double($0)) } ?? "Measuring…")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        } content: {
            switch model.trash {
            case .unknown:
                ProgressView().controlSize(.small)
            case .needsFullDiskAccess:
                FullDiskAccessNotice(message: "CareMyMac can’t see inside the Trash. To measure and empty it, turn on CareMyMac in Privacy & Security › Full Disk Access, then rescan.")
            case .contents(let count, _):
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(count == 0 ? "The Trash is empty." : "\(CleanupScreen.count(count)) in the Trash")
                        .font(.callout)
                        .monospacedDigit()
                    Button("Open Trash") { NSWorkspace.shared.open(CleanupTrash.url(home: model.home)) }
                        .buttonStyle(.link)
                        .font(.callout)
                        .help("Open the Trash in Finder")
                    Spacer(minLength: 12)
                    Button("Empty Trash…", role: .destructive, action: empty)
                        .disabled(count == 0 || model.isBusy)
                        .help("Delete everything in the Trash permanently")
                }
            }
        }
    }
}

private struct FullDiskAccessNotice: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "lock.fill")
                .foregroundStyle(Palette.warning)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Open Full Disk Access") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                    NSWorkspace.shared.open(url)
                }
            }
            .controlSize(.small)
        }
    }
}

private extension CleanupCategory {
    var summary: String {
        switch self {
        case .userCaches: "Files apps keep to start and load faster. Caches of running apps stay unselected."
        case .logs: "Activity and diagnostic logs apps have written."
        case .developer: "Build products and package downloads that developer tools recreate."
        case .installers: "Disk images and installer packages in Downloads. Nothing here is selected until you choose it."
        }
    }

    var blockedMessage: String {
        switch self {
        case .userCaches: "CareMyMac can’t read ~/Library/Caches. Turn on CareMyMac in Privacy & Security › Full Disk Access, then rescan."
        case .logs: "CareMyMac can’t read ~/Library/Logs. Turn on CareMyMac in Privacy & Security › Full Disk Access, then rescan."
        case .developer: "CareMyMac can’t read your developer folders. Turn on CareMyMac in Privacy & Security › Full Disk Access, then rescan."
        case .installers: "CareMyMac can’t read your Downloads folder. Turn on CareMyMac in Privacy & Security › Full Disk Access, then rescan."
        }
    }
}
