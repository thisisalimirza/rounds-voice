import Foundation
import SwiftData

enum TagMatchMode: String, CaseIterable, Identifiable, Sendable {
    case and
    case or

    var id: String { rawValue }

    var title: String {
        switch self {
        case .and: return "Match all"
        case .or: return "Match any"
        }
    }

    var detail: String {
        switch self {
        case .and: return "Card must have every selected tag"
        case .or: return "Card may have any selected tag"
        }
    }
}

struct TagCount: Identifiable, Hashable, Sendable {
    var tag: String
    var count: Int
    /// Precomputed for fast search typing.
    var tagLower: String

    var id: String { tag }

    init(tag: String, count: Int) {
        self.tag = tag
        self.count = count
        self.tagLower = tag.lowercased()
    }
}

/// Study / browse filter built from the tag browser.
struct StudyFilter: Equatable, Sendable {
    var tags: [String] = []
    var matchMode: TagMatchMode = .and

    var isEmpty: Bool { tags.isEmpty }

    var summary: String {
        guard !tags.isEmpty else { return "" }
        let joiner = matchMode == .and ? " + " : " | "
        return tags.joined(separator: joiner)
    }

    /// Short chip label — last segment of a hierarchical tag.
    static func shortLabel(for tag: String) -> String {
        tag.split(separator: "::").last.map(String.init) ?? tag
    }
}

/// Node in an AnKing-style `::` hierarchy.
struct TagTreeNode: Identifiable, Hashable, Sendable {
    var path: String
    var name: String
    var count: Int
    var children: [TagTreeNode]

    var id: String { path }
    var isLeaf: Bool { children.isEmpty }
}

/// Aggregate and filter AnKing-style hyper-tagged decks without loading every card into a List.
enum TagQuery {
    private static let batchSize = 500
    private static let hierarchySeparator = "::"

