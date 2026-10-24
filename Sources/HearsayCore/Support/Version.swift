import os

public enum HearsayCore {
    public static let version = "0.1.0"
    public static let subsystem = "com.tannervass.hearsay"

    static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }
}
