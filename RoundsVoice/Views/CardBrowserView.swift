import SwiftUI
import SwiftData

struct CardBrowserView: View {
    @Bindable var deck: Deck

    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var scheme
    @Query(sort: \Deck.name) private var allDecks: [Deck]

    @State private var activeStudyFilter: StudyFilter
    @State private var searchText = ""
    @State private var filter: CardQuery.BrowserFilter = .all
    @State private var cards: [Card] = []
    @State private var totalMatching = 0
    @State private var isLoading = false
    @State private var isSelecting = false
    @State private var isWorking = false
    /// Select-all mode: do NOT materialize hundreds of UUIDs into List selection (that hangs UI).
    @State private var selectAllMatching = false
    @State private var selectedIDs: Set<UUID> = []
    @State private var cardPendingDelete: Card?
    @State private var cardPendingEdit: Card?
    @State private var showNewCard = false
    @State private var showMoveSheet = false
    @State private var showBatchDeleteConfirm = false
    @State private var showTagSheet = false
    @State private var showStudySession = false
    @State private var listViewModel = DeckListViewModel()
    @State private var reloadTask: Task<Void, Never>?

    private let pageSize = 80

    init(deck: Deck, studyFilter: StudyFilter = StudyFilter()) {
        self.deck = deck
        _activeStudyFilter = State(initialValue: studyFilter)
    }

    private var searchHint: String {
        if searchText.lowercased().hasPrefix("re:") {
            return "Regex mode"
        }
        if searchText.contains("*") || searchText.contains("?") {
            return "Wildcard mode"
        }
        return "Substring, wildcards, or re:pattern"
    }

    private var selectionCount: Int {
        selectAllMatching ? totalMatching : selectedIDs.count
    }

    private var hasSelection: Bool {
        selectAllMatching || !selectedIDs.isEmpty
    }

    private func isCardSelected(_ id: UUID) -> Bool {
        selectAllMatching || selectedIDs.contains(id)
    }

