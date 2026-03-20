import Foundation

// MARK: - Meeting State

/// The lifecycle state of a meeting recording session.
/// Designed as a pure value type for testability.
enum MeetingState: Sendable, Equatable {
    /// No active session. The system is waiting.
    case idle

    /// A session is actively recording.
    case recording(MeetingMetadata)

    /// Recording has stopped; the session is being finalized (draining audio, writing files).
    case ending(MeetingMetadata)
}

// MARK: - Meeting Event

/// Events that drive state transitions in the meeting lifecycle.
enum MeetingEvent: Sendable {
    /// The user pressed Start.
    case userStarted(MeetingMetadata)

    /// The user pressed Stop.
    case userStopped

    /// The user discarded the current session (delete files, return to idle).
    case userDiscarded

    /// Finalization (drain + write sidecar) completed.
    case finalizationComplete

    /// Finalization timed out. Force transition to idle.
    case finalizationTimeout
}

// MARK: - Pure Transition Function

/// Pure function: given a state and event, returns the next state.
/// No side effects. All side effects are dispatched by the coordinator after transition.
func transition(from state: MeetingState, on event: MeetingEvent) -> MeetingState {
    switch (state, event) {

    // idle + userStarted -> recording
    case (.idle, .userStarted(let metadata)):
        return .recording(metadata)

    // recording + userStopped -> ending
    case (.recording(let metadata), .userStopped):
        return .ending(metadata)

    // recording + userDiscarded -> idle (discard without finalizing)
    case (.recording, .userDiscarded):
        return .idle

    // ending + finalizationComplete -> idle
    case (.ending, .finalizationComplete):
        return .idle

    // ending + finalizationTimeout -> idle (forced)
    case (.ending, .finalizationTimeout):
        return .idle

    // All other combinations are no-ops (e.g., double-start, stop while idle)
    default:
        return state
    }
}
