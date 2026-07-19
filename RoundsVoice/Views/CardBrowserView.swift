import SwiftUI
import SwiftData

struct CardBrowserView: View {
    @Bindable var deck: Deck
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var scheme
    @State private var searchText = ""
    @State private var filter: CardFilter = .all
    @State private var cardPendingDelete: Card?
    @State private var listViewModel = DeckListViewModel()

    private enum CardFilter: String, CaseIterable, Identifiable {
        case all
        case due

        var id: String { rawValue }

        var title: String {
            switch self {
            case .all: return "All"
            case .due: return "Due"
            }
        }
    }

    private var filteredCards: [Card] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        var cards = deck.cards

        if filter == .due {
            cards = cards.filter(\.isDue)
        }

        if !query.isEmpty {
            cards = cards.filter {
                $0.displayQuestion.localizedCaseInsensitiveContains(query)
                    || $0.spokenAnswer.localizedCaseInsensitiveContains(query)
                    || $0.tags.contains { $0.localizedCaseInsensitiveContains(query) }
            }
        }

        return cards.sorted { lhs, rhs in
            if lhs.isDue != rhs.isDue { return lhs.isDue && !rhs.isDue }
            return lhs.dueDate < rhs.dueDate
        }
    }

    /// Cap the visible list for huge AnKing imports; search narrows the set.
    private var visibleCards: [Card] {
        Array(filteredCards.prefix(searchText.isEmpty ? 250 : 400))
    }

    var body: some View {
        ZStack {
            AtmosphereBackground(intensity: 0.55)

            VStack(spacing: 0) {
                filterBar
                    .padding(.horizontal, RVTheme.Spacing.lg)
                    .padding(.vertical, RVTheme.Spacing.sm)

                if deck.cards.isEmpty {
                    emptyState
                } else if visibleCards.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(visibleCards, id: \.id) { card in
                            CardBrowserRow(card: card)
                                .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .contextMenu {
                                    Button("Delete Card", systemImage: "trash", role: .destructive) {
                                        cardPendingDelete = card
                                    }
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        cardPendingDelete = card
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }

                        if filteredCards.count > visibleCards.count {
                            Text("Showing \(visibleCards.count) of \(filteredCards.count). Search to narrow.")
                                .font(RVTheme.Typography.caption)
                                .foregroundStyle(.tertiary)
                                .frame(maxWidth: .infinity)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
        }
        .navigationTitle("Cards")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search question or answer")
        .toolbarBackground(.hidden, for: .navigationBar)
        .confirmationDialog(
            "Delete this card?",
            isPresented: Binding(
                get: { cardPendingDelete != nil },
                set: { if !$0 { cardPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Card", role: .destructive) {
                if let card = cardPendingDelete {
                    listViewModel.deleteCard(card, context: modelContext)
                }
                cardPendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                cardPendingDelete = nil
            }
        } message: {
            Text("This only removes it from Rounds Voice — your Anki collection is unchanged.")
        }
    }

    private var filterBar: some View {
        HStack {
            Picker("Filter", selection: $filter) {
                ForEach(CardFilter.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)

            Text("\(filteredCards.count)")
                .font(RVTheme.Typography.monoStat)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 36, alignment: .trailing)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: RVTheme.Spacing.sm) {
            Text("No cards in this deck")
                .font(RVTheme.Typography.title)
            Text("Import an Anki package or reload sample decks from Home.")
                .font(RVTheme.Typography.bodySoft)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(RVTheme.Spacing.lg)
    }
}

private struct CardBrowserRow: View {
    let card: Card
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(card.cardType == .cloze ? "CLOZE" : "BASIC")
                    .font(RVTheme.Typography.overline)
                    .tracking(1.2)
                    .foregroundStyle(RVTheme.seafoam)
                if card.isDue {
                    Text("DUE")
                        .font(RVTheme.Typography.overline)
                        .tracking(1.0)
                        .foregroundStyle(RVTheme.copper)
                }
                Spacer()
            }

            Text(card.displayQuestion)
                .font(RVTheme.Typography.body)
                .foregroundStyle(.primary)
                .lineLimit(4)

            Text(card.spokenAnswer)
                .font(RVTheme.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(scheme == .dark ? Color.white.opacity(0.04) : Color.white.opacity(0.5))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(RVTheme.hairline, lineWidth: 1)
                }
        }
    }
}
