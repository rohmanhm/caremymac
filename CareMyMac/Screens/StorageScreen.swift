import AppKit
import Charts
import CareMyMacKit
import CareMyMacUI
import SwiftUI

/// Startup disk capacity, the local storage index by category, and the folders that hold the most.
struct StorageScreen: View {
    @Environment(LiveMonitor.self) private var monitor
    @State private var model = StorageModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.gap) {
                PageHeader("Storage", subtitle: "See what takes up space, folder by folder.") {
                    ThermalBadge()
                }

                VolumeCard(volume: monitor.volumes.first(where: \.isRoot), model: model)

                if let result = model.result {
                    CategoriesCard(result: result)
                    FolderListCard(result: result, model: model)
                } else if model.isScanning {
                    FirstScanCard(model: model)
                } else if model.hasLoaded {
                    EmptyStateView(
                        "Not scanned yet",
                        symbol: "chart.pie",
                        message: "Scan your home folder to see which categories and folders take up space. The index stays on this Mac."
                    ) {
                        Button("Scan home folder") { model.scanHome() }
                            .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .card()
                }

                PageFooter()
            }
            .padding(Metrics.pagePadding)
        }
        .pageBackground()
        .task { await model.loadIfNeeded() }
    }
}

// MARK: - Volume and scan controls

private struct VolumeCard: View {
    let volume: VolumeStats?
    let model: StorageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "internaldrive")
                    .font(.title2)
                    .foregroundStyle(Resource.storage.color)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(volume?.name ?? "Startup disk").font(.headline).lineLimit(1)
                    Text(capacityText)
                        .font(.callout)
                        .lineLimit(1)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                controls
            }

            CapacityBar(share: usedShare)
                .accessibilityLabel("Startup disk used")
                .accessibilityValue(Format.percent(usedShare, digits: 0))

            HStack(spacing: 6) {
                Text(scopeText).lineLimit(1).truncationMode(.middle).help(scopeText)
                Text("·")
                Text(lastScanText).monospacedDigit().lineLimit(1)
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if model.isScanning {
                ScanProgressRow(model: model)
            }
            if let message = model.errorMessage {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Palette.warning)
                        .accessibilityHidden(true)
                    Text(message).font(.callout)
                    Spacer(minLength: 8)
                    Button("Dismiss", systemImage: "xmark") { model.dismissError() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .help("Dismiss")
                }
            }
        }
        .card()
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 8) {
            Button("Choose folder…") { chooseFolder() }
                .buttonStyle(.bordered)
                .disabled(model.isScanning)
                .help("Measure one folder and add it to the index")
            if model.isScanning {
                Button("Stop") { model.cancel() }
                    .buttonStyle(.bordered)
            } else if model.result == nil {
                Button("Scan home folder") { model.scanHome() }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("Rescan") { model.rescan() }
                    .buttonStyle(.borderedProminent)
                    .help("Measure the indexed folders again")
            }
        }
        .fixedSize()
    }

    private var usedShare: Double {
        volume?.usedShare ?? 0
    }

    private var capacityText: String {
        guard let volume else { return "Measuring capacity…" }
        return "\(Format.bytes(volume.usedBytes)) used · \(Format.bytes(volume.availableForImportantUsage)) free of \(Format.bytes(volume.totalBytes))"
    }

    private var scopeText: String {
        guard let result = model.result else { return "Local storage index" }
        return "Index of \(result.rootPath == model.homeURL.path ? "your home folder" : StoragePath.display(result.rootPath))"
    }

    private var lastScanText: String {
        guard let date = model.result?.date else { return "Not scanned yet" }
        return "Last scan \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Scan"
        panel.message = "Choose a folder to measure. Its sizes replace that part of the index."
        panel.directoryURL = model.homeURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.scan(folder: url)
    }
}

/// Used share of a volume, in the Storage hue.
struct CapacityBar: View {
    let share: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.fill.tertiary)
                Capsule()
                    .fill(Resource.storage.color)
                    .frame(width: max(proxy.size.width * share, share > 0 ? 8 : 0))
            }
        }
        .frame(height: 8)
    }
}

extension VolumeStats {
    /// Used share of capacity, 0...1; purgeable space counts as free, as in Finder.
    var usedShare: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
    }
}