    /// In-memory filter over a cached catalog — O(tags), never touches SwiftData.
    static func filterTags(_ catalog: [TagCount], matching search: String) -> [TagCount] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return catalog }
        return catalog.filter { $0.tagLower.contains(needle) }
    }

    /// Build a hierarchical tree from a flat tag catalog (`A::B::C`).
    /// Parent counts are the sum of exact tag frequencies under that prefix.
    static func buildTree(from catalog: [TagCount]) -> [TagTreeNode] {
        final class MutableNode {
            let path: String
            let name: String
            var exactCount = 0
            var children: [String: MutableNode] = [:]

            init(path: String, name: String) {
                self.path = path
                self.name = name
            }
        }

        let root = MutableNode(path: "", name: "")

        for item in catalog {
            let segments = item.tag
                .components(separatedBy: hierarchySeparator)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !segments.isEmpty else { continue }

            var current = root
            var pathParts: [String] = []
            for (index, segment) in segments.enumerated() {
                pathParts.append(segment)
                let path = pathParts.joined(separator: hierarchySeparator)
                if current.children[segment] == nil {
                    current.children[segment] = MutableNode(path: path, name: segment)
                }
                current = current.children[segment]!
                if index == segments.count - 1 {
                    current.exactCount = item.count
                }
            }
        }

        func freeze(_ node: MutableNode) -> (nodes: [TagTreeNode], rollup: Int) {
            let childEntries = node.children.values.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            var children: [TagTreeNode] = []
            var childRollup = 0
            for child in childEntries {
                let frozen = freeze(child)
                children.append(contentsOf: frozen.nodes)
                childRollup += frozen.rollup
            }
            let total = node.exactCount + childRollup
            if node.path.isEmpty {
                return (children, total)
            }
            return (
                [TagTreeNode(path: node.path, name: node.name, count: total, children: children)],
                total
            )
        }

        return freeze(root).nodes
    }

    /// True when a card tag equals `selectedPath` or lives under it (`selectedPath::…`).
    static func tagMatchesPath(_ cardTag: String, selectedPath: String) -> Bool {
        let tag = cardTag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let path = selectedPath.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !tag.isEmpty, !path.isEmpty else { return false }
        if tag == path { return true }
        return tag.hasPrefix(path + hierarchySeparator)
    }

    /// Needles for `Card.tagsBlob` predicate / fast string checks (exact + children under path).
    static func tagsBlobNeedles(for path: String) -> (exact: String, prefix: String) {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (
            Card.tagsBlobToken(normalized),
            Card.tagDelimiter + normalized + hierarchySeparator
        )
    }

    static func tagsBlobMatchesPath(_ tagsBlob: String, path: String) -> Bool {
        guard !tagsBlob.isEmpty else { return false }
        let needles = tagsBlobNeedles(for: path)
        return tagsBlob.contains(needles.exact) || tagsBlob.contains(needles.prefix)
    }

    static func tagsBlobMatchesFilter(_ tagsBlob: String, filter: StudyFilter) -> Bool {
        guard !filter.tags.isEmpty else { return true }
        guard !tagsBlob.isEmpty else { return false }
        switch filter.matchMode {
        case .and:
            return filter.tags.allSatisfy { tagsBlobMatchesPath(tagsBlob, path: $0) }
        case .or:
            return filter.tags.contains { tagsBlobMatchesPath(tagsBlob, path: $0) }
        }
    }

    /// Scan a deck's tags in batches and return frequency-sorted unique tags.
    static func aggregateTags(
        deckID: UUID,
        context: ModelContext,
        matching search: String = ""
    ) throws -> [TagCount] {
        let catalog = try aggregateAllTags(deckID: deckID, context: context)
        return filterTags(catalog, matching: search)
    }

    /// Full catalog sorted by frequency (call once per screen, then `filterTags`).
    static func aggregateAllTags(
        deckID: UUID,
        context: ModelContext
    ) throws -> [TagCount] {
        var counts: [String: Int] = [:]
        counts.reserveCapacity(4_096)
        var offset = 0

        while true {
            var descriptor = FetchDescriptor<Card>(
                predicate: #Predicate<Card> { $0.deck?.id == deckID },
                sortBy: [SortDescriptor(\.id)]
            )
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = batchSize
            // Only need tags — still materializes Card but avoids extra sort work in-loop.
            let batch = try context.fetch(descriptor)
            if batch.isEmpty { break }

            for card in batch {
                for tag in card.tags {
                    let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    counts[trimmed, default: 0] += 1
                }
            }

            offset += batch.count
            if batch.count < batchSize { break }
        }

        return counts
            .map { TagCount(tag: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.tag.localizedCaseInsensitiveCompare(rhs.tag) == .orderedAscending
            }
    }

    /// Chunked catalog build that yields between batches so the UI stays responsive.
    @MainActor
    static func aggregateTagsChunked(
        deckID: UUID,
        context: ModelContext
    ) async throws -> [TagCount] {
        var counts: [String: Int] = [:]
        counts.reserveCapacity(4_096)
        var offset = 0

        while true {
            var descriptor = FetchDescriptor<Card>(
                predicate: #Predicate<Card> { $0.deck?.id == deckID },
                sortBy: [SortDescriptor(\.id)]
            )
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = batchSize
            let batch = try context.fetch(descriptor)
            if batch.isEmpty { break }

            for card in batch {
                for tag in card.tags {
                    let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { continue }
                    counts[trimmed, default: 0] += 1
                }
            }

            offset += batch.count
            if batch.count < batchSize { break }
            // Let the run loop breathe so typing / ProgressView stay alive.
            await Task.yield()
        }

        return counts
            .map { TagCount(tag: $0.key, count: $0.value) }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.tag.localizedCaseInsensitiveCompare(rhs.tag) == .orderedAscending
            }
    }

    static func cardMatches(_ card: Card, filter: StudyFilter) -> Bool {
        guard !filter.tags.isEmpty else { return true }
        // Prefer denormalized blob (fast path used by SwiftData predicates too).
        if !card.tagsBlob.isEmpty {
            return tagsBlobMatchesFilter(card.tagsBlob, filter: filter)
        }
        let cardTags = card.tags
        switch filter.matchMode {
        case .and:
            return filter.tags.allSatisfy { path in
                cardTags.contains { tagMatchesPath($0, selectedPath: path) }
            }
        case .or:
            return filter.tags.contains { path in
                cardTags.contains { tagMatchesPath($0, selectedPath: path) }
            }
        }
    }

    /// Count cards matching a multi-tag filter (batched).
    static func countMatching(
        deckID: UUID,
        filter: StudyFilter,
        onlyDue: Bool = false,
        context: ModelContext
    ) throws -> Int {
        var total = 0
        var offset = 0
        let now = Date.now

        while true {
            var descriptor = FetchDescriptor<Card>(
                predicate: #Predicate<Card> { $0.deck?.id == deckID },
                sortBy: [SortDescriptor(\.id)]
            )
            descriptor.fetchOffset = offset
            descriptor.fetchLimit = batchSize
            let batch = try context.fetch(descriptor)
            if batch.isEmpty { break }

            for card in batch {
                if onlyDue {
                    guard !card.isSuspended, !card.isBuried, card.dueDate <= now else { continue }
                }
                if filter.isEmpty || cardMatches(card, filter: filter) {
                    total += 1
                }
            }

            offset += batch.count
            if batch.count < batchSize { break }
        }
        return total
    }
}
