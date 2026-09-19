import Foundation
import AppKit

/// 一次分析所需的配置快照（在主线程从设置读取）
struct AnalysisConfig {
    var providerKind: AIProviderKind
    var apiKey: String
    var endpoint: String
    var model: String
    var prompt: String
    var timeout: TimeInterval
    var stream: Bool
    var maxLongEdge: Int
    var jpegQuality: Double
    var params: ProviderParams

    var providerConfig: ProviderConfig { ProviderConfig(kind: providerKind, apiKey: apiKey, endpoint: endpoint) }
}

struct AnalysisJob {
    let id: String
    let createdAt: Date
    let source: String
    let image: CGImage
    var encoded: EncodedImage
    let config: AnalysisConfig
}

enum PipelineEvent {
    case started(id: String, source: String)
    case thinking(id: String, chars: Int)
    case partial(id: String, delta: String)
    case completed(id: String, text: String, source: String, model: String, latencyMs: Int)
    case failed(id: String, message: String, source: String?)
    case status(message: String, level: String)   // info / warning
}

/// 截图 → 编码 → AI → 事件分发。队列最多 3 个，串行执行；截图在触发瞬间完成。
/// 所有可变状态只在主线程访问；onEvent 在主线程回调。
final class AnalysisPipeline {
    static let maxQueue = 3

    private let settings: SettingsStore
    private let history: HistoryStore
    private let captureQueue = DispatchQueue(label: "com.li.screenai.capture", qos: .userInitiated)
    private var pending: [AnalysisJob] = []
    private var active: AnalysisJob?
    private var lastTrigger = Date.distantPast
    private var lastSignature: [UInt8]?
    /// 定时捕获因画面无变化而跳过的次数（供菜单显示）
    private(set) var skippedUnchanged = 0

    var onEvent: ((PipelineEvent) -> Void)?
    var onCaptureDisabled: (() -> Void)?

    init(settings: SettingsStore, history: HistoryStore) {
        self.settings = settings
        self.history = history
    }

    var isBusy: Bool { active != nil || !pending.isEmpty }
    var queueCount: Int { pending.count + (active == nil ? 0 : 1) }

    // MARK: Trigger（主线程）

