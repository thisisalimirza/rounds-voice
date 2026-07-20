import Foundation
import SwiftData

/// Fast, paged card access — never materialize `deck.cards` for large decks.
enum CardQuery {
    enum BrowserFilter: String, CaseIterable, Identifiable {
        case all
        case due
        case suspended

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All"
            case .due: return "Due"
            case .suspended: return "Suspended"
            }
        }
    }

    /// Search syntax:
    /// - plain substring (default)
    /// - wildcards with `*` / `?` (near-regex)
    /// - full regex with prefix `re:`
    enum SearchMode: Equatable, Sendable {
        case substring(String)
        case wildcard(NSRegularExpression)
        case regex(NSRegularExpression)

        static func parse(_ raw: String) -> SearchMode? {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }

            if trimmed.lowercased().hasPrefix("re:") {
                let pattern = String(trimmed.dropFirst(3))
                guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                    return .substring(trimmed.lowercased())
                }
                return .regex(regex)
            }

            if trimmed.contains("*") || trimmed.contains("?") {
                // Near-regex: `*` / `?` match anywhere in the blob (Anki-style browse).
                let escaped = NSRegularExpression.escapedPattern(for: trimmed)
                    .replacingOccurrences(of: "\\*", with: ".*")
                    .replacingOccurrences(of: "\\?", with: ".")
                if let regex = try? NSRegularExpression(
                    pattern: escaped,
                    options: [.caseInsensitive]
                ) {
                    return .wildcard(regex)
                }
            }

            return .substring(trimmed.lowercased())
        }

        func matches(_ blob: String) -> Bool {
            switch self {
            case .substring(let needle):
                return blob.contains(needle)
            case .wildcard(let regex), .regex(let regex):
                let range = NSRange(blob.startIndex..<blob.endIndex, in: blob)
                return regex.firstMatch(in: blob, options: [], range: range) != nil
            }
        }

        /// Cheap SwiftData prefilter token (first literal run) to shrink candidates before regex.
        var prefilterToken: String? {
            switch self {
            case .substring(let s):
                return s.count >= 2 ? s : nil
            case .wildcard, .regex:
                return nil
            }
        }
    }

    struct Page: Sendable {
        var cards: [Card]
        var totalMatching: Int
    }

    static func fetchPage(
        deckID: UUID,
        filter: BrowserFilter,
        search: String,
        offset: Int,
        limit: Int,
        context: ModelContext,
        studyFilter: StudyFilter = StudyFilter()
    ) throws -> Page {
        if !studyFilter.isEmpty {
            return try fetchPageWithTags(
                deckID: deckID,
                filter: filter,
                search: search,
                studyFilter: studyFilter,
                offset: offset,
                limit: limit,
                context: context
            )
        }

        let mode = SearchMode.parse(search)
        let needsInMemory = {
            guard let mode else { return false }
            if case .substring = mode { return false }
            return true
        }()

        if needsInMemory, let mode {
            return try fetchPageInMemory(
                deckID: deckID,
                filter: filter,
                mode: mode,
                offset: offset,
                limit: limit,
                context: context
            )
        }

        return try fetchPagePredicate(
            deckID: deckID,
            filter: filter,
            substring: mode.flatMap { if case .substring(let s) = $0 { return s } else { return nil } },
            offset: offset,
            limit: limit,
            context: context
        )
    }

    /// All card IDs matching the current browse filters (not just the loaded page).
    static func fetchMatchingIDs(
        deckID: UUID,
        filter: BrowserFilter,
        search: String,
        context: ModelContext,
        studyFilter: StudyFilter = StudyFilter()
    ) throws -> [UUID] {
        if !studyFilter.isEmpty {
            return try collectMatchingIDsWithTags(
                deckID: deckID,
                filter: filter,
                search: search,
                studyFilter: studyFilter,
                context: context
            )
        }

        let mode = SearchMode.parse(search)
        let needsInMemory = {
            guard let mode else { return false }
            if case .substring = mode { return false }
            return true
        }()

        if needsInMemory, let mode {
            return try collectMatchingIDsInMemory(
                deckID: deckID,
                filter: filter,
                mode: mode,
                context: context
            )
        }

        let substring = mode.flatMap { if case .substring(let s) = $0 { return s } else { return nil } }
        return try collectMatchingIDsPredicate(
            deckID: deckID,
            filter: filter,
            substring: substring,
            context: context
        )
    }

    private static func fetchPagePredicate(
        deckID: UUID,
        filter: BrowserFilter,
        substring: String?,
        offset: Int,
        limit: Int,
        context: ModelContext
    ) throws -> Page {
        let now = Date.now
        let hasSearch = !(substring ?? "").isEmpty
        let query = substring ?? ""

        let predicate: Predicate<Card>
        switch filter {
        case .all:
            if hasSearch {
                predicate = #Predicate<Card> {
                    $0.deck?.id == deckID && $0.searchBlob.contains(query)
                }
            } else {
                predicate = #Predicate<Card> {
                    $0.deck?.id == deckID
                }
            }
        case .due:
            if hasSearch {
                predicate = #Predicate<Card> {
                    $0.deck?.id == deckID
                        && $0.isSuspended == false
                        && $0.dueDate <= now
                        && $0.searchBlob.contains(query)
                }
            } else {
                predicate = #Predicate<Card> {
                    $0.deck?.id == deckID
                        && $0.isSuspended == false
                        && $0.dueDate <= now
                }
            }
        case .suspended:
            if hasSearch {
                predicate = #Predicate<Card> {
                    $0.deck?.id == deckID
                        && $0.isSuspended == true
                        && $0.searchBlob.contains(query)
                }
            } else {
                predicate = #Predicate<Card> {
                    $0.deck?.id == deckID && $0.isSuspended == true
                }
            }
        }

        var countDescriptor = FetchDescriptor<Card>(predicate: predicate)
        let totalMatching = try context.fetchCount(countDescriptor)

        var pageDescriptor = FetchDescriptor<Card>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.dueDate)]
        )
        pageDescriptor.fetchOffset = max(0, offset)
        pageDescriptor.fetchLimit = max(1, limit)

        let cards = try context.fetch(pageDescriptor)
        return Page(cards: cards, totalMatching: totalMatching)
    }

    private static func collectMatchingIDsPredicate(
        deckID: UUID,
        filter: BrowserFilter,
        substring: String?,
        context: ModelContext
    ) throws -> [UUID] {
        let now = Date.now
        let hasSearch = !(substring ?? "").isEmpty
        let query = substring ?? ""

        let predicate: Predicate<Card>
        switch filter {
        case .all:
            if hasSearch {
                predicate = #Predicate<Card> {
                    $0.deck?.id == deckID && $0.searchBlob.contains(query)
                }
            } else {
                predicate = #Predicate<Card> {
                    $0.deck?.id == deckID
                }
            }
        case .due:
            if hasSearch {
                predicate = #Predicate<Card> {
                    $0.deck?.id == deckID
                        && $0.isSuspended == false
                        && $0.dueDate <= now
                        && $0.searchBlob.contains(query)
                }
            } else {
                predicate = #Predicate<Card> {
                    $0.deck?.id == deckID
                        && $0.isSuspended == false
                        && $0.dueDate <= now
                }
            }
        case .suspended:
            if hasSearch {
                predicate = #Predicate<Card> {
                    $0.deck?.id == deckID
                        && $0.isSuspended == true
                        && $0.searchBlob.contains(query)
                }
            } else {
                predicate = #Predicate<Card> {
                    $0.deck?.id == deckID && $0.isSuspended == true
                }
            }
        }

        var descriptor = FetchDescriptor<Card>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.dueDate)]
        )
        let cards = try context.fetch(descriptor)
        return cards.map(\.id)
    }

    /// Wildcard / regex: scan in batches so we never load 40k cards at once into a List.
    private static func fetchPageInMemory(
        deckID: UUID,
        filter: BrowserFilter,
        mode: SearchMode,
        offset: Int,
        limit: Int,
        context: ModelContext
    ) throws -> Page {
        let now = Date.now
        let basePredicate: Predicate<Card>
        switch filter {
        case .all:
            basePredicate = #Predicate<Card> { $0.deck?.id == deckID }
        case .due:
            basePredicate = #Predicate<Card> {
                $0.deck?.id == deckID && $0.isSuspended == false && $0.dueDate <= now
            }
        case .suspended:
            basePredicate = #Predicate<Card> {
                $0.deck?.id == deckID && $0.isSuspended == true
            }
        }

        var matched: [Card] = []
        var scanOffset = 0
        let batchSize = 500
        while true {
            var descriptor = FetchDescriptor<Card>(
                predicate: basePredicate,
                sortBy: [SortDescriptor(\.dueDate)]
            )
            descriptor.fetchOffset = scanOffset
            descriptor.fetchLimit = batchSize
            let batch = try context.fetch(descriptor)
            if batch.isEmpty { break }
            for card in batch where mode.matches(card.searchBlob) {
                matched.append(card)
            }
            scanOffset += batch.count
            if batch.count < batchSize { break }
            // Soft cap scan for pathological regex on huge decks — still returns matches found.
            if scanOffset >= 20_000 { break }
        }

        let total = matched.count
        let start = min(max(0, offset), total)
        let end = min(start + max(1, limit), total)
        let page = start < end ? Array(matched[start..<end]) : []
        return Page(cards: page, totalMatching: total)
    }

    private static func collectMatchingIDsInMemory(
        deckID: UUID,
        filter: BrowserFilter,
        mode: SearchMode,
        context: ModelContext
    ) throws -> [UUID] {
        let now = Date.now
        let basePredicate: Predicate<Card>
        switch filter {
        case .all:
            basePredicate = #Predicate<Card> { $0.deck?.id == deckID }
        case .due:
            basePredicate = #Predicate<Card> {
                $0.deck?.id == deckID && $0.isSuspended == false && $0.dueDate <= now
            }
        case .suspended:
            basePredicate = #Predicate<Card> {
                $0.deck?.id == deckID && $0.isSuspended == true
            }
        }

        var ids: [UUID] = []
        var scanOffset = 0
        let batchSize = 500
        while true {
            var descriptor = FetchDescriptor<Card>(
                predicate: basePredicate,
                sortBy: [SortDescriptor(\.dueDate)]
            )
            descriptor.fetchOffset = scanOffset
            descriptor.fetchLimit = batchSize
            let batch = try context.fetch(descriptor)
            if batch.isEmpty { break }
            for card in batch where mode.matches(card.searchBlob) {
                ids.append(card.id)
            }
            scanOffset += batch.count
            if batch.count < batchSize { break }
            if scanOffset >= 20_000 { break }
        }
        return ids
    }

    static func fetchDue(
        deckID: UUID,
        limit: Int,
        context: ModelContext,
        studyFilter: StudyFilter = StudyFilter()
    ) throws -> [Card] {
        let now = Date.now
        // Over-fetch so we can drop buried cards + apply tag/sibling filters.
        let fetchCap = max(limit * 4, 80)
        var descriptor = FetchDescriptor<Card>(
            predicate: #Predicate<Card> {
                $0.deck?.id == deckID
                    && $0.isSuspended == false
                    && $0.dueDate <= now
            },
            sortBy: [
                SortDescriptor(\.dueDate),
                SortDescriptor(\.reviewCount)
            ]
        )
        descriptor.fetchLimit = fetchCap
        var cards = try context.fetch(descriptor)
            .filter { !$0.isBuried }

        if !studyFilter.isEmpty {
            cards = cards.filter { TagQuery.cardMatches($0, filter: studyFilter) }
        }

        // If tag filter is sparse, scan further batches.
        if !studyFilter.isEmpty && cards.count < limit {
            var offset = fetchCap
            while cards.count < limit {
                var more = FetchDescriptor<Card>(
                    predicate: #Predicate<Card> {
                        $0.deck?.id == deckID
                            && $0.isSuspended == false
                            && $0.dueDate <= now
                    },
                    sortBy: [
                        SortDescriptor(\.dueDate),
                        SortDescriptor(\.reviewCount)
                    ]
                )
                more.fetchOffset = offset
                more.fetchLimit = 200
                let batch = try context.fetch(more)
                if batch.isEmpty { break }
                let matched = batch.filter { !$0.isBuried && TagQuery.cardMatches($0, filter: studyFilter) }
                cards.append(contentsOf: matched)
                offset += batch.count
                if batch.count < 200 { break }
            }
        }

        return Array(cards.prefix(max(1, limit)))
    }

    static func fetchUpcoming(
        deckID: UUID,
        limit: Int,
        context: ModelContext,
        studyFilter: StudyFilter = StudyFilter()
    ) throws -> [Card] {
        var descriptor = FetchDescriptor<Card>(
            predicate: #Predicate<Card> {
                $0.deck?.id == deckID && $0.isSuspended == false
            },
            sortBy: [SortDescriptor(\.dueDate)]
        )
        descriptor.fetchLimit = max(limit * 3, 40)
        var cards = try context.fetch(descriptor).filter { !$0.isBuried }
        if !studyFilter.isEmpty {
            cards = cards.filter { TagQuery.cardMatches($0, filter: studyFilter) }
        }
        return Array(cards.prefix(max(1, limit)))
    }

    /// Sibling cards that share a note key (including `#ordinal` variants).
    static func fetchSiblings(
        noteKey: String,
        deckID: UUID,
        excluding cardID: UUID,
        context: ModelContext
    ) throws -> [Card] {
        let key = noteKey
        var descriptor = FetchDescriptor<Card>(
            predicate: #Predicate<Card> {
                $0.deck?.id == deckID
                    && $0.siblingKey == key
                    && $0.id != cardID
            }
        )
        descriptor.fetchLimit = 64
        return try context.fetch(descriptor)
    }

    /// Tag + optional text search.
    /// Prefer `tagsBlob` SwiftData predicates (indexed contains) — never load the whole deck.
    private static func fetchPageWithTags(
        deckID: UUID,
        filter: BrowserFilter,
        search: String,
        studyFilter: StudyFilter,
        offset: Int,
        limit: Int,
        context: ModelContext
    ) throws -> Page {
        let mode = SearchMode.parse(search)
        let needsRegex = {
            guard let mode else { return false }
            if case .substring = mode { return false }
            return true
        }()

        if !needsRegex,
           let predicate = try? tagBrowsePredicate(
            deckID: deckID,
            filter: filter,
            studyFilter: studyFilter,
            substring: {
                guard case .substring(let s) = mode else { return nil }
                return s
            }()
           ) {
            var countDescriptor = FetchDescriptor<Card>(predicate: predicate)
            let totalMatching = try context.fetchCount(countDescriptor)

            var pageDescriptor = FetchDescriptor<Card>(
                predicate: predicate,
                sortBy: [SortDescriptor(\.dueDate)]
            )
            pageDescriptor.fetchOffset = max(0, offset)
            pageDescriptor.fetchLimit = max(1, limit)
            let cards = try context.fetch(pageDescriptor)
            return Page(cards: cards, totalMatching: totalMatching)
        }

        return try fetchPageWithTagsStreaming(
            deckID: deckID,
            filter: filter,
            mode: mode,
            studyFilter: studyFilter,
            offset: offset,
            limit: limit,
            context: context
        )
    }

    /// Stream a full-deck scan but only retain the requested page window (not all matches).
    private static func fetchPageWithTagsStreaming(
        deckID: UUID,
        filter: BrowserFilter,
        mode: SearchMode?,
        studyFilter: StudyFilter,
        offset: Int,
        limit: Int,
        context: ModelContext
    ) throws -> Page {
        let now = Date.now
        var matchedCount = 0
        var page: [Card] = []
        page.reserveCapacity(max(1, limit))
        let start = max(0, offset)
        let end = start + max(1, limit)
        var scanOffset = 0
        let batchSize = 500

        // AND / single-tag: first-tag prefilter is safe. OR multi-tag must scan the deck
        // (otherwise cards that only match later tags are never fetched).
        let prefilter = streamingTagPrefilter(deckID: deckID, studyFilter: studyFilter)

        while true {
            var descriptor = FetchDescriptor<Card>(
                predicate: prefilter,
                sortBy: [SortDescriptor(\.dueDate)]
            )
            descriptor.fetchOffset = scanOffset
            descriptor.fetchLimit = batchSize
            let batch = try context.fetch(descriptor)
            if batch.isEmpty { break }

            for card in batch {
                switch filter {
                case .all: break
                case .due:
                    guard !card.isSuspended, !card.isBuried, card.dueDate <= now else { continue }
                case .suspended:
                    guard card.isSuspended else { continue }
                }
                guard TagQuery.cardMatches(card, filter: studyFilter) else { continue }
                if let mode, !mode.matches(card.searchBlob) { continue }

                if matchedCount >= start && matchedCount < end {
                    page.append(card)
                }
                matchedCount += 1
            }

            scanOffset += batch.count
            if batch.count < batchSize { break }
        }

        return Page(cards: page, totalMatching: matchedCount)
    }

    /// Safe DB prefilter for streaming tag scans.
    private static func streamingTagPrefilter(
        deckID: UUID,
        studyFilter: StudyFilter
    ) -> Predicate<Card> {
        let canNarrow =
            studyFilter.tags.count == 1
            || (studyFilter.tags.count > 1 && studyFilter.matchMode == .and)
        guard canNarrow, let first = studyFilter.tags.first else {
            return #Predicate<Card> { $0.deck?.id == deckID }
        }
        let needles = TagQuery.tagsBlobNeedles(for: first)
        let exact = needles.exact
        let prefix = needles.prefix
        return #Predicate<Card> {
            $0.deck?.id == deckID
                && ($0.tagsBlob.contains(exact) || $0.tagsBlob.contains(prefix))
        }
    }

    private static func collectMatchingIDsWithTags(
        deckID: UUID,
        filter: BrowserFilter,
        search: String,
        studyFilter: StudyFilter,
        context: ModelContext
    ) throws -> [UUID] {
        let mode = SearchMode.parse(search)
        let needsRegex = {
            guard let mode else { return false }
            if case .substring = mode { return false }
            return true
        }()

        if !needsRegex,
           let predicate = try? tagBrowsePredicate(
            deckID: deckID,
            filter: filter,
            studyFilter: studyFilter,
            substring: {
                guard case .substring(let s) = mode else { return nil }
                return s
            }()
           ) {
            var descriptor = FetchDescriptor<Card>(
                predicate: predicate,
                sortBy: [SortDescriptor(\.dueDate)]
            )
            return try context.fetch(descriptor).map(\.id)
        }

        return try collectMatchingIDsStreaming(
            deckID: deckID,
            filter: filter,
            mode: mode,
            studyFilter: studyFilter,
            context: context
        )
    }

    private static func collectMatchingIDsStreaming(
        deckID: UUID,
        filter: BrowserFilter,
        mode: SearchMode?,
        studyFilter: StudyFilter,
        context: ModelContext
    ) throws -> [UUID] {
        let now = Date.now
        var ids: [UUID] = []
        var scanOffset = 0
        let batchSize = 500
        let prefilter = streamingTagPrefilter(deckID: deckID, studyFilter: studyFilter)

        while true {
            var descriptor = FetchDescriptor<Card>(
                predicate: prefilter,
                sortBy: [SortDescriptor(\.dueDate)]
            )
            descriptor.fetchOffset = scanOffset
            descriptor.fetchLimit = batchSize
            let batch = try context.fetch(descriptor)
            if batch.isEmpty { break }

            for card in batch {
                switch filter {
                case .all: break
                case .due:
                    guard !card.isSuspended, !card.isBuried, card.dueDate <= now else { continue }
                case .suspended:
                    guard card.isSuspended else { continue }
                }
                guard TagQuery.cardMatches(card, filter: studyFilter) else { continue }
                if let mode, !mode.matches(card.searchBlob) { continue }
                ids.append(card.id)
            }

            scanOffset += batch.count
            if batch.count < batchSize { break }
        }
        return ids
    }

    /// Apply work to matching cards in chunks (for Select-All batch suspend/delete/move).
    /// - Parameter removesFromMatchSet: When true (delete/move, or suspend while filtered to Due),
    ///   always re-fetch from offset 0 so shifted rows aren't skipped. When false (e.g. suspend
    ///   while browsing All), advance the offset so the same cards aren't reprocessed.
    @MainActor
    static func processMatching(
        deckID: UUID,
        filter: BrowserFilter,
        search: String,
        studyFilter: StudyFilter,
        context: ModelContext,
        batchSize: Int = 150,
        removesFromMatchSet: Bool = true,
        handle: ([Card]) throws -> Void
    ) async throws -> Int {
        let mode = SearchMode.parse(search)
        let needsRegex = {
            guard let mode else { return false }
            if case .substring = mode { return false }
            return true
        }()

        var processed = 0

        if !needsRegex,
           let predicate = try? tagBrowsePredicate(
            deckID: deckID,
            filter: filter,
            studyFilter: studyFilter,
            substring: {
                guard case .substring(let s) = mode else { return nil }
                return s
            }()
           ) {
            var offset = 0
            while true {
                var descriptor = FetchDescriptor<Card>(
                    predicate: predicate,
                    sortBy: [SortDescriptor(\.dueDate)]
                )
                descriptor.fetchOffset = removesFromMatchSet ? 0 : offset
                descriptor.fetchLimit = batchSize
                let batch = try context.fetch(descriptor)
                if batch.isEmpty { break }
                try handle(batch)
                processed += batch.count
                if !removesFromMatchSet {
                    offset += batch.count
                }
                if batch.count < batchSize { break }
                await Task.yield()
            }
            return processed
        }

        // Fallback (regex / 3+ tags): resolve IDs once, then mutate in chunks.
        let ids = try collectMatchingIDsStreaming(
            deckID: deckID,
            filter: filter,
            mode: mode,
            studyFilter: studyFilter,
            context: context
        )
        var index = 0
        while index < ids.count {
            let end = min(index + batchSize, ids.count)
            let slice = Set(ids[index..<end])
            let batch = try fetchCards(ids: slice, context: context)
            if !batch.isEmpty {
                try handle(batch)
                processed += batch.count
            }
            index = end
            await Task.yield()
        }
        return processed
    }

    /// Fast SwiftData predicate for exactly one tag (+ status / substring).
    /// Multi-tag filters use the streaming path with a first-tag `tagsBlob` prefilter.
    /// Each `#Predicate` lives in its own tiny function so the type-checker doesn't time out.
    private static func tagBrowsePredicate(
        deckID: UUID,
        filter: BrowserFilter,
        studyFilter: StudyFilter,
        substring: String?
    ) throws -> Predicate<Card> {
        let tags = studyFilter.tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard tags.count == 1, let tag = tags.first else {
            throw TagPredicateError.unsupportedTagCount
        }

        let query = substring ?? ""
        let needles = TagQuery.tagsBlobNeedles(for: tag)
        let exact = needles.exact
        let prefix = needles.prefix
        let hasSearch = !query.isEmpty

        switch filter {
        case .all:
            return hasSearch
                ? predicateAllTagSearch(deckID: deckID, exact: exact, prefix: prefix, query: query)
                : predicateAllTag(deckID: deckID, exact: exact, prefix: prefix)
        case .due:
            return hasSearch
                ? predicateDueTagSearch(deckID: deckID, exact: exact, prefix: prefix, query: query)
                : predicateDueTag(deckID: deckID, exact: exact, prefix: prefix)
        case .suspended:
            return hasSearch
                ? predicateSuspendedTagSearch(deckID: deckID, exact: exact, prefix: prefix, query: query)
                : predicateSuspendedTag(deckID: deckID, exact: exact, prefix: prefix)
        }
    }

    private static func predicateAllTag(
        deckID: UUID,
        exact: String,
        prefix: String
    ) -> Predicate<Card> {
        #Predicate<Card> {
            $0.deck?.id == deckID
                && ($0.tagsBlob.contains(exact) || $0.tagsBlob.contains(prefix))
        }
    }

    private static func predicateAllTagSearch(
        deckID: UUID,
        exact: String,
        prefix: String,
        query: String
    ) -> Predicate<Card> {
        #Predicate<Card> {
            $0.deck?.id == deckID
                && ($0.tagsBlob.contains(exact) || $0.tagsBlob.contains(prefix))
                && $0.searchBlob.contains(query)
        }
    }

    private static func predicateDueTag(
        deckID: UUID,
        exact: String,
        prefix: String
    ) -> Predicate<Card> {
        let now = Date.now
        return #Predicate<Card> {
            $0.deck?.id == deckID
                && $0.isSuspended == false
                && $0.dueDate <= now
                && ($0.tagsBlob.contains(exact) || $0.tagsBlob.contains(prefix))
        }
    }

    private static func predicateDueTagSearch(
        deckID: UUID,
        exact: String,
        prefix: String,
        query: String
    ) -> Predicate<Card> {
        let now = Date.now
        return #Predicate<Card> {
            $0.deck?.id == deckID
                && $0.isSuspended == false
                && $0.dueDate <= now
                && ($0.tagsBlob.contains(exact) || $0.tagsBlob.contains(prefix))
                && $0.searchBlob.contains(query)
        }
    }

    private static func predicateSuspendedTag(
        deckID: UUID,
        exact: String,
        prefix: String
    ) -> Predicate<Card> {
        #Predicate<Card> {
            $0.deck?.id == deckID
                && $0.isSuspended == true
                && ($0.tagsBlob.contains(exact) || $0.tagsBlob.contains(prefix))
        }
    }

    private static func predicateSuspendedTagSearch(
        deckID: UUID,
        exact: String,
        prefix: String,
        query: String
    ) -> Predicate<Card> {
        #Predicate<Card> {
            $0.deck?.id == deckID
                && $0.isSuspended == true
                && ($0.tagsBlob.contains(exact) || $0.tagsBlob.contains(prefix))
                && $0.searchBlob.contains(query)
        }
    }

    private enum TagPredicateError: Error {
        case unsupportedTagCount
    }

    /// Resolve cards by ID via direct lookups (never scan the whole deck).
    static func fetchCards(
        ids: Set<UUID>,
        context: ModelContext,
        deckID: UUID? = nil
    ) throws -> [Card] {
        _ = deckID
        guard !ids.isEmpty else { return [] }

        var result: [Card] = []
        result.reserveCapacity(ids.count)
        for id in ids {
            var descriptor = FetchDescriptor<Card>(predicate: #Predicate<Card> { $0.id == id })
            descriptor.fetchLimit = 1
            if let card = try context.fetch(descriptor).first {
                result.append(card)
            }
        }
        return result
    }
}

