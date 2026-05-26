import Foundation
import os

public enum Log {
    private static let subsystem = "com.lhdev.parallax"

    public static let network = Logger(subsystem: subsystem, category: "network")
    public static let playback = Logger(subsystem: subsystem, category: "playback")
    public static let auth = Logger(subsystem: subsystem, category: "auth")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
    public static let persistence = Logger(subsystem: subsystem, category: "persistence")
}
