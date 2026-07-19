import SwiftUI
import SwiftData

struct CardBrowserView: View {
    @Bindable var deck: Deck
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var scheme
    @State private var searchText = ""
    @State private var filter: CardQuery.BrowserFilter = .all
    @State private var cards: [Card] = []
    @State private var totalMatching = 0
    @State private var isLoading = false
    @State private var cardPendingDelete: Card?
    @State private var cardPendingEdit: Card?
    @State private var listViewModel = DeckListViewModel()
    @State private var reloadTask: Task<Void, Never>?

    private let pageSize = 80

    var body: some View {
        ZStack {
            AtmosphereBackground(intensity: 0.55)

            VStack(spacing: 0) {
                filterBar
                    .padding(.horizontal, RVTheme.Spacing.lg)
                    .padding(.vertical, RVTheme.Spacing.sm)

                if deck.cardCount == 0 {
                    emptyState
                } else if !isLoading && cards.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .foregroundStyle(.secondary)
                } else {
                    List {
                        ForEach(cards, id: \.id) { card in
                            Button {
                                cardPendingEdit = card
                            } label: {
                                CardBrowserRow(card: card)
                            }
                            .buttonStyle(.plain)
                            .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .contextMenu {
                                Button(card.isSuspended ? "Unsuspend" : "Suspend", systemImage: card.isSuspended ? "play.circle" : "pause.circle") {
                                    listViewModel.setSuspended(card, suspended: !card.isSuspended, context: modelContext)
                                    scheduleReload()
                                }
                                Button("Edit", systemImage: "pencil") {
                                    cardPendingEdit = card
                                }
                                Button("Delete Card", systemImage: "trash", role: .destructive) {
                                    cardPendingDelete = card
                                }
                            }
                            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                                Button {
                                    listViewModel.setSuspended(card, suspended: !card.isSuspended, context: modelContext)
                                    scheduleReload()
                                } label: {
                                    Label(
                                        card.isSuspended ? "Unsuspend" : "Suspend",
                                        systemImage: card.isSuspended ? "play.circle" : "pause.circle"
                                    )
                                }
                                .tint(RVTheme.seafoam)
                            }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    cardPendingDelete = card
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    cardPendingEdit = card
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(RVTheme.listening)
                            }
                        }

                        if cards.count < totalMatching {
                            Button {
                                loadMore()
                            } label: {
                                if isLoading {
                                    ProgressView()
                                        .frame(maxWidth: .infinity)
                                } else {
                                    Text("Load more (\(cards.count) of \(totalMatching))")
                                        .font(RVTheme.Typography.headline)
                                        .foregroundStyle(RVTheme.seafoam)
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        } else if totalMatching > 0 {
                            Text("\(totalMatching) cards")
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
        .onAppear { scheduleReload(reset: true) }
        .onChange(of: searchText) { _, _ in scheduleReload(reset: true) }
        .onChange(of: filter) { _, _ in scheduleReload(reset: true) }
        .sheet(item: $cardPendingEdit) { card in
            CardEditView(card: card) { front, back, tags in
                listViewModel.saveCardEdits(card, front: front, back: back, tags: tags, context: modelContext)
                scheduleReload()
            }
        }
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
                    scheduleReload(reset: true)
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
                ForEach(CardQuery.BrowserFilter.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)

            Text("\(totalMatching)")
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

    private func scheduleReload(reset: Bool = false) {
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(for: .milliseconds(reset && !searchText.isEmpty ? 220 : 40))
            guard !Task.isCancelled else { return }
            await reload(reset: true)
        }
    }

    @MainActor
    private func reload(reset: Bool) async {
        isLoading = true
        do {
            let page = try CardQuery.fetchPage(
                deckID: deck.id,
                filter: filter,
                search: searchText,
                offset: 0,
                limit: pageSize,
                context: modelContext
            )
            cards = page.cards
            totalMatching = page.totalMatching
        } catch {
            cards = []
            totalMatching = 0
        }
        isLoading = false
    }

    @MainActor
    private func loadMore() {
        guard !isLoading, cards.count < totalMatching else { return }
        isLoading = true
        do {
            let page = try CardQuery.fetchPage(
                deckID: deck.id,
                filter: filter,
                search: searchText,
                offset: cards.count,
                limit: pageSize,
                context: modelContext
            )
            let existing = Set(cards.map(\.id))
            cards.append(contentsOf: page.cards.filter { !existing.contains($0.id) })
            totalMatching = page.totalMatching
        } catch {
            // Keep current page.
        }
        isLoading = false
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
                if card.isSuspended {
                    Text("SUSPENDED")
                        .font(RVTheme.Typography.overline)
                        .tracking(1.0)
                        .foregroundStyle(.secondary)
                } else if card.isDue {
                    Text("DUE")
                        .font(RVTheme.Typography.overline)
                        .tracking(1.0)
                        .foregroundStyle(RVTheme.copper)
                }
                Spacer()
            }

            Text(card.displayQuestion)
                .font(RVTheme.Typography.body)
                .foregroundStyle(card.isSuspended ? .secondary : .primary)
                .lineLimit(4)

            Text(card.spokenAnswer)
                .font(RVTheme.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(card.isSuspended ? 0.72 : 1)
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
