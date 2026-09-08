import Foundation

/// RFC 4180 兼容的 CSV 编解码（按 Unicode 标量处理，正确区分 CR / LF / CRLF）。
enum CSV {
    static func escape(_ field: String) -> String {
        let needsQuote = field.unicodeScalars.contains { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }
        guard needsQuote else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func line(_ fields: [String]) -> String {
        fields.map(escape).joined(separator: ",") + "\r\n"
    }

    /// 解析整段 CSV 文本，返回记录数组（不做表头处理）。
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = String.UnicodeScalarView()
        var inQuotes = false
        var iterator = text.unicodeScalars.makeIterator()
        var pending: Unicode.Scalar? = nil

        func next() -> Unicode.Scalar? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }
        func endField() { row.append(String(field)); field = String.UnicodeScalarView() }
        func endRow() { endField(); rows.append(row); row = [] }

        while let c = next() {
            if inQuotes {
                if c == "\"" {
                    if let n = next() {
                        if n == "\"" { field.append("\"") } else { inQuotes = false; pending = n }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
            } else {
                switch c {
                case "\"":
                    inQuotes = true
                case ",":
                    endField()
                case "\r":
                    if let n = next(), n != "\n" { pending = n }
                    endRow()
                case "\n":
                    endRow()
                default:
                    field.append(c)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }
}
