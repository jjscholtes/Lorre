import Foundation

enum Formatters {
    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }

    static func timestamp(ms: Int) -> String {
        let clamped = max(0, ms)
        let totalSeconds = clamped / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        let millis = clamped % 1000
        if hours > 0 {
            return String(format: "%02d:%02d:%02d.%03d", hours, minutes, seconds, millis)
        }
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
