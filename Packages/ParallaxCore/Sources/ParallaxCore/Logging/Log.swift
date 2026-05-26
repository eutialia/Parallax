import Foundation
import os

public enum Log {
    private static let subsystem = "com.lhdev.parallax"

    @available(macOS 11.0, iOS 14.0, *)
    public static let network = Logger(subsystem: subsystem, category: "network")
    @available(macOS 11.0, iOS 14.0, *)
    public static let playback = Logger(subsystem: subsystem, category: "playback")
    @available(macOS 11.0, iOS 14.0, *)
    public static let auth = Logger(subsystem: subsystem, category: "auth")
    @available(macOS 11.0, iOS 14.0, *)
    public static let ui = Logger(subsystem: subsystem, category: "ui")
    @available(macOS 11.0, iOS 14.0, *)
    public static let persistence = Logger(subsystem: subsystem, category: "persistence")
}
