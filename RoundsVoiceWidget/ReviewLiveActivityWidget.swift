import ActivityKit
import SwiftUI
import WidgetKit

struct ReviewLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ReviewActivityAttributes.self) { context in
            LockScreenLiveActivityView(context: context)
                .activityBackgroundTint(LiveActivityPalette.ink.opacity(0.92))
                .activitySystemActionForegroundColor(LiveActivityPalette.bone)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        phaseGlyph(context.state.phase, size: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Rounds Voice")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(LiveActivityPalette.seafoamBright)
                            Text(context.attributes.deckName)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(LiveActivityPalette.bone)
                                .lineLimit(1)
                        }
                    }
                    .padding(.leading, 4)
                }

                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(context.state.phase.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(phaseColor(context.state.phase))
                        Text("\(context.state.cardsCompleted) done")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(LiveActivityPalette.bone.opacity(0.7))
                    }
                    .padding(.trailing, 4)
                }

                DynamicIslandExpandedRegion(.center) {
                    EmptyView()
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(context.state.detail.isEmpty ? context.state.phase.title : context.state.detail)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(LiveActivityPalette.bone)
                            .lineLimit(2)
                            .contentTransition(.numericText())

                        HStack {
                            Label("\(context.state.correctCount) correct", systemImage: "checkmark")
                            Spacer()
                            Label("\(context.state.queueRemaining) left", systemImage: "rectangle.stack")
                        }
                        .font(.caption2)
                        .foregroundStyle(LiveActivityPalette.bone.opacity(0.65))
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 2)
                }
            } compactLeading: {
                phaseGlyph(context.state.phase, size: 12)
                    .padding(.leading, 2)
            } compactTrailing: {
                Text(compactTrailingText(context.state))
                    .font(.caption2.weight(.bold).monospacedDigit())
                    .foregroundStyle(phaseColor(context.state.phase))
                    .padding(.trailing, 2)
                    .contentTransition(.numericText())
            } minimal: {
                phaseGlyph(context.state.phase, size: 12)
            }
            .keylineTint(phaseColor(context.state.phase))
        }
    }

    private func compactTrailingText(_ state: ReviewActivityAttributes.ContentState) -> String {
        if state.isPaused { return "‖" }
        switch state.phase {
        case .listening:
            return state.detail.isEmpty ? "Mic" : "…"
        case .thinking:
            return "…"
        case .correct, .incorrect:
            return state.phase.compactLabel
        case .speaking:
            return "▶"
        case .finished:
            return "✓"
        case .idle, .paused:
            return state.phase.compactLabel
        }
    }

    @ViewBuilder
    private func phaseGlyph(_ phase: ReviewActivityAttributes.ContentState.Phase, size: CGFloat) -> some View {
        Image(systemName: phase.symbolName)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(phaseColor(phase))
            .symbolEffect(.pulse, options: .repeating, isActive: phase == .listening || phase == .thinking)
    }

    private func phaseColor(_ phase: ReviewActivityAttributes.ContentState.Phase) -> Color {
        switch phase {
        case .listening: return LiveActivityPalette.listening
        case .thinking: return LiveActivityPalette.thinking
        case .correct: return LiveActivityPalette.correct
        case .incorrect: return LiveActivityPalette.incorrect
        case .paused: return LiveActivityPalette.bone.opacity(0.7)
        case .speaking: return LiveActivityPalette.seafoamBright
        case .idle, .finished: return LiveActivityPalette.seafoam
        }
    }
}

// MARK: - Lock Screen

private struct LockScreenLiveActivityView: View {
    let context: ActivityViewContext<ReviewActivityAttributes>

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(phaseColor.opacity(0.22))
                    .frame(width: 44, height: 44)
                Image(systemName: context.state.phase.symbolName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(phaseColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Rounds Voice")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(LiveActivityPalette.seafoamBright)
                    Spacer()
                    Text(context.state.phase.title)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(phaseColor)
                }

                Text(context.attributes.deckName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(LiveActivityPalette.bone)
                    .lineLimit(1)

                Text(context.state.detail.isEmpty ? "Review in progress" : context.state.detail)
                    .font(.caption)
                    .foregroundStyle(LiveActivityPalette.bone.opacity(0.75))
                    .lineLimit(2)

                HStack(spacing: 12) {
                    Text("\(context.state.cardsCompleted) reviewed")
                    Text("·")
                    Text("\(context.state.correctCount) correct")
                    Text("·")
                    Text("\(context.state.queueRemaining) left")
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(LiveActivityPalette.bone.opacity(0.55))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private var phaseColor: Color {
        switch context.state.phase {
        case .listening: return LiveActivityPalette.listening
        case .thinking: return LiveActivityPalette.thinking
        case .correct: return LiveActivityPalette.correct
        case .incorrect: return LiveActivityPalette.incorrect
        case .paused: return LiveActivityPalette.bone.opacity(0.7)
        case .speaking: return LiveActivityPalette.seafoamBright
        case .idle, .finished: return LiveActivityPalette.seafoam
        }
    }
}

// MARK: - Palette (widget-safe; mirrors RVTheme)

private enum LiveActivityPalette {
    static let ink = Color(red: 0.09, green: 0.12, blue: 0.16)
    static let bone = Color(red: 0.96, green: 0.95, blue: 0.92)
    static let seafoam = Color(red: 0.22, green: 0.52, blue: 0.48)
    static let seafoamBright = Color(red: 0.32, green: 0.68, blue: 0.62)
    static let listening = Color(red: 0.35, green: 0.58, blue: 0.72)
    static let thinking = Color(red: 0.55, green: 0.48, blue: 0.38)
    static let correct = Color(red: 0.28, green: 0.58, blue: 0.46)
    static let incorrect = Color(red: 0.72, green: 0.32, blue: 0.30)
}
