import Foundation

enum T {
    static var passes = 0
    static var failures = 0

    static func check(_ cond: Bool, _ msg: String, file: String = #file, line: Int = #line) {
        if cond { passes += 1 } else {
            failures += 1
            print("  FAIL: \(msg)  [\((file as NSString).lastPathComponent):\(line)]")
        }
    }

    static func equal<V: Equatable>(_ a: V, _ b: V, _ msg: String, file: String = #file, line: Int = #line) {
        if a == b { passes += 1 } else {
            failures += 1
            print("  FAIL: \(msg): \(String(describing: a)) != \(String(describing: b))  [\((file as NSString).lastPathComponent):\(line)]")
        }
    }

    static func run(_ name: String, _ body: () throws -> Void) {
        let before = failures
        do { try body() } catch {
            failures += 1
            print("  FAIL: \(name) threw \(error)")
        }
        print((failures == before ? "ok   " : "FAIL ") + name)
    }
}
