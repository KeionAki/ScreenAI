import Foundation

/// 从模型回答中提取代码块。提示词要求编程题必须用 ``` 包裹，选择/填空题不得使用 ```，
/// 因此「是否含围栏代码块」即可作为「是否编程题」的判据。
enum CodeExtractor {
    static let fence = "```"

    /// 是否包含（哪怕尚未闭合的）代码块围栏
    static func containsCodeBlock(_ text: String) -> Bool {
        text.contains(fence)
    }

    /// 提取第一个代码块的内容；去掉围栏与语言标识。
    /// 围栏未闭合（流式中途）时，返回已收到的部分。
    static func extract(_ text: String) -> String? {
        guard let open = text.range(of: fence) else { return nil }
        // 跳过语言标识：围栏后到行尾的内容
        var bodyStart = open.upperBound
        if let newline = text[bodyStart...].firstIndex(of: "\n") {
            let lang = text[bodyStart..<newline]
            // 语言标识必须是单个词；否则视为正文紧跟在围栏后
            if lang.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "#" || $0 == "-" || $0 == "_" }) {
                bodyStart = text.index(after: newline)
            }
        }
        let rest = text[bodyStart...]
        let body: Substring
        if let close = rest.range(of: fence) {
            body = rest[..<close.lowerBound]
        } else {
            body = rest
        }
        let code = String(body).trimmingCharacters(in: CharacterSet(charactersIn: "\n\r"))
        return code.isEmpty ? nil : code
    }

    /// 供键入使用：优先取代码块；没有围栏时退回整段文本（去首尾空白）。
    static func codeToType(_ text: String) -> String? {
        if let c = extract(text) { return c }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// 把制表符换成空格，并统一换行符，便于逐字键入
    static func normalize(_ code: String, tabWidth: Int) -> String {
        let spaces = String(repeating: " ", count: max(1, tabWidth))
        return code
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: spaces)
    }
}
