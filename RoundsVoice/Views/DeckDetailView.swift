import SwiftUI
import SwiftData

struct DeckDetailView: View {
    @Bindable var deck: Deck
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var showSession = false
    @State private var appeared = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showDeleteConfirm = false
    @State private var listViewModel = DeckListViewModel()
    @State private var sampleCards: [Card] = []

    private var dueCount: Int { deck.dueCount }

    var body: some View {
        ZStack {
            AtmosphereBackground(intensity: 0.7)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    hero
                        .rvReveal(index: 0, appeared: appeared)

                    startCTA
                        .rvReveal(index: 1, appeared: appeared)
                        .padding(.top, RVTheme.Spacing.xl)

                    manageRow
                        .rvReveal(index: 2, appeared: appeared)
                        .padding(.top, RVTheme.Spacing.lg)

                    previewHeader
                        .rvReveal(index: 3, appeared: appeared)
                        .padding(.top, RVTheme.Spacing.xxl)

                    previewList
                        .padding(.top, RVTheme.Spacing.md)
                }
                .padding(.horizontal, RVTheme.Spacing.lg)
                .padding(.bottom, RVTheme.Spacing.xxl)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Rename Deck", systemImage: "pencil") {
                        renameText = deck.name
                        showRename = true
                    }
                    Button("Delete Deck", systemImage: "trash", role: .destructive) {
                        showDeleteConfirm = true
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .fullScreenCover(isPresented: $showSession) {
            ReviewSessionView(deck: deck)
        }
        .alert("Rename deck", isPresented: $showRename) {
            TextField("Deck name", text: $renameText)
            Button("Save") {
                listViewModel.renameDeck(deck, to: renameText, context: modelContext)
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Delete “\(deck.name)”?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Deck", role: .destructive) {
                listViewModel.deleteDeck(deck, context: modelContext)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes \(deck.cardCount) cards from Rounds Voice. Your Anki file is unchanged.")
        }
        .task {
            await loadPreview()
        }
        .onAppear { appeared = true }
    }

    private var hero: some View {
        VStack(alignment: .leading, spacing: RVTheme.Spacing.md) {
            Text(sourceLabel.uppercased())
                .font(RVTheme.Typography.overline)
                .tracking(1.6)
                .foregroundStyle(RVTheme.seafoam)

            Text(deck.name)
                .font(RVTheme.Typography.brandSmall)
                .foregroundStyle(.primary)

            if !deck.deckDescription.isEmpty {
                Text(deck.deckDescription)
                    .font(RVTheme.Typography.bodySoft)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: RVTheme.Spacing.xl) {
                metric(value: "\(deck.cardCount)", label: "Cards")
                metric(value: "\(dueCount)", label: "Due now")
                if deck.suspendedCount > 0 {
                    metric(value: "\(deck.suspendedCount)", label: "Suspended")
                }
            }
            .padding(.top, RVTheme.Spacing.sm)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, RVTheme.Spacing.sm)
    }

    private var startCTA: some View {
        Button {
            showSession = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "figure.walk.motion")
                    .font(.title3.weight(.medium))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start Walking Review")
                        .font(RVTheme.Typography.headline)
                    Text(dueCount > 0 ? "\(dueCount) due · pocket ready" : "Practice · pocket ready")
                        .font(RVTheme.Typography.caption)
                        .opacity(0.85)
                }
                Spacer()
                Image(systemName: "arrow.right")
                    .font(.body.weight(.semibold))
            }
            .foregroundStyle(RVTheme.bone)
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
            .background {
                RoundedRectangle(cornerRadius: RVTheme.Radius.button, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [RVTheme.seafoamBright, RVTheme.seafoam],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: RVTheme.seafoam.opacity(0.35), radius: 18, y: 10)
            }
        }
        .buttonStyle(.plain)
        .disabled(deck.cardCount == 0)
        .opacity(deck.cardCount == 0 ? 0.5 : 1)
    }

    private var manageRow: some View {
        NavigationLink {
            CardBrowserView(deck: deck)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.stack")
                    .foregroundStyle(RVTheme.seafoam)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Browse & manage cards")
                        .font(RVTheme.Typography.headline)
                        .foregroundStyle(.primary)
                    Text("Search, edit, suspend, delete")
                        .font(RVTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(scheme == .dark ? Color.white.opacity(0.04) : Color.white.opacity(0.5))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(RVTheme.hairline, lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
    }

    private var previewHeader: some View {
        HStack(alignment: .lastTextBaseline) {
            Text("Up next")
                .font(RVTheme.Typography.title)
            Spacer()
            Text("Spoken preview")
                .font(RVTheme.Typography.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var previewList: some View {
        VStack(spacing: RVTheme.Spacing.sm) {
            ForEach(Array(sampleCards.enumerated()), id: \.element.id) { index, card in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(card.cardType == .cloze ? "CLOZE" : "BASIC")
                            .font(RVTheme.Typography.overline)
                            .tracking(1.2)
                            .foregroundStyle(RVTheme.seafoam)
                        Spacer()
                    }
                    Text(card.displayQuestion)
                        .font(RVTheme.Typography.body)
                        .foregroundStyle(.primary)
                    Text(card.spokenAnswer)
                        .font(RVTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(scheme == .dark ? Color.white.opacity(0.04) : Color.white.opacity(0.5))
                        .overlay {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(RVTheme.hairline, lineWidth: 1)
                        }
                }
                .rvReveal(index: 4 + index, appeared: appeared)
            }

            if deck.cardCount > sampleCards.count {
                NavigationLink {
                    CardBrowserView(deck: deck)
                } label: {
                    Text("View all \(deck.cardCount) cards")
                        .font(RVTheme.Typography.headline)
                        .foregroundStyle(RVTheme.seafoam)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, RVTheme.Spacing.sm)
                }
            }
        }
    }

    private var sourceLabel: String {
        switch deck.source {
        case .sample: return "Sample deck"
        case .ankiImport: return "Imported from Anki"
        case .manual: return "Manual deck"
        }
    }

    private func metric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(RVTheme.Typography.monoStat)
                .monospacedDigit()
            Text(label)
                .font(RVTheme.Typography.caption)
                .foregroundStyle(.secondary)
        }
    }

    @MainActor
    private func loadPreview() async {
        do {
            var due = try CardQuery.fetchDue(deckID: deck.id, limit: 4, context: modelContext)
            if due.isEmpty {
                due = try CardQuery.fetchUpcoming(deckID: deck.id, limit: 4, context: modelContext)
            }
            sampleCards = due
        } catch {
            sampleCards = []
        }
    }
}
