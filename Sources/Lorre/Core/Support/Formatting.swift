import Foundation

enum Formatters {
    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let minutes = total / 60
        let secs = total % 60
        return String(format: "%02d:%02d", minutes, secs)
    }

    static func timestamp(ms: Int) -> String {
        let clamped = max(0, ms)
        let totalSeconds = clamped / 1000
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        let millis = clamped % 1000
        return String(format: "%02d:%02d.%03d", minutes, seconds, millis)
    }

    static func sessionMetadata(date: Date, durationSeconds: Double?) -> String {
        let dateString = date.formatted(date: .abbreviated, time: .shortened)
        if let durationSeconds {
            return "\(dateString) • \(duration(durationSeconds))"
        }
        return dateString
    }
}
