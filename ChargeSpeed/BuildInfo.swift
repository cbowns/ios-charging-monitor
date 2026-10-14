import Foundation

/// What's installed: version, build, and the git commit and time stamped into Info.plist by
/// the "Stamp build info" build phase (see project.yml).
enum BuildInfo {
    private static let info = Bundle.main.infoDictionary ?? [:]

    static let version = info["CFBundleShortVersionString"] as? String ?? "?"
    static let build = info["CFBundleVersion"] as? String ?? "?"
    /// Short hash, with "-dirty" when built from uncommitted changes.
    static let commit = info["GitCommit"] as? String ?? "unknown"
    static let date: Date? = (info["BuildDate"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }

    /// "0.1.0 (1) · c756e32 · built Oct 14, 3:20 PM"
    static var summary: String {
        var text = "\(version) (\(build)) · \(commit)"
        if let date { text += " · built " + date.formatted(date: .abbreviated, time: .shortened) }
        return text
    }
}
