import Foundation
import Combine

struct CaptionEntry: Identifiable, Equatable {
    enum Kind { case pending, success, error, status }
    let id: String
    var text: String
    var source: String
    var time: Date
    var kind: Kind
    var note: String = ""     // 进行中的补充说明（如“思考中… 300 字”）
}

/// 字幕窗口的数据：最新在最上。
final class CaptionModel: ObservableObject {
    @Published var entries: [CaptionEntry] = []
    @Published var isPaused = false
    @Published var phoneConnected = false

    func apply(_ event: PipelineEvent, maxCount: Int) {
        switch event {
        case let .started(id, source):
            if let i = entries.firstIndex(where: { $0.id == id }) {
                entries[i].text = ""
                entries[i].note = ""
                entries[i].kind = .pending
                entries[i].time = Date()
            } else {
                entries.insert(CaptionEntry(id: id, text: "", source: source, time: Date(), kind: .pending), at: 0)
            }
        case let .thinking(id, chars):
            if let i = entries.firstIndex(where: { $0.id == id }), entries[i].kind == .pending {
                entries[i].note = "思考中… \(chars) 字"
            }
        case let .partial(id, delta):
            if let i = entries.firstIndex(where: { $0.id == id }) {
                entries[i].text += delta
                entries[i].note = ""
            }
        case let .completed(id, text, source, _, _):
            if let i = entries.firstIndex(where: { $0.id == id }) {
                entries[i].text = text
                entries[i].kind = .success
                entries[i].time = Date()
            } else {
                entries.insert(CaptionEntry(id: id, text: text, source: source, time: Date(), kind: .success), at: 0)
            }
        case let .failed(id, message, source):
            if let i = entries.firstIndex(where: { $0.id == id }) {
                entries[i].text = message
                entries[i].kind = .error
            } else {
                entries.insert(CaptionEntry(id: id, text: message, source: source ?? "", time: Date(), kind: .error), at: 0)
            }
        case let .status(message, _):
            entries.insert(CaptionEntry(id: UUID().uuidString, text: message, source: "", time: Date(), kind: .status), at: 0)
        }
        let limit = max(1, maxCount)
        if entries.count > limit {
            // 优先保留进行中的条目
            var kept: [CaptionEntry] = []
            for e in entries where kept.count < limit || e.kind == .pending { kept.append(e) }
            entries = kept
        }
    }

    func clear() { entries.removeAll() }
}
