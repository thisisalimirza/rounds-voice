import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var colorScheme
    @Query(sort: \Deck.name) private var decks: [Deck]
    @State private var viewModel = DeckListViewModel()
    @State private var appeared = false
    @State private var showSettings = false
    @State private var settings = AppSettings.shared
    @State private var showImporter = false
    @State private var importViewModel = DeckImportViewModel()
    @State private var deckPendingDelete: Deck?
    @State private var deckPendingRename: Deck?
    @State private var renameText = ""

    private var totalDue: Int {
        decks.reduce(0) { $0 + $1.dueCardCount }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AtmosphereBackground()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {
                        brandHero
                            .rvReveal(index: 0, appeared: appeared)
                            .padding(.top, RVTheme.Spacing.md)

                        if viewModel.isSeeding {
                            ProgressView()
                                .tint(RVTheme.seafoam)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, RVTheme.Spacing.xxl)
                        } else if decks.isEmpty {
                            emptyState
                                .rvReveal(index: 1, appeared: appeared)
                                .padding(.top, RVTheme.Spacing.xl)
                        } else {
                            dueRibbon
                                .rvReveal(index: 1, appeared: appeared)
                                .padding(.top, RVTheme.Spacing.xl)

                            Text("Your decks")
                                .font(RVTheme.Typography.overline)
                                .tracking(1.4)
                                .textCase(.uppercase)
                                .foregroundStyle(.secondary)
                                .padding(.top, RVTheme.Spacing.xl)
                                .rvReveal(index: 2, appeared: appeared)

                            deckList
                                .padding(.top, RVTheme.Spacing.md)
                        }
                    }
                    .padding(.horizontal, RVTheme.Spacing.lg)
                    .padding(.bottom, RVTheme.Spacing.xxl)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 10) {
                        Button {
                            showImporter = true
                        } label: {
                            Image(systemName: "square.and.arrow.down")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 32, height: 32)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                        .accessibilityLabel("Import Anki deck")

                        Button {
                            showSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 32, height: 32)
                                .background(.ultraThinMaterial, in: Circle())
                        }

                        Menu {
                            Button("Import Anki .apkg", systemImage: "square.and.arrow.down") {
                                showImporter = true
                            }
                            Button("Reload Sample Decks", systemImage: "arrow.clockwise") {
                                viewModel.resetSampleDecks(context: modelContext)
                            }
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 32, height: 32)
                                .background(.ultraThinMaterial, in: Circle())
                        }
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(settings: settings)
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.ankiPackage, .ankiColPackage, .data],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    Task {
                        await importViewModel.importPackage(from: url, into: modelContext)
                    }
                case .failure(let error):
                    importViewModel.errorMessage = error.localizedDescription
                }
            }
            .overlay {
                if importViewModel.isImporting {
                    ZStack {
                        Color.black.opacity(0.35).ignoresSafeArea()
                        VStack(spacing: 14) {
                            ProgressView()
                                .tint(RVTheme.seafoam)
                            Text(importViewModel.progressMessage ?? "Importing…")
                                .font(RVTheme.Typography.headline)
                                .foregroundStyle(RVTheme.bone)
                                .multilineTextAlignment(.center)
                        }
                        .padding(28)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                }
            }
            .alert(
                "Import complete",
                isPresented: Binding(
                    get: { importViewModel.successMessage != nil },
                    set: { if !$0 { importViewModel.successMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { importViewModel.successMessage = nil }
            } message: {
                Text(importViewModel.successMessage ?? "")
            }
            .alert(
                "Import failed",
                isPresented: Binding(
                    get: { importViewModel.errorMessage != nil },
                    set: { if !$0 { importViewModel.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { importViewModel.errorMessage = nil }
            } message: {
                Text(importViewModel.errorMessage ?? "")
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .onAppear {
                viewModel.seedIfNeeded(context: modelContext)
                appeared = true
            }
            .alert(
                "Something went wrong",
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { if !$0 { viewModel.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { viewModel.errorMessage = nil }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .alert("Rename deck", isPresented: Binding(
                get: { deckPendingRename != nil },
                set: { if !$0 { deckPendingRename = nil } }
            )) {
                TextField("Deck name", text: $renameText)
                Button("Save") {
                    if let deck = deckPendingRename {
                        viewModel.renameDeck(deck, to: renameText, context: modelContext)
                    }
                    deckPendingRename = nil
                }
                Button("Cancel", role: .cancel) {
                    deckPendingRename = nil
                }
            }
            .confirmationDialog(
                "Delete deck?",
                isPresented: Binding(
                    get: { deckPendingDelete != nil },
                    set: { if !$0 { deckPendingDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete Deck", role: .destructive) {
                    if let deck = deckPendingDelete {
                        viewModel.deleteDeck(deck, context: modelContext)
                    }
                    deckPendingDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    deckPendingDelete = nil
                }
            } message: {
                if let deck = deckPendingDelete {
                    Text("Removes “\(deck.name)” and \(deck.totalCardCount) cards from Rounds Voice. Your Anki file is unchanged.")
                }
            }
        }
    }

    /// Brand-first first viewport — product name is the hero signal.
    private var brandHero: some View {
        VStack(alignment: .leading, spacing: RVTheme.Spacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("Rounds")
                    .font(RVTheme.Typography.brand)
                    .foregroundStyle(.primary)
                Text(" Voice")
                    .font(RVTheme.Typography.brand)
                    .foregroundStyle(RVTheme.seafoam)
            }

            Text("Clear Anki on foot.")
                .font(RVTheme.Typography.title)
                .foregroundStyle(.primary.opacity(0.85))

            Text("Hands-free reviews for walks, gym, and commute — graded like a professor, scheduled like Anki.")
                .font(RVTheme.Typography.bodySoft)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340, alignment: .leading)
                .padding(.top, 2)

            Button {
                showImporter = true
            } label: {
                Label("Import AnKing / Anki .apkg", systemImage: "square.and.arrow.down")
                    .font(RVTheme.Typography.headline)
                    .foregroundStyle(RVTheme.seafoam)
            }
            .padding(.top, RVTheme.Spacing.sm)

            // Quiet rule — editorial, not a card
            Rectangle()
                .fill(RVTheme.seafoam.opacity(0.35))
                .frame(width: 48, height: 2)
                .padding(.top, RVTheme.Spacing.sm)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dueRibbon: some View {
        HStack(alignment: .lastTextBaseline, spacing: 10) {
            Text("\(totalDue)")
                .font(RVTheme.Typography.brandSmall)
                .foregroundStyle(RVTheme.seafoam)
                .contentTransition(.numericText())
            VStack(alignment: .leading, spacing: 2) {
                Text("cards due")
                    .font(RVTheme.Typography.headline)
                Text("across \(decks.count) decks")
                    .font(RVTheme.Typography.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: RVTheme.Spacing.md) {
            Text("No decks yet")
                .font(RVTheme.Typography.display)
            Text("Sample AnKing decks appear on first launch. Reload them anytime from the menu.")
                .font(RVTheme.Typography.bodySoft)
                .foregroundStyle(.secondary)
            Button {
                viewModel.resetSampleDecks(context: modelContext)
            } label: {
                Text("Load Sample Decks")
                    .font(RVTheme.Typography.headline)
                    .foregroundStyle(RVTheme.bone)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
                    .background(RVTheme.seafoam, in: Capsule())
            }
            .padding(.top, RVTheme.Spacing.sm)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, RVTheme.Spacing.lg)
    }

    private var deckList: some View {
        VStack(spacing: RVTheme.Spacing.md) {
            ForEach(Array(decks.enumerated()), id: \.element.id) { index, deck in
                NavigationLink(value: deck.id) {
                    DeckRowView(deck: deck, index: index)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Rename", systemImage: "pencil") {
                        renameText = deck.name
                        deckPendingRename = deck
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        deckPendingDelete = deck
                    }
                }
                .rvReveal(index: 3 + index, appeared: appeared)
            }
        }
        .navigationDestination(for: UUID.self) { deckID in
            if let deck = decks.first(where: { $0.id == deckID }) {
                DeckDetailView(deck: deck)
            }
        }
    }
}

struct DeckRowView: View {
    let deck: Deck
    var index: Int = 0
    @Environment(\.colorScheme) private var scheme

    private var accentWash: Color {
        let washes = [RVTheme.seafoam, RVTheme.listening, RVTheme.copper]
        return washes[index % washes.count]
    }

    var body: some View {
        HStack(alignment: .center, spacing: RVTheme.Spacing.md) {
            // Asymmetric accent bar — not a generic icon tile
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(accentWash)
                .frame(width: 4, height: 52)

            VStack(alignment: .leading, spacing: 6) {
                Text(deck.name)
                    .font(RVTheme.Typography.title)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)

                Text(deck.deckDescription)
                    .font(RVTheme.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 2) {
                Text("\(deck.dueCardCount)")
                    .font(RVTheme.Typography.monoStat)
                    .foregroundStyle(accentWash)
                    .monospacedDigit()
                Text("due")
                    .font(RVTheme.Typography.overline)
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 18)
        .background {
            RoundedRectangle(cornerRadius: RVTheme.Radius.card, style: .continuous)
                .fill(scheme == .dark ? Color.white.opacity(0.04) : Color.white.opacity(0.55))
                .overlay {
                    RoundedRectangle(cornerRadius: RVTheme.Radius.card, style: .continuous)
                        .strokeBorder(RVTheme.hairline, lineWidth: 1)
                }
        }
        .contentShape(RoundedRectangle(cornerRadius: RVTheme.Radius.card, style: .continuous))
    }
}

#Preview {
    HomeView()
        .modelContainer(PreviewSupport.container)
}