private struct ScanProgressRow: View {
    let model: StorageModel

    var body: some View {
        let progress = model.progress
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary(progress))
                    .font(.callout)
                    .monospacedDigit()
                Text(progress.map { StoragePath.display($0.currentFolder) } ?? "Starting…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(progress?.currentFolder ?? "")
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func summary(_ progress: StorageIndexProgress?) -> String {
        let root = model.scanningPath.map { $0 == model.homeURL.path ? "home folder" : StoragePath.display($0) } ?? ""
        guard let progress else { return "Scanning \(root)…" }
        return "Scanning \(root) · \(Format.integer(progress.itemsScanned)) items · \(Format.bytes(Double(progress.bytesMeasured)))"
    }
}

private struct FirstScanCard: View {
    let model: StorageModel

    var body: some View {
        VStack(spacing: 8) {
            ProgressView()
            Text("Building the storage index").font(.headline)
            Text("Categories and the largest folders appear here when the scan finishes. It keeps running if you switch pages.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .card()
    }
}

// MARK: - Categories

private struct CategoriesCard: View {
    let result: StorageIndexResult

    var body: some View {
        let shown = result.categories.filter { $0.bytes > 0 || $0.status != .updatePending }
        let slices = shown.filter { $0.bytes > 0 }
        SectionCard("Categories", subtitle: "Where measured files live") {
            HStack(alignment: .center, spacing: 32) {
                Donut(slices: slices, total: result.totalMeasured)
                    .frame(width: 176, height: 176)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 24), GridItem(.flexible(), spacing: 24)], alignment: .leading, spacing: 14) {
                    ForEach(shown, id: \.category) { total in
                        CategoryLegendRow(total: total)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.vertical, 4)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                if result.unreadableItemCount > 0 {
                    PartialAccessNotice(count: result.unreadableItemCount)
                }
                Text("Categories follow folder locations. Sizes are allocated space; APFS clones and snapshots aren’t measured, so totals can differ from what macOS reports.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct Donut: View {
    let slices: [StorageIndexResult.CategoryTotal]
    let total: Int64

    var body: some View {
        ZStack {
            if slices.isEmpty {
                Circle()
                    .strokeBorder(.fill.tertiary, lineWidth: 176 * 0.19)
            } else {
                Chart(slices, id: \.category) { slice in
                    SectorMark(
                        angle: .value("Size", slice.bytes),
                        innerRadius: .ratio(0.62),
                        angularInset: 1.5
                    )
                    .cornerRadius(3)
                    .foregroundStyle(slice.category.color)
                }
                .chartLegend(.hidden)
            }
            VStack(spacing: 2) {
                Text(Format.bytes(Double(total)))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                Text("measured").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Format.bytes(Double(total))) measured")
        .accessibilityValue(slices.map { "\($0.category.displayName) \(Format.bytes(Double($0.bytes)))" }.joined(separator: ", "))
    }
}

private struct CategoryLegendRow: View {
    let total: StorageIndexResult.CategoryTotal

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(total.category.color)
                .frame(width: 8, height: 8)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 1) {
                Text(total.category.displayName).lineLimit(1)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(total.status == .partialAccess ? AnyShapeStyle(Palette.warningText) : AnyShapeStyle(.secondary))
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            Text(Format.bytes(Double(total.bytes)))
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
        .help(total.status == .partialAccess ? "\(total.category.displayName): \(Format.integer(total.unreadableItemCount)) items couldn’t be read" : "\(total.category.displayName): \(statusText)")
    }

    private var statusText: String {
        switch total.status {
        case .upToDate: "Up to date"
        case .updatePending: "Update pending"
        case .partialAccess: "Partial access"
        }
    }
}

private struct PartialAccessNotice: View {
    let count: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "lock.fill")
                .foregroundStyle(Palette.warning)
                .accessibilityHidden(true)
            Text("\(Format.integer(count)) \(count == 1 ? "item" : "items") couldn’t be read. To measure protected folders, turn on CareMyMac in Privacy & Security › Full Disk Access, then rescan.")
                .font(.callout)
                .monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Open Full Disk Access") { FullDiskAccess.openSystemSettings() }
            .controlSize(.small)
        }
    }
}

// MARK: - Folder list

private struct FolderListCard: View {
    let result: StorageIndexResult
    let model: StorageModel
    @State private var search = ""