    /// automatic = true 表示定时触发：忙碌时静默跳过，可按设置跳过无变化画面，不弹状态提示。
    func trigger(automatic: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))
        let now = Date()
        if !automatic {
            guard now.timeIntervalSince(lastTrigger) * 1000 >= Double(settings.debounceMs) else { return }
        }
        lastTrigger = now

        guard settings.captureEnabled else {
            if !automatic { emit(.status(message: "捕获已停止，请在菜单栏点击「启动捕获」", level: "warning")) }
            return
        }
        guard ScreenCapturer.effectivePermission() else {
            if !automatic { emit(.failed(id: UUID().uuidString, message: CaptureError.permissionDenied.localizedDescription, source: nil)) }
            return
        }
        if automatic {
            guard queueCount == 0 else { return }   // 上一次还没结束，等下一个周期
        } else {
            guard queueCount < AnalysisPipeline.maxQueue else {
                emit(.status(message: "分析队列已满（\(AnalysisPipeline.maxQueue) 个），本次触发已忽略", level: "warning"))
                return
            }
        }
        guard let target = resolveTarget() else { return }
        let config = snapshotConfig()
        let id = UUID().uuidString
        let skipUnchanged = automatic && settings.autoCaptureSkipUnchanged
        let previousSignature = lastSignature

        captureQueue.async { [weak self] in
            do {
                let result = try ScreenCapturer.capture(target)
                let signature = ChangeDetector.signature(result.image)
                if skipUnchanged && ChangeDetector.isUnchanged(previousSignature, signature) {
                    Log.capture.info("定时捕获：画面无变化，跳过")
                    DispatchQueue.main.async { self?.skippedUnchanged += 1 }
                    return
                }
                guard let encoded = ImageEncoder.encode(result.image, maxLongEdge: config.maxLongEdge, quality: config.jpegQuality) else {
                    throw CaptureError.captureFailed
                }
                Log.capture.info("截图 \(result.image.width)x\(result.image.height) → \(encoded.width)x\(encoded.height), \(encoded.byteCount / 1024) KB")
                let source = automatic ? "定时 · " + result.sourceDescription : result.sourceDescription
                let job = AnalysisJob(id: id, createdAt: now, source: source, image: result.image, encoded: encoded, config: config)
                DispatchQueue.main.async {
                    self?.lastSignature = signature
                    self?.enqueue(job)
                }
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                DispatchQueue.main.async { self?.captureFailed(id: id, message: message, config: config) }
            }
        }
    }

    private func captureFailed(id: String, message: String, config: AnalysisConfig) {
        emit(.failed(id: id, message: message, source: nil))
        record(id: id, source: "", config: config, result: "", status: "error", error: message, latency: 0)
    }

    /// 根据设置解析捕获目标；目标丢失时按用户设置处理。
    private func resolveTarget() -> CaptureTarget? {
        switch settings.captureScope {
        case .fullScreen:
            return .fullScreen
        case .display:
            if ScreenCapturer.displayExists(settings.selectedDisplayID) { return .display(settings.selectedDisplayID) }
            return handleLoss(settings.displayLossBehavior, what: "目标显示器已断开")
        case .window:
            guard let ref = settings.selectedWindow else {
                return handleLoss(settings.windowLossBehavior, what: "尚未选择目标窗口")
            }
            if WindowEnumerator.resolve(ref) != nil { return .window(ref) }
            return handleLoss(settings.windowLossBehavior, what: "目标窗口已关闭（\(ref.displayName.truncated(40))）")
        case .region:
            guard let region = settings.selectedRegion else {
                return handleLoss(settings.regionLossBehavior, what: "尚未选择捕获区域")
            }
            if ScreenCapturer.displayExists(region.displayID) { return .region(region) }
            return handleLoss(settings.regionLossBehavior, what: "区域所在显示器已断开")
        }
    }

    private func handleLoss(_ behavior: TargetLossBehavior, what: String) -> CaptureTarget? {
        switch behavior {
        case .stop:
            settings.captureEnabled = false
            emit(.status(message: "\(what)，已停止捕获", level: "warning"))
            onCaptureDisabled?()
            return nil
        case .fallbackFullScreen:
            settings.captureScope = .fullScreen
            emit(.status(message: "\(what)，已自动回退为全屏捕获", level: "warning"))
            return .fullScreen
        }
    }

    private func snapshotConfig() -> AnalysisConfig {
        AnalysisConfig(
            providerKind: settings.apiProvider,
            apiKey: settings.apiKey(for: settings.apiProvider),
            endpoint: settings.currentEndpoint,
            model: settings.currentModel,
            prompt: settings.promptTemplate,
            timeout: settings.apiTimeout,
            stream: settings.streamingEnabled,
            maxLongEdge: settings.maxImageLongEdge,
            jpegQuality: settings.jpegQuality,
            params: settings.currentParams
        )
    }

    // MARK: Queue（主线程）

    private func enqueue(_ job: AnalysisJob) {
        pending.append(job)
        emit(.started(id: job.id, source: job.source))
        pump()
    }

    private func pump() {
        guard active == nil, !pending.isEmpty else { return }
        let job = pending.removeFirst()
        active = job
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            await self.run(job)
            await MainActor.run {
                self.active = nil
                self.pump()
            }
        }
    }

    // MARK: Run（后台；通过 emitAsync 回主线程）

    private func run(_ job: AnalysisJob) async {
        let start = Date()
        var encoded = job.encoded
        var quality = job.config.jpegQuality
        var rateRetries = 0
        var timeoutRetried = false
        var attempt = 0
        _ = history.registerPrompt(job.config.prompt)

        while true {
            attempt += 1
            if attempt > 1 { await emitAsync(.started(id: job.id, source: job.source)) }
            var accumulated = ""
            var reasoningChars = 0
            var finishReason: String?
            var lastThinkingEmit = Date.distantPast
            do {
                let provider = AIProviderFactory.make(job.config.providerConfig)
                let request = AIRequest(imageBase64: encoded.base64, prompt: job.config.prompt, model: job.config.model,
                                        timeout: job.config.timeout, stream: job.config.stream, params: job.config.params)
                for try await event in provider.analyze(request) {
                    switch event {
                    case .text(let delta):
                        accumulated += delta
                        await emitAsync(.partial(id: job.id, delta: delta))
                    case .reasoning(let delta):
                        reasoningChars += delta.count
                        if Date().timeIntervalSince(lastThinkingEmit) > 0.4 {
                            lastThinkingEmit = Date()
                            await emitAsync(.thinking(id: job.id, chars: reasoningChars))
                        }
                    case .finished(let reason):
                        finishReason = reason
                    }
                }
                let text = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
                let latency = Int(Date().timeIntervalSince(start) * 1000)
                if text.isEmpty {
                    let hint = "请在 API 设置中增大「最大输出 tokens」（当前 \(job.config.params.maxTokens)），或关闭/降低思考"
                    if finishReason == "length" {
                        throw AIError.emptyResponse("输出被截断：达到最大输出 tokens，思考内容也计入其中。\(hint)")
                    } else if reasoningChars > 0 {
                        throw AIError.emptyResponse("模型只返回了 \(reasoningChars) 字的思考内容，没有给出答案。\(hint)")
                    } else {
                        throw AIError.emptyResponse("模型未返回内容（结束原因：\(finishReason ?? "未知")）")
                    }
                }
                await emitAsync(.completed(id: job.id, text: text, source: job.source, model: job.config.model, latencyMs: latency))
                if finishReason == "length" {
                    await emitAsync(.status(message: "答案可能被截断（达到最大输出 tokens），可在 API 设置中增大上限", level: "warning"))
                }
                record(id: job.id, source: job.source, config: job.config, result: text, status: "success", error: "", latency: latency)
                return
            } catch let e as AIError {
                if e.isRateLimited && rateRetries < 3 {
                    rateRetries += 1
                    let delay = pow(2.0, Double(rateRetries))
                    await emitAsync(.status(message: "请求被限流，\(Int(delay)) 秒后第 \(rateRetries) 次重试", level: "info"))
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    continue
                }
                if e.isTimeout && !timeoutRetried {
                    timeoutRetried = true
                    await emitAsync(.status(message: "请求超时，正在重试", level: "info"))
                    continue
                }
                if e.isImageTooLarge && quality > 0.4 {
                    quality = quality > 0.6 ? 0.6 : 0.4
                    if let re = ImageEncoder.encode(job.image, maxLongEdge: min(job.config.maxLongEdge, 1200), quality: quality) {
                        encoded = re
                        await emitAsync(.status(message: "图片过大，已降低质量（\(quality)）重试", level: "info"))
                        continue
                    }
                }
                let message = e.localizedDescription
                let latency = Int(Date().timeIntervalSince(start) * 1000)
                await emitAsync(.failed(id: job.id, message: message, source: job.source))
                record(id: job.id, source: job.source, config: job.config, result: accumulated, status: "error", error: message, latency: latency)
                return
            } catch {
                let message = error.localizedDescription
                let latency = Int(Date().timeIntervalSince(start) * 1000)
                await emitAsync(.failed(id: job.id, message: message, source: job.source))
                record(id: job.id, source: job.source, config: job.config, result: accumulated, status: "error", error: message, latency: latency)
                return
            }
        }
    }

    private func record(id: String, source: String, config: AnalysisConfig, result: String, status: String, error: String, latency: Int) {
        let rec = HistoryRecord(id: id, timestamp: Date(), captureSource: source, promptHash: HistoryStore.hash(of: config.prompt),
                                provider: config.providerKind.rawValue, model: config.model, result: result, status: status,
                                errorMessage: error, latencyMs: latency)
        history.append(rec)
    }

    private func emit(_ event: PipelineEvent) {
        onEvent?(event)
    }

    private func emitAsync(_ event: PipelineEvent) async {
        await MainActor.run { self.emit(event) }
    }
}

extension PipelineEvent {
    /// 转换为推送给手机端的消息
    var serverMessage: ServerMessage? {
        switch self {
        case let .started(id, source): return .analysisStarted(id: id, timestamp: Date(), source: source)
        case let .thinking(id, chars): return .analysisThinking(id: id, chars: chars)
        case let .partial(id, delta): return .analysisPartial(id: id, delta: delta)
        case let .completed(id, text, source, model, latency): return .analysisResult(id: id, timestamp: Date(), result: text, source: source, model: model, latencyMs: latency)
        case let .failed(id, message, source): return .error(id: id, timestamp: Date(), message: message, source: source)
        case let .status(message, level): return .statusChange(id: UUID().uuidString, timestamp: Date(), message: message, level: level)
        }
    }
}
