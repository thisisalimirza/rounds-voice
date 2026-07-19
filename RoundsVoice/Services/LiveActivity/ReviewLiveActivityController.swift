import ActivityKit
import Foundation

/// Starts, updates, and ends the review Live Activity (Lock Screen + Dynamic Island).
@MainActor
final class ReviewLiveActivityController {
    static let shared = ReviewLiveActivityController()

    private var activity: Activity<ReviewActivityAttributes>?
    private var lastState: ReviewActivityAttributes.ContentState?
    private var updateTask: Task<Void, Never>?

    private init() {}

    var isAvailable: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    func start(deckName: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        endStaleActivities()

        let initial = ReviewActivityAttributes.ContentState(
            phase: .idle,
            detail: "Starting review…",
            cardsCompleted: 0,
            correctCount: 0,
            queueRemaining: 0,
            isPaused: false
        )
        let attributes = ReviewActivityAttributes(deckName: deckName)
        let content = ActivityContent(state: initial, staleDate: nil)

        do {
            activity = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
            lastState = initial
        } catch {
            activity = nil
            lastState = nil
        }
    }

    func update(
        phase: ReviewActivityAttributes.ContentState.Phase,
        detail: String,
        cardsCompleted: Int,
        correctCount: Int,
        queueRemaining: Int,
        isPaused: Bool
    ) {
        let state = ReviewActivityAttributes.ContentState(
            phase: phase,
            detail: String(detail.prefix(120)),
            cardsCompleted: cardsCompleted,
            correctCount: correctCount,
            queueRemaining: queueRemaining,
            isPaused: isPaused
        )
        guard state != lastState else { return }
        lastState = state

        // Coalesce rapid caption updates so ActivityKit isn't flooded.
        updateTask?.cancel()
        updateTask = Task {
            if phase == .listening {
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
            }
            await push(state)
        }
    }

    func end() {
        updateTask?.cancel()
        updateTask = nil
        lastState = nil
        guard let activity else {
            endStaleActivities()
            return
        }
        self.activity = nil
        let final = ReviewActivityAttributes.ContentState(
            phase: .finished,
            detail: "Session complete",
            cardsCompleted: 0,
            correctCount: 0,
            queueRemaining: 0,
            isPaused: false
        )
        Task {
            await activity.end(
                ActivityContent(state: final, staleDate: nil),
                dismissalPolicy: .immediate
            )
        }
    }

    private func push(_ state: ReviewActivityAttributes.ContentState) async {
        guard let activity else { return }
        let content = ActivityContent(state: state, staleDate: nil)
        await activity.update(content)
    }

    private func endStaleActivities() {
        for existing in Activity<ReviewActivityAttributes>.activities {
            Task {
                await existing.end(nil, dismissalPolicy: .immediate)
            }
        }
    }
}
