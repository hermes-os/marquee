import Foundation

// MARK: - App Error

enum AppError: Identifiable {
    case fileNotFound(path: String)
    case scanFailed(directory: String)
    case playbackFailed(title: String)

    var id: String {
        switch self {
        case .fileNotFound(let path): return "fileNotFound:\(path)"
        case .scanFailed(let dir): return "scanFailed:\(dir)"
        case .playbackFailed(let title): return "playbackFailed:\(title)"
        }
    }

    var title: String {
        switch self {
        case .fileNotFound: return "File Not Found"
        case .scanFailed: return "Scan Failed"
        case .playbackFailed: return "Playback Error"
        }
    }

    var message: String {
        switch self {
        case .fileNotFound(let path):
            let name = (path as NSString).lastPathComponent
            return "Could not locate \"\(name)\". The file may have been moved or deleted."
        case .scanFailed(let directory):
            return "Could not access \"\(directory)\". Check that the volume is mounted."
        case .playbackFailed(let title):
            return "Unable to play \"\(title)\". The file may be corrupted or in an unsupported format."
        }
    }
}
