import SwiftUI
import SwiftData

/// Hierarchical tag picker for the unified deck browser.
struct TagFilterSheet: View {
    let deck: Deck
    var initialFilter: StudyFilter
    var onApply: (StudyFilter) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var scheme

    @State private var allTags: [TagCount] = []
    @State private var tree: [TagTreeNode] = []
    @State private var searchText = ""
    @State private var selected: Set<String> = []
    @State private var matchMode: TagMatchMode = .and
    @State private var isLoading = true
    @State private var expanded: Set<String> = []
    @State private var filterTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ZStack {
                AtmosphereBackground(intensity: 0.45)

                VStack(spacing: 0) {
                    Picker("Match", selection: $matchMode) {
                        ForEach(TagMatchMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, RVTheme.Spacing.lg)
                    .padding(.top, RVTheme.Spacing.sm)

                    Text(matchMode.detail)
                        .font(RVTheme.Typography.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, RVTheme.Spacing.lg)
                        .padding(.top, 6)
                        .padding(.bottom, 8)

                    if !selected.isEmpty {
                        selectedChipRow
                            .padding(.horizontal, RVTheme.Spacing.lg)
                            .padding(.bottom, 8)
                    }

                    if isLoading && allTags.isEmpty {
                        ProgressView("Scanning tags…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if tree.isEmpty {
                        ContentUnavailableView(
                            searchText.isEmpty ? "No tags in this deck" : "No matching tags",
                            systemImage: "tag.slash",
                            description: Text(searchText.isEmpty
                                ? "Import an AnKing package or add tags when editing cards."
                                : "Try a shorter search.")
                        )
                    } else {
                        List {
                            ForEach(tree) { node in
                                TagTreeOutlineRow(
                                    node: node,
                                    depth: 0,
                                    selected: $selected,
                                    expanded: $expanded
                                )
                                .listRowInsets(EdgeInsets(top: 2, leading: 12, bottom: 2, trailing: 16))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Filter tags")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !selected.isEmpty {
                        Button("Clear") { selected.removeAll() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") {
                        onApply(StudyFilter(tags: Array(selected).sorted(), matchMode: matchMode))
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
            .task {
                selected = Set(initialFilter.tags)
                matchMode = initialFilter.matchMode
                await loadCatalogOnce()
            }
            .onChange(of: searchText) { _, _ in scheduleFilter() }
        }
    }

    private var selectedChipRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(selected).sorted(), id: \.self) { tag in
                    Button {
                        selected.remove(tag)
                    } label: {
                        HStack(spacing: 4) {
                            Text(StudyFilter.shortLabel(for: tag))
                                .font(.caption.weight(.semibold))
                            Image(systemName: "xmark")
                                .font(.caption2.weight(.bold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .foregroundStyle(RVTheme.bone)
                        .background(RVTheme.seafoam, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(tag)
                }
            }
        }
    }

    private func scheduleFilter() {
        filterTask?.cancel()
        filterTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            applyFilter()
        }
    }

    @MainActor
    private func applyFilter() {
        let filtered = TagQuery.filterTags(allTags, matching: searchText)
        tree = TagQuery.buildTree(from: filtered)
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            expanded = Set(allPaths(in: tree))
        }
    }

    private func allPaths(in nodes: [TagTreeNode]) -> [String] {
        nodes.flatMap { node in
            [node.path] + allPaths(in: node.children)
        }
    }

    @MainActor
    private func loadCatalogOnce() async {
        isLoading = true
        do {
            await Task.yield()
            allTags = try await TagQuery.aggregateTagsChunked(
                deckID: deck.id,
                context: modelContext
            )
            applyFilter()
            // Expand first level for AnKing-sized trees.
            expanded = Set(tree.map(\.path))
        } catch {
            allTags = []
            tree = []
        }
        isLoading = false
    }
}

private struct TagTreeOutlineRow: View {
    let node: TagTreeNode
    let depth: Int
    @Binding var selected: Set<String>
    @Binding var expanded: Set<String>
    @Environment(\.colorScheme) private var scheme

    private var isOn: Bool { selected.contains(node.path) }
    private var isExpanded: Bool { expanded.contains(node.path) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                if node.children.isEmpty {
                    Color.clear.frame(width: 22, height: 22)
                } else {
                    Button {
                        if isExpanded {
                            expanded.remove(node.path)
                        } else {
                            expanded.insert(node.path)
                        }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
                }

                Button {
                    if isOn {
                        selected.remove(node.path)
                    } else {
                        selected.insert(node.path)
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isOn ? RVTheme.seafoam : Color.secondary.opacity(0.45))

                        Text(node.name)
                            .font(RVTheme.Typography.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        Text("\(node.count)")
                            .font(RVTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 9)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(isOn ? (scheme == .dark ? 0.10 : 0.06) : 0.03))
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(node.path), \(node.count) cards")
            }
            .padding(.leading, CGFloat(depth) * 14)

            if isExpanded {
                ForEach(node.children) { child in
                    TagTreeOutlineRow(
                        node: child,
                        depth: depth + 1,
                        selected: $selected,
                        expanded: $expanded
                    )
                }
            }
        }
    }
}
