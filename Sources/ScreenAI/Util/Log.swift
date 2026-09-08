import Foundation
import os

enum Log {
    static let subsystem = "com.li.screenai"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let capture = Logger(subsystem: subsystem, category: "capture")
    static let ai = Logger(subsystem: subsystem, category: "ai")
    static let server = Logger(subsystem: subsystem, category: "server")
    static let history = Logger(subsystem: subsystem, category: "history")
    static let pairing = Logger(subsystem: subsystem, category: "pairing")
}
