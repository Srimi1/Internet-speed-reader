import os

public enum Log {
    public static let subsystem = "com.srimi.internetspeedreader"

    public static let live = Logger(subsystem: subsystem, category: "live")
    public static let outage = Logger(subsystem: subsystem, category: "outage")
    public static let speedTest = Logger(subsystem: subsystem, category: "speedtest")
    public static let app = Logger(subsystem: subsystem, category: "app")
}
