import Foundation

struct SSEEvent: Equatable {
    var event: String?
    var data: String
}

/// 逐行喂入的 Server-Sent Events 解析器。
struct SSEParser {
    private var event: String?
    private var dataLines: [String] = []

    mutating func feed(line raw: String) -> SSEEvent? {
        var line = raw
        if line.hasSuffix("\r") { line.removeLast() }
        if line.isEmpty {
            guard !dataLines.isEmpty else { event = nil; return nil }
            let ev = SSEEvent(event: event, data: dataLines.joined(separator: "\n"))
            event = nil
            dataLines = []
            return ev
        }
        if line.hasPrefix(":") { return nil }
        let field: String
        var value: String
        if let idx = line.firstIndex(of: ":") {
            field = String(line[..<idx])
            value = String(line[line.index(after: idx)...])
            if value.hasPrefix(" ") { value.removeFirst() }
        } else {
            field = line
            value = ""
        }
        switch field {
        case "event": event = value
        case "data": dataLines.append(value)
        default: break
        }
        return nil
    }

    /// 流结束时把未以空行终止的数据也吐出来
    mutating func flush() -> SSEEvent? {
        feed(line: "")
    }
}
