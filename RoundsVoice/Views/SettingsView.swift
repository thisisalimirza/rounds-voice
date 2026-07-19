import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var showKey = false

    var body: some View {
        NavigationStack {
            ZStack {
                AtmosphereBackground(intensity: 0.6)
                ScrollView(showsIndicators: false) {
                    content
                        .padding(RVTheme.Spacing.lg)
                        .padding(.bottom, RVTheme.Spacing.xxl)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(RVTheme.seafoam)
                }
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: RVTheme.Spacing.xl) {
            header
            voiceSection
            if settings.ttsEngine == .openAI {
                voicePickerSection
                voiceSpeedSection
            }
            listeningSection
            graderSection
            apiKeySection
            projectIDSection
            modelSection
            statusNote
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: RVTheme.Spacing.sm) {
            Text("Voice & grading")
                .font(RVTheme.Typography.display)
            Text("OpenAI for natural speech and medical listening when online — Apple only as offline fallback.")
                .font(RVTheme.Typography.bodySoft)
                .foregroundStyle(.secondary)
        }
    }

    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: RVTheme.Spacing.sm) {
            sectionLabel("App voice")
            ForEach(TTSEngine.allCases) { engine in
                TTSEngineOptionRow(
                    engine: engine,
                    isSelected: settings.ttsEngine == engine,
                    isDisabled: engine == .openAI && !settings.hasOpenAIKey
                ) {
                    settings.ttsEngine = engine
                }
            }

            if settings.ttsEngine == .openAI && !settings.hasOpenAIKey {
                Text("Add an OpenAI API key below to unlock natural voice.")
                    .font(RVTheme.Typography.caption)
                    .foregroundStyle(RVTheme.copper)
            }
        }
    }

    private var voicePickerSection: some View {
        VStack(alignment: .leading, spacing: RVTheme.Spacing.sm) {
            sectionLabel("Voice character")
            ForEach(OpenAITTSVoice.allCases) { voice in
                Button {
                    settings.ttsVoice = voice
                } label: {
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: settings.ttsVoice == voice ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(
                                settings.ttsVoice == voice
                                    ? AnyShapeStyle(RVTheme.seafoam)
                                    : AnyShapeStyle(.tertiary)
                            )
                            .font(.title3)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(voice.title)
                                .font(RVTheme.Typography.headline)
                                .foregroundStyle(.primary)
                            Text(voice.blurb)
                                .font(RVTheme.Typography.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(16)
                    .background {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(.ultraThinMaterial)
                            .overlay {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(
                                        settings.ttsVoice == voice
                                            ? RVTheme.seafoam.opacity(0.45)
                                            : RVTheme.hairline,
                                        lineWidth: 1
                                    )
                            }
                    }
                }
                .buttonStyle(.plain)
            }

            Text("Streams audio for faster start. Prefetches the next card. Falls back to Apple offline.")
                .font(RVTheme.Typography.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var listeningSection: some View {
        VStack(alignment: .leading, spacing: RVTheme.Spacing.sm) {
            sectionLabel("Listening")

            Toggle(isOn: $settings.useOpenAISTT) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("OpenAI medical speech-to-text")
                        .font(RVTheme.Typography.headline)
                    Text("Live captions + gpt-4o-transcribe for drug names & mechanisms. Apple if offline.")
                        .font(RVTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(RVTheme.seafoam)
            .disabled(!settings.hasOpenAIKey)
            .padding(16)
            .background(settingsPanel)

            if !settings.hasOpenAIKey {
                Text("Add an API key to enable cloud listening.")
                    .font(RVTheme.Typography.caption)
                    .foregroundStyle(RVTheme.copper)
            }
        }
    }

    private var voiceSpeedSection: some View {
        VStack(alignment: .leading, spacing: RVTheme.Spacing.sm) {
            sectionLabel("Speaking pace")
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Slower")
                        .font(RVTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%.2f×", settings.ttsSpeed))
                        .font(RVTheme.Typography.monoStat)
                        .monospacedDigit()
                    Spacer()
                    Text("Faster")
                        .font(RVTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.ttsSpeed, in: 0.85...1.4, step: 0.05)
                    .tint(RVTheme.seafoam)
            }
            .padding(16)
            .background(settingsPanel)

            Text("Default 1.15× keeps walking reviews moving without sounding rushed.")
                .font(RVTheme.Typography.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var graderSection: some View {
        VStack(alignment: .leading, spacing: RVTheme.Spacing.sm) {
            sectionLabel("Grader")
            ForEach(AppSettings.GraderEngine.allCases) { engine in
                GraderOptionRow(
                    engine: engine,
                    isSelected: settings.graderEngine == engine
                ) {
                    settings.graderEngine = engine
                }
            }
        }
    }

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: RVTheme.Spacing.sm) {
            sectionLabel("OpenAI API key")

            HStack(spacing: 10) {
                apiKeyField
                Button {
                    showKey.toggle()
                } label: {
                    Image(systemName: showKey ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .background(settingsPanel)

            Text("Stored in Keychain on this device. Powers AI grading and natural voice.")
                .font(RVTheme.Typography.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var projectIDSection: some View {
        VStack(alignment: .leading, spacing: RVTheme.Spacing.sm) {
            sectionLabel("OpenAI project ID (optional)")

            TextField("proj_…", text: $settings.openAIProjectID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(RVTheme.Typography.bodySoft)
                .padding(16)
                .background(settingsPanel)

            Text("Sent as the OpenAI-Project header for project-scoped keys.")
                .font(RVTheme.Typography.caption)
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var apiKeyField: some View {
        if showKey {
            TextField("sk-…", text: $settings.openAIAPIKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(RVTheme.Typography.bodySoft)
        } else {
            SecureField("sk-…", text: $settings.openAIAPIKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(RVTheme.Typography.bodySoft)
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: RVTheme.Spacing.sm) {
            sectionLabel("Grading model")

            TextField("gpt-4o-mini", text: $settings.openAIModel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(RVTheme.Typography.bodySoft)
                .padding(16)
                .background(settingsPanel)

            Text("gpt-4o-mini is fast and cheap for grading. Use gpt-4o for stricter judgment.")
                .font(RVTheme.Typography.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var statusNote: some View {
        let gradingReady = settings.graderEngine == .openAI && settings.hasOpenAIKey
        let voiceReady = settings.shouldUseOpenAITTS
        let listenReady = settings.shouldUseOpenAISTT
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(voiceReady ? RVTheme.correct : RVTheme.copper)
                    .frame(width: 8, height: 8)
                Text(
                    voiceReady
                        ? "Natural voice streaming (\(settings.ttsVoice.title))."
                        : "App voice: Apple system (offline / no key)."
                )
                .font(RVTheme.Typography.caption)
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Circle()
                    .fill(listenReady ? RVTheme.correct : RVTheme.copper)
                    .frame(width: 8, height: 8)
                Text(
                    listenReady
                        ? "Medical listening: OpenAI transcribe + live captions."
                        : "Listening: Apple Speech (enable OpenAI STT when online)."
                )
                .font(RVTheme.Typography.caption)
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Circle()
                    .fill(gradingReady ? RVTheme.correct : RVTheme.copper)
                    .frame(width: 8, height: 8)
                Text(
                    gradingReady
                        ? "AI grading active for the next walking review."
                        : "Using offline heuristic until an OpenAI key is set."
                )
                .font(RVTheme.Typography.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.top, RVTheme.Spacing.sm)
    }

    private var settingsPanel: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(RVTheme.hairline, lineWidth: 1)
            }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(RVTheme.Typography.overline)
            .tracking(1.4)
            .foregroundStyle(.secondary)
    }
}

private struct TTSEngineOptionRow: View {
    let engine: TTSEngine
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(RVTheme.seafoam) : AnyShapeStyle(.tertiary))
                    .font(.title3)

                VStack(alignment: .leading, spacing: 4) {
                    Text(engine.title)
                        .font(RVTheme.Typography.headline)
                        .foregroundStyle(.primary)
                    Text(engine.subtitle)
                        .font(RVTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .opacity(isDisabled && !isSelected ? 0.55 : 1)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                isSelected ? RVTheme.seafoam.opacity(0.45) : RVTheme.hairline,
                                lineWidth: 1
                            )
                    }
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled && !isSelected)
    }
}

private struct GraderOptionRow: View {
    let engine: AppSettings.GraderEngine
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(RVTheme.seafoam) : AnyShapeStyle(.tertiary))
                    .font(.title3)

                VStack(alignment: .leading, spacing: 4) {
                    Text(engine.title)
                        .font(RVTheme.Typography.headline)
                        .foregroundStyle(.primary)
                    Text(engine.subtitle)
                        .font(RVTheme.Typography.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                isSelected ? RVTheme.seafoam.opacity(0.45) : RVTheme.hairline,
                                lineWidth: 1
                            )
                    }
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    SettingsView(settings: .shared)
}