    var body: some View {
        let query = search.trimmingCharacters(in: .whitespaces)
        let folders = query.isEmpty ? result.folders : result.folders.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query)
        }
        let largest = max(result.folders.first?.bytes ?? 1, 1)
        SectionCard("Where your space goes", subtitle: "Largest folders, by allocated size") {
            TextField("Find a folder", text: $search, prompt: Text("Find a folder"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .labelsHidden()
        } content: {
            if folders.isEmpty {
                Text(query.isEmpty ? "No folder is large enough to list yet. Folders appear once they hold at least 1% of what was measured." : "No folder matches “\(query)”.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(folders) { folder in
                        FolderRow(
                            folder: folder,
                            fraction: Double(folder.bytes) / Double(largest),
                            isStale: folder.measuredAt < result.date,
                            canRescan: !model.isScanning,
                            rescan: { model.scan(folder: URL(fileURLWithPath: folder.path)) }
                        )
                    }
                }
                .padding(.horizontal, -8)
            }
        }
    }
}

private struct FolderRow: View {
    let folder: StorageIndexResult.FolderEntry
    let fraction: Double
    let isStale: Bool
    let canRescan: Bool
    let rescan: () -> Void
    @State private var hovering = false

    var body: some View {
        let path = StoragePath.display(folder.path)
        Button {
            ProcessActions.revealInFinder(path: folder.path)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: folder.category.symbol)
                    .foregroundStyle(folder.category.color)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(folder.name).lineLimit(1).layoutPriority(1).help(folder.name)
                        Text(path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(folder.path)
                        Spacer(minLength: 8)
                        if folder.hasPartialAccess {
                            Badge(text: "Partial access", style: AnyShapeStyle(Palette.warningText))
                        } else if isStale {
                            Badge(text: "Update pending", style: AnyShapeStyle(.secondary))
                        }
                        Text(Format.bytes(Double(folder.bytes)))
                            .monospacedDigit()
                            .frame(minWidth: 72, alignment: .trailing)
                    }
                    ProportionBar(fraction: fraction, color: folder.category.color)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .background(hovering ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Reveal in Finder") { ProcessActions.revealInFinder(path: folder.path) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(folder.path, forType: .string)
            }
            Divider()
            Button("Rescan This Folder") { rescan() }.disabled(!canRescan)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(folder.name), \(Format.bytes(Double(folder.bytes)))\(folder.hasPartialAccess ? ", partial access" : "")")
        .accessibilityHint("Reveals the folder in Finder")
    }
}

private struct ProportionBar: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.fill.quaternary)
                Capsule().fill(color).frame(width: max(3, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
    }
}

private struct Badge: View {
    let text: String
    let style: AnyShapeStyle

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(style)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.fill.tertiary, in: Capsule())
    }
}

// MARK: - Category styling

private enum StoragePath {
    static func display(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

private extension StorageCategory {
    /// OKLCH hue, spread evenly around the wheel; "Other files" stays neutral.
    var hue: Double? {
        switch self {
        case .downloads: 245
        case .documentsAndDesktop: 290
        case .applications: 200
        case .media: 20
        case .developer: 335
        case .appData: 155
        case .caches: 65
        case .system: 110
        case .other: nil
        }
    }

    var color: Color {
        StorageCategoryColors.colors[self] ?? Color(nsColor: .systemGray)
    }

    var symbol: String {
        switch self {
        case .downloads: "arrow.down.circle"
        case .documentsAndDesktop: "doc"
        case .applications: "square.stack.3d.up"
        case .media: "photo.on.rectangle"
        case .developer: "hammer"
        case .appData: "shippingbox"
        case .caches: "tray.full"
        case .system: "gearshape"
        case .other: "folder"
        }
    }
}

private enum StorageCategoryColors {
    static let colors: [StorageCategory: Color] = Dictionary(uniqueKeysWithValues: StorageCategory.allCases.compactMap { category in
        category.hue.map { (category, Palette.primary(hue: $0)) }
    })
}
