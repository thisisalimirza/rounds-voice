import SwiftUI
import SwiftData

/// Study analytics — today + all-time, backed by persisted session summaries.
struct StatsView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) private var scheme
    @Query(sort: \StudySessionSummary.endedAt, order: .reverse) private var sessions: [StudySessionSummary]

    private var today: StudyStats.Snapshot {
        StudyStats.aggregate(sessions: Array(sessions), since: StudyStats.startOfToday())
    }

    private var allTime: StudyStats.Snapshot {
        StudyStats.aggregate(sessions: Array(sessions))
    }

    var body: some View {
        ZStack {
            AtmosphereBackground(intensity: 0.55)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: RVTheme.Spacing.xl) {
                    header

                    periodCard(title: "Today", snapshot: today, accent: RVTheme.seafoam)

                    periodCard(title: "All time", snapshot: allTime, accent: RVTheme.listening)

                    if !sessions.isEmpty {
                        recentSection
                    } else {
                        emptyHint
                    }
                }
                .padding(.horizontal, RVTheme.Spacing.lg)
                .padding(.bottom, RVTheme.Spacing.xxl)
                .padding(.top, RVTheme.Spacing.md)
            }
        }
        .navigationTitle("Stats")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your pace")
                .font(RVTheme.Typography.display)
            Text("Cards studied, accuracy, and time per card from walking reviews.")
                .font(RVTheme.Typography.bodySoft)
                .foregroundStyle(.secondary)
        }
    }

    private func periodCard(title: String, snapshot: StudyStats.Snapshot, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title.uppercased())
                .font(RVTheme.Typography.overline)
                .tracking(1.4)
                .foregroundStyle(accent)

            HStack(spacing: 0) {
                metric(value: "\(snapshot.cardsStudied)", label: "cards")
                divider
                metric(value: "\(snapshot.accuracyPercent)%", label: "accuracy")
                divider
                metric(value: formatAvg(snapshot.averageSecondsPerCard), label: "per card")
            }

            HStack(spacing: 16) {
                Label("\(snapshot.studiedMinutes) min studied", systemImage: "clock")
                Label("\(snapshot.sessionCount) sessions", systemImage: "figure.walk")
            }
            .font(RVTheme.Typography.caption)
            .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(scheme == .dark ? Color.white.opacity(0.04) : Color.white.opacity(0.55))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(RVTheme.hairline, lineWidth: 1)
                }
        }
    }

    private func metric(value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(RVTheme.Typography.monoStat)
                .foregroundStyle(.primary)
                .monospacedDigit()
            Text(label)
                .font(RVTheme.Typography.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var divider: some View {
        Rectangle()
            .fill(RVTheme.hairline)
            .frame(width: 1, height: 36)
            .padding(.horizontal, 8)
    }

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent sessions")
                .font(RVTheme.Typography.overline)
                .tracking(1.4)
                .foregroundStyle(.secondary)

            ForEach(Array(sessions.prefix(12)), id: \.id) { session in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.deckName)
                            .font(RVTheme.Typography.headline)
                            .lineLimit(1)
                        Text(session.endedAt.formatted(date: .abbreviated, time: .shortened))
                            .font(RVTheme.Typography.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text("\(session.cardsCompleted) cards · \(session.accuracyPercent)%")
                            .font(RVTheme.Typography.caption)
                            .foregroundStyle(.secondary)
                        Text(formatAvg(session.averageSecondsPerCard) + " / card")
                            .font(RVTheme.Typography.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(scheme == .dark ? 0.04 : 0.03))
                }
            }
        }
    }

    private var emptyHint: some View {
        ContentUnavailableView(
            "No sessions yet",
            systemImage: "chart.bar",
            description: Text("Finish a walking review and your stats will show up here.")
        )
        .frame(maxWidth: .infinity)
        .padding(.top, RVTheme.Spacing.lg)
    }

    private func formatAvg(_ seconds: Double) -> String {
        guard seconds > 0 else { return "—" }
        if seconds < 60 {
            return String(format: "%.0fs", seconds)
        }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }
}
