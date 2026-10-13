import Foundation
import OSLog

/// Structured RE2 client logs — filter Console / simctl with:
/// `subsystem == "com.foqerhk.koko" AND category == "RE2"`
enum RE2Log {
    static let logger = Logger(subsystem: "com.foqerhk.koko", category: "RE2")

    static func info(_ message: String) {
#if DEBUG
        logger.info("\(message, privacy: .public)")
        // Also mirror to stderr so `simctl launch --console` / Xcode console catch it.
        fputs("RE2 \(message)\n", stderr)
        fflush(stderr)
#else
        logger.info("\(message, privacy: .private(mask: .hash))")
#endif
    }

    static func error(_ message: String) {
#if DEBUG
        logger.error("\(message, privacy: .public)")
        fputs("RE2 ERROR \(message)\n", stderr)
        fflush(stderr)
#else
        logger.error("\(message, privacy: .private(mask: .hash))")
#endif
    }
}
