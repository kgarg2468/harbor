import Foundation

enum ShellTimeoutError: Error, LocalizedError {
    case timedOut(exe: String, seconds: TimeInterval)

    var errorDescription: String? {
        switch self {
        case let .timedOut(exe, seconds):
            return "\(exe) did not finish within \(Int(seconds)) s"
        }
    }
}

extension Shell {
    /// First existing path among `candidates`, or nil.
    static func locate(_ candidates: [String]) -> String? {
        candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}