    var body: some View {
        browserChrome
            .navigationTitle("Browse")
            .navigationBarTitleDisplayMode(.inline)
            // Plain string only — LocalizedStringKey treats *…* as markdown and breaks searchable.
            .searchable(text: $searchText, prompt: "Search, wildcards, or re:regex")
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar { browserToolbar }
            .task(id: deck.id) {
                try? await DeckStats.backfillSearchBlobs(deckID: deck.id, context: modelContext)
                scheduleReload(reset: true)
            }
            .onChange(of: searchText) { _, _ in
                clearSelection()
                scheduleReload(reset: true)
            }
            .onChange(of: filter) { _, _ in
                clearSelection()
                scheduleReload(reset: true)
            }
            .onChange(of: activeStudyFilter) { _, _ in
                clearSelection()
                scheduleReload(reset: true)
            }
            .sheet(isPresented: $showTagSheet) {
                TagFilterSheet(deck: deck, initialFilter: activeStudyFilter) { next in
                    activeStudyFilter = next
                }
            }
            .fullScreenCover(isPresented: $showStudySession) {
                ReviewSessionView(deck: deck, studyFilter: activeStudyFilter)
            }
            .sheet(item: $cardPendingEdit) { card in
                CardEditView(card: card) { front, back, tags in
                    listViewModel.saveCardEdits(card, front: front, back: back, tags: tags, context: modelContext)
                    scheduleReload()
                }
            }
            .sheet(isPresented: $showNewCard) {
                CardEditView(card: nil, isNew: true) { front, back, tags in
                    _ = listViewModel.addCard(to: deck, front: front, back: back, tags: tags, context: modelContext)
                    scheduleReload(reset: true)
                }
            }
            .sheet(isPresented: $showMoveSheet) {
                MoveCardsSheet(
                    decks: allDecks.filter { $0.id != deck.id },
                    count: selectionCount
                ) { destination in
                    Task { await runBatchMove(to: destination) }
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
                Button("Cancel", role: .cancel) { cardPendingDelete = nil }
            } message: {
                Text("Removes it from Rounds Voice only — your Anki collection is unchanged.")
            }
            .confirmationDialog(
                "Delete \(selectionCount) cards?",
                isPresented: $showBatchDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("Delete \(selectionCount) Cards", role: .destructive) {
                    Task { await runBatchDelete() }
                }
                Button("Cancel", role: .cancel) {}
            }
    }

    private var browserChrome: some View {
        ZStack {
            AtmosphereBackground(intensity: 0.55)
            VStack(spacing: 0) {
                filterBar
                    .padding(.horizontal, RVTheme.Spacing.lg)
                    .padding(.vertical, RVTheme.Spacing.sm)
                filterChipRow
                    .padding(.horizontal, RVTheme.Spacing.lg)
                    .padding(.bottom, 6)
                Text(searchHint)
                    .font(RVTheme.Typography.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, RVTheme.Spacing.lg)
                    .padding(.bottom, 6)
                browserListArea
                if isSelecting {
                    selectionBar
                }
            }
        }
    }

    @ViewBuilder
    private var browserListArea: some View {
        if deck.cardCount == 0 && cards.isEmpty {
            emptyState
        } else if !isLoading && cards.isEmpty {
            ContentUnavailableView(
                "No matching cards",
                systemImage: "rectangle.stack",
                description: Text(emptyFilterMessage)
            )
        } else {
            List {
                ForEach(cards, id: \.id) { card in
                    row(for: card)
                }
                loadMoreFooter
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder
    private var loadMoreFooter: some View {
        if cards.count < totalMatching {
            Button {
                loadMore()
            } label: {
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity)
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

    @ToolbarContentBuilder
    private var browserToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                showNewCard = true
            } label: {
                Image(systemName: "plus")
            }
            .accessibilityLabel("Add card")

            Button(isSelecting ? "Done" : "Select") {
                withAnimation {
                    isSelecting.toggle()
                    if !isSelecting { clearSelection() }
                }
            }
        }
    }

    private var emptyFilterMessage: String {
        if !activeStudyFilter.isEmpty || !searchText.isEmpty || filter != .all {
            return "Try clearing tags, search, or the status filter."
        }
        return "No cards match."
    }

    private var filterChipRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button {
                        showTagSheet = true
                    } label: {
                        Label(
                            activeStudyFilter.isEmpty ? "Tags" : "Tags (\(activeStudyFilter.tags.count))",
                            systemImage: "tag"
                        )
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .foregroundStyle(activeStudyFilter.isEmpty ? Color.primary : RVTheme.bone)
                        .background {
                            Capsule().fill(
                                activeStudyFilter.isEmpty
                                    ? Color.primary.opacity(scheme == .dark ? 0.08 : 0.06)
                                    : RVTheme.seafoam
                            )
                        }
                    }
                    .buttonStyle(.plain)

                    if activeStudyFilter.tags.count >= 2 {
                        Button {
                            var next = activeStudyFilter
                            next.matchMode = next.matchMode == .and ? .or : .and
                            activeStudyFilter = next
                        } label: {
                            Text(activeStudyFilter.matchMode == .and ? "Match all" : "Match any")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .foregroundStyle(.primary)
                                .background(Color.primary.opacity(scheme == .dark ? 0.08 : 0.06), in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }

                    ForEach(activeStudyFilter.tags, id: \.self) { tag in
                        Button {
                            var next = activeStudyFilter
                            next.tags.removeAll { $0 == tag }
                            activeStudyFilter = next
                        } label: {
                            HStack(spacing: 4) {
                                Text(StudyFilter.shortLabel(for: tag))
                                    .font(.caption.weight(.semibold))
                                Image(systemName: "xmark")
                                    .font(.caption2.weight(.bold))
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .foregroundStyle(RVTheme.bone)
                            .background(RVTheme.seafoam.opacity(0.85), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(tag)")
                    }

                    if !activeStudyFilter.isEmpty {
                        Button {
                            showStudySession = true
                        } label: {
                            Label("Study", systemImage: "figure.walk.motion")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 7)
                                .foregroundStyle(RVTheme.bone)
                                .background(RVTheme.copper, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            if !activeStudyFilter.isEmpty {
                Text(activeStudyFilter.summary)
                    .font(RVTheme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private func row(for card: Card) -> some View {
        Button {
            if isSelecting {
                toggleSelection(for: card.id)
            } else {
                cardPendingEdit = card
            }
        } label: {
            CardBrowserRow(card: card, isSelected: isCardSelected(card.id) && isSelecting)
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
            Button("Edit", systemImage: "pencil") { cardPendingEdit = card }
            Button("Delete Card", systemImage: "trash", role: .destructive) {
                cardPendingDelete = card
            }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                listViewModel.setSuspended(card, suspended: !card.isSuspended, context: modelContext)
                scheduleReload()
            } label: {
                Label(card.isSuspended ? "Unsuspend" : "Suspend", systemImage: card.isSuspended ? "play.circle" : "pause.circle")
            }
            .tint(RVTheme.seafoam)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) { cardPendingDelete = card } label: {
                Label("Delete", systemImage: "trash")
            }
            Button { cardPendingEdit = card } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(RVTheme.listening)
        }
    }

    private var selectionBar: some View {
        VStack(spacing: 10) {
            HStack {
                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                    Text("Working…")
                        .font(RVTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(selectionSummary)
                        .font(RVTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(selectAllMatching ? "Clear" : "Select All") {
                    if selectAllMatching {
                        clearSelection()
                    } else {
                        // Instant — no ID fetch. Batch actions stream matches by filter.
                        selectedIDs.removeAll()
                        selectAllMatching = true
                    }
                }
                .font(.caption.weight(.semibold))
                .disabled(isWorking || totalMatching == 0)
            }

            HStack(spacing: 10) {
                batchButton("Suspend", systemImage: "pause.circle") {
                    Task { await runBatchSuspend(true) }
                }
                batchButton("Unsuspend", systemImage: "play.circle") {
                    Task { await runBatchSuspend(false) }
                }
                batchButton("Move", systemImage: "folder") {
                    showMoveSheet = true
                }
                .disabled(allDecks.filter { $0.id != deck.id }.isEmpty)
                batchButton("Delete", systemImage: "trash", destructive: true) {
                    showBatchDeleteConfirm = true
                }
            }
        }
        .padding(.horizontal, RVTheme.Spacing.lg)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
    }

    private var selectionSummary: String {
        if !hasSelection {
            return "None selected · \(totalMatching) matching"
        }
        if selectAllMatching {
            return "All \(totalMatching) matching selected"
        }
        return "\(selectedIDs.count) selected · \(totalMatching) matching"
    }

    private func batchButton(
        _ title: String,
        systemImage: String,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                Text(title).font(.caption2.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .foregroundStyle(destructive ? RVTheme.incorrect : RVTheme.seafoam)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(scheme == .dark ? Color.white.opacity(0.06) : Color.white.opacity(0.55))
            }
        }
        .buttonStyle(.plain)
        .disabled(!hasSelection || isWorking)
        .opacity(hasSelection ? 1 : 0.4)
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
            Text("Add a card, import an Anki package, or move cards here from another deck.")
                .font(RVTheme.Typography.bodySoft)
                .foregroundStyle(.secondary)
            Button("Add Card") { showNewCard = true }
                .buttonStyle(.borderedProminent)
                .tint(RVTheme.seafoam)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(RVTheme.Spacing.lg)
    }

    private func scheduleReload(reset: Bool = false) {
        reloadTask?.cancel()
        reloadTask = Task {
            try? await Task.sleep(for: .milliseconds(reset && !searchText.isEmpty ? 220 : 40))
            guard !Task.isCancelled else { return }
            await reload()
        }
    }

    @MainActor
    private func reload() async {
        isLoading = true
        do {
            let page = try CardQuery.fetchPage(
                deckID: deck.id,
                filter: filter,
                search: searchText,
                offset: 0,
                limit: pageSize,
                context: modelContext,
                studyFilter: activeStudyFilter
            )
            cards = page.cards
            totalMatching = page.totalMatching
            // Keep off-page selections (Select All); do not clip to the loaded page.
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
                context: modelContext,
                studyFilter: activeStudyFilter
            )
            let existing = Set(cards.map(\.id))
            cards.append(contentsOf: page.cards.filter { !existing.contains($0.id) })
            totalMatching = page.totalMatching
        } catch {
            // Keep current page.
        }
        isLoading = false
    }

    private func clearSelection() {
        selectAllMatching = false
        selectedIDs.removeAll()
    }

    private func toggleSelection(for id: UUID) {
        if selectAllMatching {
            // Leave "all matching" without materializing every ID — start a small explicit set.
            selectAllMatching = false
            selectedIDs = [id]
            return
        }
        if selectedIDs.contains(id) {
            selectedIDs.remove(id)
        } else {
            selectedIDs.insert(id)
        }
    }

    @MainActor
    private func withBulkSaveDisabled<T>(_ work: () async throws -> T) async rethrows -> T {
        let previous = modelContext.autosaveEnabled
        modelContext.autosaveEnabled = false
        defer { modelContext.autosaveEnabled = previous }
        return try await work()
    }

    @MainActor
    private func runBatchSuspend(_ suspended: Bool) async {
        isWorking = true
        defer { isWorking = false }
        do {
            if selectAllMatching {
                // One WAL checkpoint at the end — not one per chunk (console: 26k-page checkpoints).
                let removes = filter == .due || filter == .suspended
                try await withBulkSaveDisabled {
                    _ = try await CardQuery.processMatching(
                        deckID: deck.id,
                        filter: filter,
                        search: searchText,
                        studyFilter: activeStudyFilter,
                        context: modelContext,
                        batchSize: 500,
                        removesFromMatchSet: removes
                    ) { batch in
                        listViewModel.setSuspended(
                            cards: batch,
                            suspended: suspended,
                            context: modelContext,
                            updateDeckStats: false,
                            save: false
                        )
                    }
                    try DeckStats.recomputeCounts(for: deck, context: modelContext)
                    try modelContext.save()
                }
            } else {
                let selected = try CardQuery.fetchCards(ids: selectedIDs, context: modelContext)
                listViewModel.setSuspended(cards: selected, suspended: suspended, context: modelContext)
            }
            clearSelection()
            isSelecting = false
            scheduleReload(reset: true)
        } catch {
            // Keep selection.
        }
    }

    @MainActor
    private func runBatchMove(to destination: Deck) async {
        isWorking = true
        defer {
            isWorking = false
            showMoveSheet = false
        }
        do {
            if selectAllMatching {
                try await withBulkSaveDisabled {
                    _ = try await CardQuery.processMatching(
                        deckID: deck.id,
                        filter: filter,
                        search: searchText,
                        studyFilter: activeStudyFilter,
                        context: modelContext,
                        batchSize: 500,
                        removesFromMatchSet: true
                    ) { batch in
                        listViewModel.moveCards(
                            batch,
                            to: destination,
                            context: modelContext,
                            updateDeckStats: false,
                            save: false
                        )
                    }
                    try DeckStats.recomputeCounts(for: deck, context: modelContext)
                    try DeckStats.recomputeCounts(for: destination, context: modelContext)
                    try modelContext.save()
                }
            } else {
                let selected = try CardQuery.fetchCards(ids: selectedIDs, context: modelContext)
                listViewModel.moveCards(selected, to: destination, context: modelContext)
            }
            clearSelection()
            isSelecting = false
            scheduleReload(reset: true)
        } catch {
            // Keep selection.
        }
    }

    @MainActor
    private func runBatchDelete() async {
        isWorking = true
        defer { isWorking = false }
        do {
            if selectAllMatching {
                try await withBulkSaveDisabled {
                    _ = try await CardQuery.processMatching(
                        deckID: deck.id,
                        filter: filter,
                        search: searchText,
                        studyFilter: activeStudyFilter,
                        context: modelContext,
                        batchSize: 500,
                        removesFromMatchSet: true
                    ) { batch in
                        listViewModel.deleteCards(
                            batch,
                            context: modelContext,
                            updateDeckStats: false,
                            save: false
                        )
                    }
                    try DeckStats.recomputeCounts(for: deck, context: modelContext)
                    try modelContext.save()
                }
            } else {
                let selected = try CardQuery.fetchCards(ids: selectedIDs, context: modelContext)
                listViewModel.deleteCards(selected, context: modelContext)
            }
            clearSelection()
            isSelecting = false
            scheduleReload(reset: true)
        } catch {
            // Keep selection.
        }
    }
}

private struct CardBrowserRow: View {
    let card: Card
    var isSelected: Bool = false
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
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(RVTheme.seafoam)
                }
            }

            Text(card.displayQuestion)
                .font(RVTheme.Typography.body)
                .foregroundStyle(card.isSuspended ? .secondary : .primary)
                .lineLimit(4)

            Text(card.spokenAnswer)
                .font(RVTheme.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            if !card.tags.isEmpty {
                Text(card.tags.prefix(4).joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(card.isSuspended ? 0.72 : 1)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(scheme == .dark ? Color.white.opacity(0.04) : Color.white.opacity(0.5))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            isSelected ? RVTheme.seafoam.opacity(0.7) : RVTheme.hairline,
                            lineWidth: isSelected ? 2 : 1
                        )
                }
        }
    }
}

struct MoveCardsSheet: View {
    let decks: [Deck]
    let count: Int
    var onPick: (Deck) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(decks, id: \.id) { deck in
                Button {
                    onPick(deck)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(deck.name)
                                .font(RVTheme.Typography.headline)
                            Text("\(deck.cardCount) cards")
                                .font(RVTheme.Typography.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "folder")
                            .foregroundStyle(RVTheme.seafoam)
                    }
                }
            }
            .navigationTitle("Move \(count) cards")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .overlay {
                if decks.isEmpty {
                    ContentUnavailableView(
                        "No other decks",
                        systemImage: "folder.badge.plus",
                        description: Text("Create another deck on Home, then move cards here.")
                    )
                }
            }
        }
    }
}
