import SwiftUI

// MARK: - Public view

struct TreemapView: View {
    let repository: Repository
    let archive: Archive

    @Environment(\.dismiss) private var dismiss

    @State private var root: ArchiveTree?
    @State private var drill: [String] = []  // path segments to current focus
    @State private var loading = false
    @State private var error: String?
    @State private var hovered: TreemapItem?

    private var current: ArchiveTree? {
        root?.node(at: drill)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            canvasArea
            Divider()
            footer
        }
        .frame(minWidth: 880, minHeight: 620)
        .task { await load() }
        .alert("Error", isPresented: Binding(
            get: { error != nil },
            set: { if !$0 { error = nil } }
        ), actions: {
            Button("OK") { error = nil }
        }, message: {
            Text(error ?? "")
        })
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Close")

            Divider().frame(height: 16)

            Button {
                if !drill.isEmpty { drill.removeLast() }
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(drill.isEmpty)

            Button {
                drill.removeAll()
            } label: {
                Image(systemName: "house")
            }
            .disabled(drill.isEmpty)

            Divider().frame(height: 16)

            Text(archive.name).font(.headline)
            Text("/").foregroundStyle(.tertiary)
            Text(drill.isEmpty ? "root" : drill.joined(separator: " / "))
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if let current {
                Text(ByteCountFormatter.string(
                    fromByteCount: Int64(current.totalSize),
                    countStyle: .file
                ))
                .font(.callout.bold().monospacedDigit())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Canvas

    @ViewBuilder
    private var canvasArea: some View {
        if loading {
            VStack {
                ProgressView("Loading index…")
                Text("Cached to disk afterwards, just like the browser and history views.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let node = current {
            let items = TreemapItem.items(for: node, threshold: 0.002)
            if items.isEmpty {
                ContentUnavailableView(
                    "Nothing to show",
                    systemImage: "rectangle.3.group",
                    description: Text("This folder has no measurable files.")
                )
            } else {
                GeometryReader { geo in
                    let placed = Squarify.layout(
                        items: items,
                        rect: CGRect(origin: .zero, size: geo.size)
                    )
                    ZStack(alignment: .topLeading) {
                        ForEach(placed, id: \.item.id) { p in
                            rectView(for: p)
                                .frame(width: p.rect.width, height: p.rect.height)
                                .position(x: p.rect.midX, y: p.rect.midY)
                        }
                    }
                }
                .clipped()
            }
        }
    }

    private func rectView(for p: PlacedRect) -> some View {
        let isHovered = hovered?.id == p.item.id
        let fill = color(for: p.item)
        let canDrill = !p.item.isAggregated && (p.item.node?.children.isEmpty == false)
        return ZStack {
            Rectangle()
                .fill(fill)
            Rectangle()
                .strokeBorder(
                    isHovered ? Color.white : Color.black.opacity(0.35),
                    lineWidth: isHovered ? 2 : 0.5
                )
            if p.rect.width > 60 && p.rect.height > 26 {
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.item.name)
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if p.rect.height > 42 {
                        Text(ByteCountFormatter.string(
                            fromByteCount: Int64(p.item.size),
                            countStyle: .file
                        ))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            hovered = hovering ? p.item : nil
        }
        .onTapGesture {
            guard canDrill, let node = p.item.node else { return }
            drill.append(node.name)
        }
        .help("\(p.item.name) — \(ByteCountFormatter.string(fromByteCount: Int64(p.item.size), countStyle: .file))")
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let hovered {
                HStack(spacing: 6) {
                    Circle()
                        .fill(color(for: hovered))
                        .frame(width: 10, height: 10)
                    Text(hovered.name).font(.caption.monospaced())
                    Text("·").foregroundStyle(.tertiary)
                    Text(ByteCountFormatter.string(
                        fromByteCount: Int64(hovered.size),
                        countStyle: .file
                    ))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    if let node = hovered.node, node.isDirectory {
                        Text("·").foregroundStyle(.tertiary)
                        Text("\(node.children.count) children").font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Click a rectangle to enter that folder. Items < 0.2% are grouped into 'other'.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    // MARK: - Loading

    private func load() async {
        guard root == nil else { return }
        loading = true
        defer { loading = false }
        if let cached = ArchiveCache.load(archiveId: archive.archiveId) {
            root = ArchiveTree.build(from: cached)
            return
        }
        do {
            let entries = try await BorgClient.shared.listArchiveEntries(
                repo: repository,
                archive: archive.name
            )
            ArchiveCache.save(archiveId: archive.archiveId, entries: entries)
            root = ArchiveTree.build(from: entries)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Colors

    private func color(for item: TreemapItem) -> Color {
        if item.isAggregated {
            return Color(white: 0.35)
        }
        var hasher = Hasher()
        hasher.combine(item.id)
        let h = abs(hasher.finalize())
        let hue = Double(h % 997) / 997.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.62)
    }
}

// MARK: - Treemap item (per-level snapshot)

struct TreemapItem: Identifiable, Hashable {
    let id: String
    let name: String
    let size: UInt64
    let isAggregated: Bool
    let node: ArchiveTree?

    static func == (lhs: TreemapItem, rhs: TreemapItem) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// Produces renderable items for one level of a tree, dropping items
    /// smaller than `threshold * parentTotal` into an aggregated "otros" bucket.
    static func items(for parent: ArchiveTree, threshold: Double) -> [TreemapItem] {
        let allChildren = parent.children.filter { $0.totalSize > 0 }
        let total = allChildren.reduce(UInt64(0)) { $0 + $1.totalSize }
        guard total > 0 else { return [] }
        let cutoff = UInt64(Double(total) * threshold)
        var visible: [ArchiveTree] = []
        var hidden: [ArchiveTree] = []
        for child in allChildren {
            if child.totalSize >= cutoff {
                visible.append(child)
            } else {
                hidden.append(child)
            }
        }
        var result: [TreemapItem] = visible.map { node in
            TreemapItem(
                id: node.path,
                name: node.name,
                size: node.totalSize,
                isAggregated: false,
                node: node
            )
        }
        if !hidden.isEmpty {
            let sum = hidden.reduce(UInt64(0)) { $0 + $1.totalSize }
            result.append(TreemapItem(
                id: "__rest__:\(parent.path)",
                name: "other (\(hidden.count))",
                size: sum,
                isAggregated: true,
                node: nil
            ))
        }
        return result
    }
}

// MARK: - Squarified treemap layout

struct PlacedRect {
    let item: TreemapItem
    let rect: CGRect
}

enum Squarify {
    static func layout(items: [TreemapItem], rect: CGRect) -> [PlacedRect] {
        guard !items.isEmpty, rect.width > 0, rect.height > 0 else { return [] }
        let sorted = items
            .filter { $0.size > 0 }
            .sorted { $0.size > $1.size }
        guard !sorted.isEmpty else { return [] }

        let totalSize = sorted.reduce(Double(0)) { $0 + Double($1.size) }
        let totalArea = Double(rect.width * rect.height)
        let scale = totalArea / totalSize  // units: px² per byte
        // Pre-scale each item to area (in px²), keep in parallel array.
        let areas: [Double] = sorted.map { Double($0.size) * scale }

        var result: [PlacedRect] = []
        var remaining = rect
        var row: [Int] = []  // indexes into sorted/areas

        func worst(_ indexes: [Int], side: Double) -> Double {
            guard !indexes.isEmpty else { return .infinity }
            let sum = indexes.reduce(Double(0)) { $0 + areas[$1] }
            guard sum > 0 else { return .infinity }
            let maxArea = areas[indexes.first!]
            let minArea = areas[indexes.last!]
            let s2 = side * side
            let sum2 = sum * sum
            return max((s2 * maxArea) / sum2, sum2 / (s2 * minArea))
        }

        func layoutRow(_ indexes: [Int], into rect: inout CGRect) {
            let rowSum = indexes.reduce(Double(0)) { $0 + areas[$1] }
            guard rowSum > 0 else { return }
            let horizontal = rect.width >= rect.height
            if horizontal {
                let stripWidth = CGFloat(rowSum / Double(rect.height))
                var y = rect.minY
                for i in indexes {
                    let h = CGFloat(areas[i] / Double(stripWidth))
                    let r = CGRect(
                        x: rect.minX, y: y,
                        width: stripWidth, height: h
                    )
                    result.append(PlacedRect(item: sorted[i], rect: r))
                    y += h
                }
                rect = CGRect(
                    x: rect.minX + stripWidth,
                    y: rect.minY,
                    width: max(0, rect.width - stripWidth),
                    height: rect.height
                )
            } else {
                let stripHeight = CGFloat(rowSum / Double(rect.width))
                var x = rect.minX
                for i in indexes {
                    let w = CGFloat(areas[i] / Double(stripHeight))
                    let r = CGRect(
                        x: x, y: rect.minY,
                        width: w, height: stripHeight
                    )
                    result.append(PlacedRect(item: sorted[i], rect: r))
                    x += w
                }
                rect = CGRect(
                    x: rect.minX,
                    y: rect.minY + stripHeight,
                    width: rect.width,
                    height: max(0, rect.height - stripHeight)
                )
            }
        }

        var i = 0
        while i < sorted.count {
            let side = Double(min(remaining.width, remaining.height))
            let withNew = row + [i]
            if row.isEmpty || worst(withNew, side: side) <= worst(row, side: side) {
                row = withNew
                i += 1
            } else {
                layoutRow(row, into: &remaining)
                row = []
                if remaining.width <= 0 || remaining.height <= 0 { break }
            }
        }
        if !row.isEmpty {
            layoutRow(row, into: &remaining)
        }
        return result
    }
}
