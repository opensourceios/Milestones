import Combine
import ComposableArchitecture
import Foundation

// MARK: - State

struct AppState: Equatable {
    var milestones: [Milestone]

    mutating func setToday(_ today: Date) {
        milestones = milestones.map { milestone in
            var result = milestone
            result.today = today
            return result
        }
    }
}

// MARK: - Action

enum AppAction: Equatable {
    case setTimerActive(Bool)
    case timerTicked
    case addButtonTapped
    case milestone(index: Int, action: MilestoneAction)
    case persistToDisk
}

// MARK: - Environment

struct AppEnvironment {
    let uuid: () -> UUID
    let persist: ([Milestone]) -> Void
    var startOfDay: () -> Date
    var calendar: Calendar
    var mainQueue: AnySchedulerOf<DispatchQueue>
    var persistenceQueue: AnySchedulerOf<DispatchQueue>
}

// MARK: - Reducer

let appReducer = Reducer<AppState, AppAction, AppEnvironment>.combine(
    milestoneReducer.forEach(
        state: \AppState.milestones,
        action: /AppAction.milestone,
        environment: { _ in MilestoneEnvironment() }
    ),
    Reducer { state, action, environment in
        switch action {
        case .setTimerActive(let timerActive):
            state.setToday(environment.startOfDay())

            struct TimerID: Hashable {}

            return timerActive ?
                Effect.timer(id: TimerID(), every: 1, on: environment.mainQueue)
                .map { _ in .timerTicked }
                : Effect.cancel(id: TimerID())
        case .timerTicked:
            state.setToday(environment.startOfDay())
            return .none
        case .addButtonTapped:
            let startOfDay = environment.startOfDay()
            let calendar = environment.calendar
            state.milestones.append(
                Milestone(id: environment.uuid(), calendar: calendar, title: "", today: startOfDay, date: startOfDay,
                          isEditing: true)
            )
            state.milestones.sort()
            return .none
        case .milestone(index: let index, action: .delete):
            state.milestones.remove(at: index)
            return .none
        case .milestone:
            state.milestones.sort()
            return .none
        case .persistToDisk:
            return .none
        }
    }
)
.persisting()

// MARK: - Persistence

private struct PersistID: Hashable {}

private extension Reducer where State == AppState, Action == AppAction, Environment == AppEnvironment {
    /// Persists milestones when they change.
    func persisting() -> Reducer {
        return Reducer { state, action, environment in
            // Handle the `.persistToDisk` action specifically.
            let forcePersist = action == .persistToDisk

            // Run the upstream app reducer.
            let previousState = state
            let effect = self(&state, action, environment)
            let newMilestones = state.milestones

            let persistEffect: Effect<AppAction, Never>
            if forcePersist {
                // If we're forcing persistence, do so synchronously.
                persistEffect = Effect.fireAndForget { environment.persist(newMilestones) }
                    .cancellable(id: PersistID())
            } else if newMilestones != previousState.milestones {
                // Otherwise persist in the background only if the milestones have changed.
                // Debounce every 10 seconds to avoid thrash.
                persistEffect = Effect.fireAndForget { environment.persist(newMilestones) }
                    .subscribe(on: environment.persistenceQueue)
                    .eraseToEffect()
                    .debounce(id: PersistID(), for: 10, scheduler: environment.persistenceQueue)
            } else {
                // If we're not forcing persistence, and the milestones haven't changed, immediately return the upstream
                // reducer's effect.
                return effect
            }

            // If milestones change, persist in a debounced fashion in the background.
            return .merge(effect, persistEffect)
        }
    }
}
