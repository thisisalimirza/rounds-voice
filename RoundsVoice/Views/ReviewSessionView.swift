import SwiftUI
import SwiftData
import UIKit

struct ReviewSessionView: View {
    let deck: Deck
    let studyFilter: StudyFilter
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: ReviewSessionViewModel
    @State private var draftAnswer = ""
    @State private var showBridge = false
    @FocusState private var bridgeFocused: Bool

    init(deck: Deck, studyFilter: StudyFilter = StudyFilter()) {
        self.deck = deck
        self.studyFilter = studyFilter
        _viewModel = State(
            initialValue: ReviewSessionViewModel(
                deck: deck,
                studyFilter: studyFilter,
                grader: AppSettings.shared.makeGrader,
                voice: VoiceManager()
            )
        )
    }

    var body: some View {
        ZStack {
            StatusAtmosphere(phase: viewModel.status)

            VStack(spacing: 0) {
                topBar
                    .padding(.horizontal, RVTheme.Spacing.lg)
                    .padding(.top, 8)

                Spacer(minLength: 8)

                BreathingOrb(
                    tint: statusTint,
                    symbol: micSymbol,
                    isActive: viewModel.status == .listening || viewModel.status == .speaking
                )
                // Don't implicit-animate the whole orb tree on every status flip.
                .transaction { $0.animation = nil }

                statusBlock
                    .padding(.horizontal, RVTheme.Spacing.xl)
                    .padding(.top, RVTheme.Spacing.sm)

                // Reserved slot — opacity only (no insert/remove layout thrash).
                liveCaption
                    .padding(.horizontal, RVTheme.Spacing.xl)
                    .padding(.top, RVTheme.Spacing.md)
                    .opacity(showLiveCaption ? 1 : 0)
                    .accessibilityHidden(!showLiveCaption)

                Spacer(minLength: 12)

                quietStats
                    .padding(.horizontal, RVTheme.Spacing.lg)

                if showBridge {
                    phase1Bridge
                        .padding(.horizontal, RVTheme.Spacing.lg)
                        .padding(.top, RVTheme.Spacing.md)
                        .transition(.opacity)
                }

                controls
                    .padding(.horizontal, RVTheme.Spacing.lg)
                    .padding(.top, RVTheme.Spacing.md)
                    .padding(.bottom, RVTheme.Spacing.lg)
            }
        }
        .preferredColorScheme(.dark)
        .statusBarHidden(false)
        .onAppear { viewModel.start() }
        .onDisappear {
            // SwiftUI's fullScreenCover content can spuriously receive onDisappear
            // when the app is backgrounded (locking the phone, an incoming call,
            // Control Center, etc.) even though the presented view hierarchy is
            // still alive underneath. Locking must never cancel a walking review —
            // only tear the session down when the user is genuinely leaving while
            // the app is active. Explicit exits (the X button, permission alert)
            // call `viewModel.stop()` themselves, so this is a backstop for any
            // other active-state dismissal, not the primary stop path.
            guard UIApplication.shared.applicationState == .active else { return }
            viewModel.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            // Locking goes to .inactive/.background — keep reviewing.
            // Only re-assert when becoming active again (unlock / return).
            if phase == .active {
                viewModel.reassertAfterBecomingActive()
            }
        }
        .alert(
            "Permissions needed",
            isPresented: Binding(
                get: { viewModel.needsPermissions },
                set: { if !$0 { viewModel.stop(); dismiss() } }
            )
        ) {
            Button("Close") {
                viewModel.stop()
                dismiss()
            }
        } message: {
            Text("Enable Microphone and Speech Recognition in Settings to use walking reviews.")
        }
        .alert(
            "Voice error",
            isPresented: Binding(
                get: { viewModel.errorMessage != nil && !viewModel.needsPermissions },
                set: { if !$0 { /* keep message until dismiss */ } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private var showLiveCaption: Bool {
        viewModel.status == .listening && !viewModel.liveTranscript.isEmpty
    }

    private var liveCaption: some View {
        Text(viewModel.liveTranscript.isEmpty ? " " : viewModel.liveTranscript)
            .font(RVTheme.Typography.bodySoft)
            .foregroundStyle(RVTheme.bone.opacity(0.75))
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: 340, minHeight: 44)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(RVTheme.listening.opacity(0.35), lineWidth: 1)
                    }
            }
            // Never animate on every partial token — that was a major stutter source.
    }

    private var topBar: some View {
        HStack {
            Button {
                viewModel.stop()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(RVTheme.bone.opacity(0.9))
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.08), in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            }

            Spacer()

            VStack(spacing: 3) {
                Text(viewModel.deckTitle)
                    .font(RVTheme.Typography.headline)
                    .foregroundStyle(RVTheme.bone)
                Text(viewModel.studyFilter.isEmpty ? "WALKING REVIEW" : "TAG FILTER")
                    .font(RVTheme.Typography.overline)
                    .tracking(1.8)
                    .foregroundStyle(RVTheme.seafoamBright.opacity(0.9))
                if !viewModel.studyFilter.isEmpty {
                    Text(viewModel.studyFilter.summary)
                        .font(.caption2)
                        .foregroundStyle(RVTheme.bone.opacity(0.55))
                        .lineLimit(1)
                }
            }

            Spacer()

            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
                    showBridge.toggle()
                    if showBridge { bridgeFocused = true }
                }
            } label: {
                Image(systemName: showBridge ? "keyboard.chevron.compact.down" : "keyboard")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(RVTheme.bone.opacity(0.9))
                    .frame(width: 40, height: 40)
                    .background(Color.white.opacity(0.08), in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
            }
            .accessibilityLabel("Toggle answer bridge")
        }
    }

    private var statusBlock: some View {
        VStack(spacing: RVTheme.Spacing.md) {
            Text(viewModel.status.displayText)
                .font(RVTheme.Typography.status)
                .foregroundStyle(statusTint)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: viewModel.status)

            if let card = viewModel.currentCard {
                Text(card.displayQuestion)
                    .font(RVTheme.Typography.bodySoft)
                    .foregroundStyle(RVTheme.bone.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(maxWidth: 320)
            }

            if !viewModel.lastFeedback.isEmpty,
               viewModel.status == .correct || viewModel.status == .incorrect {
                Text(viewModel.lastFeedback)
                    .font(RVTheme.Typography.caption)
                    .foregroundStyle(RVTheme.bone.opacity(0.45))
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
        }
    }

    /// Quiet metrics — not a dashboard strip of cards.
    private var quietStats: some View {
        HStack(spacing: 0) {
            quietStat("\(viewModel.stats.cardsCompleted)", "done")
            separator
            quietStat("\(viewModel.stats.accuracyPercent)%", "accuracy")
            separator
            quietStat(viewModel.elapsedFormatted, "elapsed")
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .background {
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                }
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Color.white.opacity(0.1))
            .frame(width: 1, height: 28)
    }

    private func quietStat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 17, weight: .medium, design: .serif))
                .foregroundStyle(RVTheme.bone)
                .monospacedDigit()
            Text(label.uppercased())
                .font(RVTheme.Typography.overline)
                .tracking(1.0)
                .foregroundStyle(RVTheme.bone.opacity(0.4))
        }
        .frame(maxWidth: .infinity)
    }

    private var phase1Bridge: some View {
        HStack(spacing: 10) {
            TextField("Type if mic isn't available…", text: $draftAnswer)
                .font(RVTheme.Typography.bodySoft)
                .foregroundStyle(RVTheme.bone)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .background(Color.white.opacity(0.08), in: Capsule())
                .focused($bridgeFocused)
                .submitLabel(.go)
                .onSubmit(submitDraft)

            Button(action: submitDraft) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(
                        draftAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? RVTheme.bone.opacity(0.25)
                            : RVTheme.seafoamBright
                    )
            }
            .disabled(draftAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            control("Repeat", "arrow.counterclockwise", viewModel.repeatQuestion)
            control(
                viewModel.isSuspended ? "Resume" : "Pause",
                viewModel.isSuspended ? "play.fill" : "pause.fill"
            ) {
                if viewModel.isSuspended {
                    viewModel.resumeSession()
                } else {
                    viewModel.pauseSession()
                }
            }
            control("Skip", "forward.fill", viewModel.skip)
            control("Pass", "questionmark", viewModel.markDontKnow)
        }
    }

    private func control(_ title: String, _ systemImage: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 16, weight: .medium))
                Text(title)
                    .font(RVTheme.Typography.caption)
            }
            .foregroundStyle(RVTheme.bone.opacity(0.85))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
        .disabled(
            title == "Pause" || title == "Resume"
                ? (viewModel.status == .finished || viewModel.status == .thinking)
                : (viewModel.status == .finished
                    || viewModel.status == .speaking
                    || viewModel.status == .thinking)
        )
        .opacity(
            (
                title == "Pause" || title == "Resume"
                    ? (viewModel.status == .finished || viewModel.status == .thinking)
                    : (viewModel.status == .finished
                        || viewModel.status == .speaking
                        || viewModel.status == .thinking)
            ) ? 0.4 : 1
        )
    }

    private var statusTint: Color {
        switch viewModel.status {
        case .listening: return RVTheme.listening
        case .speaking: return RVTheme.seafoamBright
        case .thinking: return RVTheme.thinking
        case .correct: return RVTheme.correct
        case .incorrect: return RVTheme.incorrect
        case .paused: return RVTheme.copper
        case .finished: return RVTheme.seafoamBright
        case .idle: return RVTheme.seafoam
        }
    }

    private var micSymbol: String {
        switch viewModel.status {
        case .listening: return "mic.fill"
        case .speaking: return "speaker.wave.2.fill"
        case .thinking: return "ellipsis"
        case .correct: return "checkmark"
        case .incorrect: return "xmark"
        case .paused: return "pause.fill"
        case .finished: return "flag.fill"
        case .idle: return "mic"
        }
    }

    private func submitDraft() {
        let answer = draftAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty else { return }
        viewModel.submitAnswer(answer)
        draftAnswer = ""
    }
}
