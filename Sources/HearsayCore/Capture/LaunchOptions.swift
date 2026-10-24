import Foundation

/// App launch arguments. `--root` is used for this run only and never saved to defaults.
public struct LaunchOptions: Sendable, Equatable {
    public var recordFor: TimeInterval?
    public var root: URL?
    public var afterCrash = false
    public var resumeRecording = false

    /// `--record-for` or `--root`: a test instance. It shares the app's defaults, so it skips crash-report
    /// notifications, dictation and crash relaunch.
    public var isTestInstance: Bool { recordFor != nil || root != nil }

    public init(recordFor: TimeInterval? = nil, root: URL? = nil, afterCrash: Bool = false, resumeRecording: Bool = false) {
        self.recordFor = recordFor; self.root = root; self.afterCrash = afterCrash; self.resumeRecording = resumeRecording
    }

    /// Unknown arguments (AppKit's `-NSDocumentRevisionsDebugMode` and the like) are ignored.
    public static func parse(_ args: [String]) -> LaunchOptions {
        var o = LaunchOptions()
        var i = 0
        while i < args.count {
            let a = args[i]
            func value() -> String? { i + 1 < args.count ? args[i + 1] : nil }
            switch a {
            case "--record-for":
                if let v = value(), let n = TimeInterval(v), n > 0 { o.recordFor = n; i += 1 }
            case "--root":
                if let v = value() {
                    o.root = URL(fileURLWithPath: (v as NSString).expandingTildeInPath, isDirectory: true)
                    i += 1
                }
            case "--after-crash": o.afterCrash = true
            case "--resume-recording": o.resumeRecording = true
            default: break
            }
            i += 1
        }
        return o
    }
}
