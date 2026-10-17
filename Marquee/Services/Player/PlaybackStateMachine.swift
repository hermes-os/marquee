import Foundation

// MARK: - Playback Lifecycle

enum PlaybackLifecycleState: String, Codable, Equatable, CustomStringConvertible {
    case idle
    case preparing
    case ready
    case loading
    case playing
    case paused
    case seeking
    case ended
    case failed
    case stopped

    var description: String { rawValue }
}

enum PlaybackLifecycleEvent: Equatable {
    case prepare
    case rendererReady
    case loadRequested
    case startFile
    case fileLoaded
    case pause
    case resume
    case seekRequested
    case seekCompleted
    case ended
    case stop
    case fail(String)
}

struct PlaybackStateMachine {
    private(set) var state: PlaybackLifecycleState = .idle
    private var stateBeforeSeeking: PlaybackLifecycleState?

    @discardableResult
    mutating func apply(_ event: PlaybackLifecycleEvent) throws -> PlaybackLifecycleState {
        let next = try nextState(for: event)
        if event == .seekRequested {
            stateBeforeSeeking = state
        } else if event == .seekCompleted || event == .stop || event == .ended {
            stateBeforeSeeking = nil
        }
        state = next
        return next
    }

    private func nextState(for event: PlaybackLifecycleEvent) throws -> PlaybackLifecycleState {
        switch event {
        case .prepare:
            switch state {
            case .idle, .stopped, .failed:
                return .preparing
            default:
                throw invalid(event)
            }

        case .rendererReady:
            switch state {
            case .preparing:
                return .ready
            case .ready, .loading, .playing, .paused, .seeking, .ended, .stopped, .failed:
                return state
            default:
                throw invalid(event)
            }

        case .loadRequested:
            switch state {
            case .idle, .preparing, .ready, .loading, .playing, .paused, .seeking, .ended, .stopped, .failed:
                return .loading
            default:
                throw invalid(event)
            }

        case .startFile:
            switch state {
            case .loading:
                return .loading
            default:
                throw invalid(event)
            }

        case .fileLoaded:
            switch state {
            case .loading, .playing:
                return .playing
            case .paused:
                return .paused
            default:
                throw invalid(event)
            }

        case .pause:
            switch state {
            case .loading, .playing, .seeking:
                return .paused
            case .paused:
                return .paused
            default:
                throw invalid(event)
            }

        case .resume:
            switch state {
            case .paused:
                return .playing
            case .playing:
                return .playing
            default:
                throw invalid(event)
            }

        case .seekRequested:
            switch state {
            case .playing, .paused:
                return .seeking
            case .loading:
                return .loading
            default:
                throw invalid(event)
            }

        case .seekCompleted:
            switch state {
            case .seeking:
                return stateBeforeSeeking == .paused ? .paused : .playing
            case .loading:
                return .loading
            default:
                throw invalid(event)
            }

        case .ended:
            switch state {
            case .loading, .playing, .paused, .ended:
                return .ended
            default:
                throw invalid(event)
            }

        case .stop:
            return .stopped

        case .fail:
            return .failed
        }
    }

    private func invalid(_ event: PlaybackLifecycleEvent) -> PlaybackStateMachineError {
        PlaybackStateMachineError.invalidTransition(from: state, event: event)
    }
}

enum PlaybackStateMachineError: Error, CustomStringConvertible {
    case invalidTransition(from: PlaybackLifecycleState, event: PlaybackLifecycleEvent)

    var description: String {
        switch self {
        case .invalidTransition(let state, let event):
            return "invalid transition from \(state) on \(event)"
        }
    }
}
