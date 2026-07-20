import Foundation
import SwiftData

/// Anki-style sibling burial for cloze / same-note cards.
enum SiblingBurial {
    /// Shared note identity used to group sister cards.
    /// Prefers denormalized `siblingKey`; falls back to stripping `#ordinal`.
    static func noteKey(for card: Card) -> String? {
        if !card.siblingKey.isEmpty { return card.siblingKey }
        let key = Card.makeSiblingKey(from: card.ankiNoteId)
        return key.isEmpty ? nil : key
    }

    /// Start of tomorrow in the current calendar — Anki bury until next day.
    static func buryUntilDate(from now: Date = .now, calendar: Calendar = .current) -> Date {
        let startOfToday = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now.addingTimeInterval(86_400)
    }

    /// From a due list, keep at most one card per note (earliest due / lowest review count).
    static func filterQueueRemovingSiblingDuplicates(_ cards: [Card]) -> [Card] {
        var seenKeys = Set<String>()
        var result: [Card] = []
        result.reserveCapacity(cards.count)

        for card in cards {
            guard let key = noteKey(for: card) else {
                result.append(card)
                continue
            }
            if seenKeys.insert(key).inserted {
                result.append(card)
            }
        }
        return result
    }

    /// After reviewing `card`, bury remaining siblings until tomorrow and drop them from `queue`.
    @discardableResult
    static func burySiblings(
        of card: Card,
        queue: inout [Card],
        context: ModelContext,
        now: Date = .now
    ) -> Int {
        guard let key = noteKey(for: card) else { return 0 }
        let until = buryUntilDate(from: now)

        // Drop from in-session queue first.
        queue.removeAll { sibling in
            sibling.id != card.id && noteKey(for: sibling) == key
        }

        // Persist bury for other due siblings in this deck (bounded fetch).
        guard let deckID = card.deck?.id else { return 0 }
        var buried = 0
        do {
            let siblings = try CardQuery.fetchSiblings(
                noteKey: key,
                deckID: deckID,
                excluding: card.id,
                context: context
            )
            for sibling in siblings {
                guard !sibling.isSuspended else { continue }
                let wasDue = sibling.isDue
                sibling.buriedUntil = until
                // Also push dueDate forward so denormalized due counts stay honest.
                if sibling.dueDate < until {
                    sibling.dueDate = until
                }
                sibling.updatedAt = now
                DeckStats.noteReviewScheduled(card: sibling, wasDue: wasDue)
                buried += 1
            }
            if buried > 0 {
                try context.save()
            }
        } catch {
            // Best-effort — queue filter still applied.
        }
        return buried
    }
}
