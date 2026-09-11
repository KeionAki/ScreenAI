import Foundation
import ImageIO
import CoreGraphics

/// 命令行诊断模式：`ScreenAI --analyze-image <路径> [--no-stream] [--prompt 文本] [--raw]`
/// 走与快捷键完全相同的编码与 AI 调用路径，逐行打印事件，用于排查模型返回问题。API Key 不会输出。
enum DiagnosticRunner {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard let idx = args.firstIndex(of: "--analyze-image"), idx + 1 < args.count else { return }
        let path = args[idx + 1]
        let noStream = args.contains("--no-stream")
        let raw = args.contains("--raw")
        var promptOverride: String?
        if let p = args.firstIndex(of: "--prompt"), p + 1 < args.count { promptOverride = args[p + 1] }
        setvbuf(stdout, nil, _IONBF, 0)
        let code = run(path: path, stream: !noStream, raw: raw, promptOverride: promptOverride)
        exit(code)
    }

    private static func run(path: String, stream: Bool, raw: Bool, promptOverride: String?) -> Int32 {
        let start = Date()
        func stamp() -> String { String(format: "[%6.2fs]", Date().timeIntervalSince(start)) }
        func log(_ s: String) { print("\(stamp()) \(s)") }

        let settings = SettingsStore.shared
        let url = URL(fileURLWithPath: path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            print("无法读取图片：\(path)")
            return 2
        }
        log("图片: \(image.width)x\(image.height) ← \(url.lastPathComponent)")
        guard let encoded = ImageEncoder.encode(image, maxLongEdge: settings.maxImageLongEdge, quality: settings.jpegQuality) else {
            print("图片编码失败")
            return 2
        }
        log("编码: \(encoded.width)x\(encoded.height), \(encoded.byteCount / 1024) KB JPEG, base64 \(encoded.base64.count) 字符")

        let kind = settings.apiProvider
        let apiKey = settings.apiKey(for: kind)
        let config = ProviderConfig(kind: kind, apiKey: apiKey, endpoint: settings.currentEndpoint)
        let params = settings.params(for: kind)
        log("配置: provider=\(kind.rawValue) endpoint=\(settings.currentEndpoint.isEmpty ? "(默认)" : settings.currentEndpoint) model=\(settings.currentModel) stream=\(stream) timeout=\(Int(settings.apiTimeout))s apiKey=\(apiKey.isEmpty ? "未设置" : "已设置(\(apiKey.count) 字符)")")
        log("参数: maxTokens=\(params.maxTokens) thinking=\(params.thinking) effort=\(params.reasoningEffort) temperature=\(params.temperature.map { String($0) } ?? "不发送") top_p=\(params.topP.map { String($0) } ?? "不发送") detail=\(params.imageDetail)\(kind == .custom && !params.extraJSON.isEmpty ? " extra=\(params.extraJSON.truncated(80))" : "")")
        let prompt = promptOverride ?? settings.promptTemplate
        log("提示词: \(prompt.truncated(80))")

        if raw {
            AIHTTP.rawLineHandler = { line in print("    RAW| \(line.truncated(400))") }
        }

        let provider = AIProviderFactory.make(config)
        let request = AIRequest(imageBase64: encoded.base64, prompt: prompt, model: settings.currentModel,
                                timeout: settings.apiTimeout, stream: stream, params: params)

        let done = DispatchSemaphore(value: 0)
        final class Box { var code: Int32 = 0 }
        let box = Box()
        Task.detached {
            var text = ""
            var reasoningChars = 0
            var lastReasoningLog = Date.distantPast
            var finish: String?
            do {
                log("请求已发送，等待响应…")
                for try await ev in provider.analyze(request) {
                    switch ev {
                    case .text(let d):
                        if text.isEmpty { log("正文开始") }
                        text += d
                        print(d, terminator: "")
                    case .reasoning(let d):
                        reasoningChars += d.count
                        if Date().timeIntervalSince(lastReasoningLog) > 1 {
                            lastReasoningLog = Date()
                            log("思考中… 累计 \(reasoningChars) 字")
                        }
                    case .finished(let r):
                        finish = r
                    }
                }
                if !text.isEmpty { print() }
                log("结束原因: \(finish ?? "未提供")")
                log("结果: 正文 \(text.count) 字，思考 \(reasoningChars) 字，耗时 \(String(format: "%.1f", Date().timeIntervalSince(start))) 秒")
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    log("⚠️ 正文为空" + (finish == "length" ? "：达到最大输出 tokens" : (reasoningChars > 0 ? "：模型只返回了思考内容" : "")))
                    box.code = 3
                }
            } catch {
                let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                log("❌ 错误: \(msg)")
                box.code = 1
            }
            done.signal()
        }
        if done.wait(timeout: .now() + settings.apiTimeout * 2 + 30) == .timedOut {
            log("❌ 诊断超时")
            return 4
        }
        return box.code
    }
}
