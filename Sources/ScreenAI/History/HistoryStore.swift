import Foundation
import CryptoKit

/// CSV 历史记录：按日分文件，追加写入；prompts.json 记录提示词哈希 → 全文。
final class HistoryStore {
    private let queue = DispatchQueue(label: "com.li.screenai.history", qos: .utility)
    private var directory: URL
    private var pendingRetry: [HistoryRecord] = []
    private var promptCache: [String: String] = [:]
    var onWriteError: ((String) -> Void)?

    init(directory: URL) {
        self.directory = directory
        queue.async { self.loadPrompts() }
    }

    func setDirectory(_ url: URL) {
        queue.sync {
            directory = url
            promptCache = [:]
            loadPrompts()
        }
    }

    var directoryURL: URL { queue.sync { directory } }

    // MARK: Prompt registry

    static func hash(of prompt: String) -> String {
        let digest = SHA256.hash(data: Data(prompt.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    /// 返回提示词哈希，并在需要时写入 prompts.json
    func registerPrompt(_ prompt: String) -> String {
        let h = HistoryStore.hash(of: prompt)
        queue.async {
            if self.promptCache[h] == nil {
                self.promptCache[h] = prompt
                self.savePrompts()
            }
        }
        return h
    }

    func prompt(forHash h: String) -> String? { queue.sync { promptCache[h] } }

    private var promptsURL: URL { directory.appendingPathComponent("prompts.json") }

    private func loadPrompts() {
        guard let data = try? Data(contentsOf: promptsURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String] else { return }
        promptCache = obj
    }

    private func savePrompts() {
        do {
            try ensureDirectory()
            let data = try JSONSerialization.data(withJSONObject: promptCache, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: promptsURL, options: .atomic)
        } catch {
            Log.history.error("保存 prompts.json 失败: \(error.localizedDescription)")
        }
    }

    // MARK: Write

    func append(_ record: HistoryRecord) {
        queue.async {
            self.pendingRetry.append(record)
            self.flushPending()
        }
    }

    private func flushPending() {
        while let r = pendingRetry.first {
            do {
                try write(r)
                pendingRetry.removeFirst()
            } catch {
                Log.history.error("写入 CSV 失败: \(error.localizedDescription)")
                if pendingRetry.count > 10 { pendingRetry.removeFirst(pendingRetry.count - 10) }
                onWriteError?(error.localizedDescription)
                queue.asyncAfter(deadline: .now() + 15) { self.flushPending() }
                return
            }
        }
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(for day: String) -> URL {
        directory.appendingPathComponent("\(day).csv")
    }

    private func write(_ r: HistoryRecord) throws {
        try ensureDirectory()
        let url = fileURL(for: DayKey.string(r.timestamp))
        let exists = FileManager.default.fileExists(atPath: url.path)
        if !exists {
            let bom = "\u{FEFF}"
            try (bom + CSV.line(HistoryRecord.csvHeader)).write(to: url, atomically: true, encoding: .utf8)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(CSV.line(r.csvFields).utf8))
        try handle.synchronize()
    }

    // MARK: Read

    func dates() -> [String] {
        queue.sync {
            let items = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            return items.compactMap { name -> String? in
                guard name.hasSuffix(".csv") else { return nil }
                let day = String(name.dropLast(4))
                return DayKey.isValid(day) ? day : nil
            }.sorted(by: >)
        }
    }

    func records(date: String) -> [HistoryRecord] {
        queue.sync { readRecords(day: date) }
    }

    private func readRecords(day: String) -> [HistoryRecord] {
        guard DayKey.isValid(day), var text = try? String(contentsOf: fileURL(for: day), encoding: .utf8) else { return [] }
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let rows = CSV.parse(text)
        return rows.dropFirst().compactMap { HistoryRecord(csvFields: $0) }
    }

    func search(query: String, dates: [String]? = nil, limit: Int = 500) -> [HistoryRecord] {
        let days = dates ?? self.dates()
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        var out: [HistoryRecord] = []
        for day in days {
            let recs = records(date: day).reversed()
            for r in recs {
                if q.isEmpty || r.result.lowercased().contains(q) || r.captureSource.lowercased().contains(q) || r.errorMessage.lowercased().contains(q) {
                    out.append(r)
                    if out.count >= limit { return out }
                }
            }
        }
        return out
    }

    func exportCSV(dates: [String]) -> String {
        var s = CSV.line(HistoryRecord.csvHeader)
        for day in dates.sorted() {
            for r in records(date: day) { s += CSV.line(r.csvFields) }
        }
        return s
    }

    func exportCSV(records: [HistoryRecord]) -> String {
        var s = CSV.line(HistoryRecord.csvHeader)
        for r in records { s += CSV.line(r.csvFields) }
        return s
    }

    func clearAll() throws {
        try queue.sync {
            let fm = FileManager.default
            let items = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in items where name.hasSuffix(".csv") {
                try fm.removeItem(at: directory.appendingPathComponent(name))
            }
        }
    }
}
