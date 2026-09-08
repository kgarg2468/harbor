import Foundation
import os

/// Persistent diagnostics keep static context; dynamic values stay private in
/// unified logging and are never copied to the plain-text diagnostic history.
enum Log {
    static let logger = Logger(subsystem: Paths.bundleIdentifier, category: "core")

    struct Message: ExpressibleByStringLiteral, ExpressibleByStringInterpolation {
        let persisted: String
        let detail: String
        init(stringLiteral value: String) { persisted = value; detail = value }
        init(stringInterpolation: StringInterpolation) {
            persisted = stringInterpolation.persisted
            detail = stringInterpolation.detail
        }
        struct StringInterpolation: StringInterpolationProtocol {
            var persisted = ""
            var detail = ""
            init(literalCapacity: Int, interpolationCount: Int) {}
            mutating func appendLiteral(_ value: String) { persisted += value; detail += value }
            mutating func appendInterpolation<T>(_ value: T) {
                persisted += "<private>"
                detail += String(describing: value)
            }
        }
    }

    static func info(_ message: Message) {
        logger.info("\(message.detail, privacy: .private)")
        append(level: "info", message)
    }

    static func error(_ message: Message) {
        logger.error("\(message.detail, privacy: .private)")
        append(level: "error", message)
    }

    // A runtime String has lost interpolation boundaries. Keep it exclusively
    // in private unified logging, with a static code in the persistent file.
    @_disfavoredOverload static func info(_ message: String) {
        logger.info("\(message, privacy: .private)")
        append(level: "info", Message(stringLiteral: "diagnostic.info"))
    }

    @_disfavoredOverload static func error(_ message: String) {
        logger.error("\(message, privacy: .private)")
        append(level: "error", Message(stringLiteral: "diagnostic.error"))
    }

    @_disfavoredOverload static func append(level: String, _ message: String, paths: Paths = .fromEnvironment()) {
        append(level: level, Message(stringLiteral: "diagnostic.event"), paths: paths)
    }

    static func append(level: String, _ message: Message, paths: Paths = .fromEnvironment()) {
        let now = Date().formatted(.iso8601.year().month().day().dateTimeSeparator(.standard).time(includingFractionalSeconds: false).timeZone(separator: .omitted))
        let severity = level == "error" ? "error" : "info"
        let line = "\(now) [\(severity)] insomnia: \(message.persisted)"
        do {
            try PrivateFiles.directory(paths.appSupport)
            try JournalLock.withLock(at: paths.recoveryLock) {
                try PrivateFiles.directory(paths.logs)
                // Older diagnostic logs may contain SSIDs, pane names, or paths.
                // Archive them privately once; never include this history in
                // new diagnostic output. Structured outage history stays intact.
                let marker = paths.logs.appendingPathComponent(".diagnostic-privacy-v1")
                if !FileManager.default.fileExists(atPath: marker.path) {
                    let legacy = paths.logs.appendingPathComponent("legacy-diagnostics", isDirectory: true)
                    for old in [paths.logFile, paths.logFile.appendingPathExtension("1")] {
                        guard FileManager.default.fileExists(atPath: old.path) else { continue }
                        let previous = try PrivateFiles.handle(old, flags: O_RDONLY)
                        try previous.close()
                        try PrivateFiles.directory(legacy)
                        let destination = legacy.appendingPathComponent("\(UUID().uuidString)-\(old.lastPathComponent)")
                        try FileManager.default.moveItem(at: old, to: destination)
                    }
                    try PrivateFiles.write(Data("1\n".utf8), to: marker, exclusive: true)
                }
                for history in [paths.handoffsLog, paths.handoffsLog.appendingPathExtension("1")] {
                    if FileManager.default.fileExists(atPath: history.path) {
                        let handle = try PrivateFiles.handle(history, flags: O_RDONLY)
                        try handle.close()
                    }
                }
                try PrivateFiles.appendRecord(line, to: paths.logFile)
            }
        } catch {
            // Diagnostics are best effort and must never block recovery.
            logger.error("diagnostic append unavailable: \(error.localizedDescription, privacy: .private)")
        }
    }
}
