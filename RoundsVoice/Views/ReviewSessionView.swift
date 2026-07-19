import SwiftUI
import SwiftData

struct ReviewSessionView: View {
    let deck: Deck
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var viewModel: ReviewSessionViewModel
    @State private var draftAnswer = ""
    @State private var showBridge = false
    @FocusState private var bridgeFocused: Bool

    init(deck: Deck) {
        self.deck = deck
        _viewModel = State(
            initialValue: ReviewSessionViewModel(
                deck: deck,
                grader: AppSettings.shared.makeGrader,
                voice: VoiceManager()
            )
        )
    }

    var body: some View {
        ZStack {
            StatusAtmosphere(tint: statusTint)

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
                .animation(.easeInOut(duration: 0.4), value: viewModel.status)

                statusBlock
                    .padding(.horizontal, RVTheme.Spacing.xl)
                    .padding(.top, RVTheme.Spacing.sm)

                if viewModel.status == .listening, !viewModel.liveTranscript.isEmpty {
                    liveCaption
                        .padding(.horizontal, RVTheme.Spacing.xl)
                        .padding(.top, RVTheme.Spacing.md)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }

                Spacer(minLength: 12)

                quietStats
                    .padding(.horizontal, RVTheme.Spacing.lg)

                if showBridge {
                    phase1Bridge
                        .padding(.horizontal, RVTheme.Spacing.lg)
                        .padding(.top, RVTheme.Spacing.md)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
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
        .onDisappear { viewModel.stop() }
        .alert(
            "Permissions needed",
            isPresented: Binding(
                get: { viewModel.needsPermissions },
                set: { if !$0 { dismiss() } }
            )
        ) {
            Button("Close") { dismiss() }
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

    private var liveCaption: some View {
        Text(viewModel.liveTranscript)
            .font(RVTheme.Typography.bodySoft)
            .foregroundStyle(RVTheme.bone.opacity(0.75))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .frame(maxWidth: 340)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.08))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(statusTint.opacity(0.35), lineWidth: 1)
                    }
            }
            .animation(.easeOut(duration: 0.15), value: viewModel.liveTranscript)
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
                Text("WALKING REVIEW")
                    .font(RVTheme.Typography.overline)
                    .tracking(1.8)
                    .foregroundStyle(RVTheme.seafoamBright.opacity(0.9))
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
                .animation(.easeInOut(duration: 0.25), value: viewModel.status)

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
        .disabled(viewModel.status == .finished || viewModel.status == .speaking || viewModel.status == .thinking)
        .opacity(viewModel.status == .finished || viewModel.status == .speaking || viewModel.status == .thinking ? 0.4 : 1)
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