/// Maintains denormalized deck counters so Home never loads 40k cards.
enum DeckStats {
    static func recomputeCounts(for deck: Deck, context: ModelContext) throws {
        let deckID = deck.id
        let now = Date.now

        var all = FetchDescriptor<Card>(predicate: #Predicate<Card> { $0.deck?.id == deckID })
        let cardCount = try context.fetchCount(all)

        // Sibling bury pushes dueDate forward, so buried cards fall out of this predicate.
        var due = FetchDescriptor<Card>(
            predicate: #Predicate<Card> {
                $0.deck?.id == deckID && $0.isSuspended == false && $0.dueDate <= now
            }
        )
        let dueCount = try context.fetchCount(due)

        var suspended = FetchDescriptor<Card>(
            predicate: #Predicate<Card> {
                $0.deck?.id == deckID && $0.isSuspended == true
            }
        )
        let suspendedCount = try context.fetchCount(suspended)

        deck.cardCount = cardCount
        deck.dueCount = dueCount
        deck.suspendedCount = suspendedCount
        deck.countsRefreshedAt = .now
    }

    static func refreshStaleCounts(context: ModelContext, olderThan hours: Double = 6) {
        do {
            let decks = try context.fetch(FetchDescriptor<Deck>())
            let cutoff = Date.now.addingTimeInterval(-hours * 3600)
            for deck in decks {
                let needs =
                    deck.countsRefreshedAt == nil
                    || (deck.countsRefreshedAt ?? .distantPast) < cutoff
                    || (deck.cardCount == 0 && deck.source != .sample)
                guard needs else { continue }
                try recomputeCounts(for: deck, context: context)
            }
            try context.save()
        } catch {
            // Best-effort.
        }
    }

    @MainActor
    static func backfillSearchBlobs(context: ModelContext) async {
        do {
            let decks = try context.fetch(FetchDescriptor<Deck>())
            for deck in decks {
                try await backfillSearchBlobs(deckID: deck.id, context: context)
            }
        } catch {
            // Best-effort.
        }
    }

    @MainActor
    static func backfillSearchBlobs(deckID: UUID, context: ModelContext) async throws {
        // Backfill searchBlob / tagsBlob / siblingKey for cards imported before those fields existed.
        // Save infrequently — per-batch saves on a ~100MB store trigger huge WAL checkpoints.
        let previousAutosave = context.autosaveEnabled
        context.autosaveEnabled = false
        defer { context.autosaveEnabled = previousAutosave }

        var descriptor = FetchDescriptor<Card>(
            predicate: #Predicate<Card> {
                $0.deck?.id == deckID
                    && ($0.searchBlob == "" || $0.siblingKey == "" || $0.tagsBlob == "")
            }
        )
        descriptor.fetchLimit = 500
        var dirty = 0
        while true {
            let batch = try context.fetch(descriptor)
            if batch.isEmpty { break }
            for card in batch {
                card.refreshSearchBlob()
            }
            dirty += batch.count
            // Checkpoint at most every ~2k rows during backfill.
            if dirty >= 2_000 {
                try context.save()
                dirty = 0
            }
            await Task.yield()
            if batch.count < 500 { break }
        }
        if dirty > 0 {
            try context.save()
        }
    }

    static func noteInserted(card: Card, into deck: Deck) {
        deck.cardCount += 1
        if card.isSuspended {
            deck.suspendedCount += 1
        } else if card.dueDate <= .now {
            deck.dueCount += 1
        }
    }

    static func noteDeleted(card: Card, from deck: Deck) {
        deck.cardCount = max(0, deck.cardCount - 1)
        if card.isSuspended {
            deck.suspendedCount = max(0, deck.suspendedCount - 1)
        } else if card.dueDate <= .now {
            deck.dueCount = max(0, deck.dueCount - 1)
        }
    }

    static func noteSuspensionChanged(card: Card, wasSuspended: Bool) {
        guard let deck = card.deck, wasSuspended != card.isSuspended else { return }
        let isDue = card.dueDate <= .now
        if card.isSuspended {
            deck.suspendedCount += 1
            if isDue { deck.dueCount = max(0, deck.dueCount - 1) }
        } else {
            deck.suspendedCount = max(0, deck.suspendedCount - 1)
            if isDue { deck.dueCount += 1 }
        }
        deck.updatedAt = .now
    }

    static func noteReviewScheduled(card: Card, wasDue: Bool) {
        guard let deck = card.deck else { return }
        let isDue = card.isDue
        if wasDue && !isDue {
            deck.dueCount = max(0, deck.dueCount - 1)
        } else if !wasDue && isDue {
            deck.dueCount += 1
        }
    }

    static func noteMoved(card: Card, from oldDeck: Deck?, to newDeck: Deck) {
        if let oldDeck, oldDeck.id != newDeck.id {
            noteDeleted(card: card, from: oldDeck)
        }
        noteInserted(card: card, into: newDeck)
    }
}
