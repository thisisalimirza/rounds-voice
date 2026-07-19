import SwiftUI

/// Design system: "Quiet Ward at Dawn"
/// Clinical calm for medical students — ink, mist, surgical seafoam.
/// Serif for brand moments, restrained sans for utility.
enum RVTheme {
    // MARK: Palette

    /// Deep ink — primary dark surface / brand weight
    static let ink = Color(red: 0.09, green: 0.12, blue: 0.16)
    /// Soft mist — light mode canvas
    static let mist = Color(red: 0.93, green: 0.94, blue: 0.93)
    /// Warm bone — light text on dark
    static let bone = Color(red: 0.96, green: 0.95, blue: 0.92)
    /// Surgical seafoam — primary accent (not teal cliché, not purple)
    static let seafoam = Color(red: 0.22, green: 0.52, blue: 0.48)
    static let seafoamBright = Color(red: 0.32, green: 0.68, blue: 0.62)
    /// Dawn copper — sparse secondary accent for emphasis only
    static let copper = Color(red: 0.72, green: 0.48, blue: 0.32)

    static let accent = seafoam
    static let accentSoft = seafoam.opacity(0.14)
    static let correct = Color(red: 0.28, green: 0.58, blue: 0.46)
    static let incorrect = Color(red: 0.72, green: 0.32, blue: 0.30)
    static let listening = Color(red: 0.35, green: 0.58, blue: 0.72)
    static let thinking = Color(red: 0.55, green: 0.48, blue: 0.38)

    // MARK: Adaptive surfaces

    static let canvas = Color("RVCanvas", bundle: nil)
    static let surface = Color("RVSurface", bundle: nil)
    static let hairline = Color.primary.opacity(0.08)

    // MARK: Typography

    enum Typography {
        /// Brand / hero — New York serif
        static let brand = Font.system(size: 42, weight: .medium, design: .serif)
        static let brandSmall = Font.system(size: 28, weight: .medium, design: .serif)
        /// Section titles
        static let display = Font.system(size: 26, weight: .semibold, design: .serif)
        static let title = Font.system(size: 20, weight: .semibold, design: .serif)
        static let headline = Font.system(size: 16, weight: .semibold, design: .default)
        static let body = Font.system(size: 16, weight: .regular, design: .default)
        static let bodySoft = Font.system(size: 15, weight: .regular, design: .default)
        static let caption = Font.system(size: 12, weight: .medium, design: .default)
        static let overline = Font.system(size: 11, weight: .semibold, design: .default)
        static let monoStat = Font.system(size: 22, weight: .medium, design: .serif)
        static let status = Font.system(size: 28, weight: .medium, design: .serif)
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 36
        static let xxl: CGFloat = 56
    }

    enum Radius {
        static let card: CGFloat = 20
        static let button: CGFloat = 16
        static let pill: CGFloat = 999
    }
}

// MARK: - Atmosphere

struct AtmosphereBackground: View {
    var intensity: Double = 1
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            (scheme == .dark ? RVTheme.ink : RVTheme.mist)
                .ignoresSafeArea()

            // Soft dawn wash — top-leading
            RadialGradient(
                colors: [
                    RVTheme.seafoam.opacity(scheme == .dark ? 0.18 * intensity : 0.12 * intensity),
                    .clear
                ],
                center: .topLeading,
                startRadius: 20,
                endRadius: 420
            )
            .ignoresSafeArea()

            // Cool depth — bottom trailing
            RadialGradient(
                colors: [
                    (scheme == .dark ? RVTheme.listening : RVTheme.copper)
                        .opacity(scheme == .dark ? 0.10 * intensity : 0.06 * intensity),
                    .clear
                ],
                center: .bottomTrailing,
                startRadius: 40,
                endRadius: 380
            )
            .ignoresSafeArea()

            // Fine grain — stable pseudo-random field (no per-frame flicker)
            GeometryReader { geo in
                Canvas { context, size in
                    var generator = SeededGenerator(seed: 42)
                    let count = Int((size.width * size.height) / 2800)
                    for _ in 0..<count {
                        let x = CGFloat.random(in: 0..<size.width, using: &generator)
                        let y = CGFloat.random(in: 0..<size.height, using: &generator)
                        let rect = CGRect(x: x, y: y, width: 1.1, height: 1.1)
                        context.fill(
                            Path(ellipseIn: rect),
                            with: .color(.primary.opacity(scheme == .dark ? 0.045 : 0.035))
                        )
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .opacity(0.65)
        }
    }
}

struct StatusAtmosphere: View {
    let tint: Color
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            (scheme == .dark ? RVTheme.ink : Color(red: 0.95, green: 0.95, blue: 0.94))
                .ignoresSafeArea()

            RadialGradient(
                colors: [tint.opacity(scheme == .dark ? 0.28 : 0.16), .clear],
                center: UnitPoint(x: 0.5, y: 0.38),
                startRadius: 10,
                endRadius: 340
            )
            .ignoresSafeArea()
            .animation(.easeInOut(duration: 0.55), value: tint)

            RadialGradient(
                colors: [
                    (scheme == .dark ? Color.black : Color.white).opacity(0.15),
                    .clear
                ],
                center: .bottom,
                startRadius: 40,
                endRadius: 500
            )
            .ignoresSafeArea()
        }
    }
}

// MARK: - Breathing voice orb

struct BreathingOrb: View {
    let tint: Color
    let symbol: String
    let isActive: Bool
    @State private var breathe = false
    @State private var ring = false

    var body: some View {
        ZStack {
            // Outer rings
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .stroke(tint.opacity(0.12 - Double(i) * 0.03), lineWidth: 1)
                    .frame(width: 168 + CGFloat(i) * 36, height: 168 + CGFloat(i) * 36)
                    .scaleEffect(ring ? 1.04 + CGFloat(i) * 0.02 : 0.96)
                    .opacity(isActive ? 1 : 0.45)
            }

            // Soft glow
            Circle()
                .fill(
                    RadialGradient(
                        colors: [tint.opacity(0.35), tint.opacity(0.08), .clear],
                        center: .center,
                        startRadius: 10,
                        endRadius: 110
                    )
                )
                .frame(width: 220, height: 220)
                .scaleEffect(breathe ? 1.08 : 0.92)
                .blur(radius: 8)

            // Core
            Circle()
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.95), tint.opacity(0.7)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 108, height: 108)
                .shadow(color: tint.opacity(0.45), radius: breathe ? 28 : 14, y: 8)
                .scaleEffect(breathe ? 1.04 : 0.98)

            Image(systemName: symbol)
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(RVTheme.bone)
                .symbolEffect(.variableColor.iterative, isActive: isActive)
        }
        .frame(height: 280)
        .onAppear {
            withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true)) {
                breathe = true
            }
            withAnimation(.easeInOut(duration: 3.2).repeatForever(autoreverses: true)) {
                ring = true
            }
        }
    }
}

// MARK: - View helpers

extension View {
    func rvSurface(padding: CGFloat = RVTheme.Spacing.md) -> some View {
        self
            .padding(padding)
            .background {
                RoundedRectangle(cornerRadius: RVTheme.Radius.card, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: RVTheme.Radius.card, style: .continuous)
                            .strokeBorder(RVTheme.hairline, lineWidth: 1)
                    }
            }
    }

    func rvReveal(index: Int, appeared: Bool) -> some View {
        self
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 14)
            .animation(
                .spring(response: 0.55, dampingFraction: 0.84).delay(Double(index) * 0.07),
                value: appeared
            )
    }
}

/// Deterministic RNG so grain doesn't shimmer on redraw.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 0xDEADBEEF : seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
