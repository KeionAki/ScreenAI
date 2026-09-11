import SwiftUI

/// 按厂商切换的请求参数面板：只展示该厂商真正支持的字段，其余不发送。
struct VendorParamsView: View {
    @ObservedObject var settings: SettingsStore
    let kind: AIProviderKind
    let model: String

    private var params: Binding<ProviderParams> {
        Binding(get: { settings.params(for: kind) }, set: { settings.setParams($0, for: kind) })
    }

    var body: some View {
        let p = params
        Group {
            switch kind {
            case .openai: openAI(p)
            case .deepseek: deepSeek(p)
            case .kimi: kimi(p)
            case .anthropic: anthropic(p)
            case .gemini: gemini(p)
            case .custom: custom(p)
            }
            HStack {
                Spacer()
                Button("恢复此厂商默认参数") { settings.setParams(ProviderParams.defaults(for: kind), for: kind) }.controlSize(.small)
            }
        }
    }

    // MARK: - 厂商面板

    @ViewBuilder
    private func openAI(_ p: Binding<ProviderParams>) -> some View {
        maxTokensRow(p, label: "最大输出 tokens（max_completion_tokens）")
        effortPicker(p, label: "推理强度（reasoning_effort）", options: [("default", "跟随模型默认"), ("minimal", "minimal"), ("low", "low"), ("medium", "medium"), ("high", "high")])
        optionalDouble(p.temperature, label: "temperature", range: 0...2, defaultValue: 1.0)
        note("推理模型（gpt-5 / o 系列）不接受 temperature，请保持不发送；gpt-4.1 等非推理模型可开启。")
        detailPicker(p, options: [("auto", "不发送（模型默认）"), ("low", "low（省 token）"), ("high", "high（高分辨率）")])
    }

    @ViewBuilder
    private func deepSeek(_ p: Binding<ProviderParams>) -> some View {
        maxTokensRow(p, label: "最大输出 tokens（max_tokens，≤ 384000）")
        note("思考内容计入此上限，思考开启时建议 ≥ 8192。")
        Picker("思考模式（thinking.type）", selection: p.thinking) {
            Text("跟随默认（开启）").tag("default")
            Text("开启").tag("enabled")
            Text("关闭").tag("disabled")
        }
        effortPicker(p, label: "推理强度（reasoning_effort）", options: [("default", "跟随默认（high）"), ("none", "none（不思考）"), ("low", "low"), ("high", "high"), ("max", "max")])
        optionalDouble(p.temperature, label: "temperature", range: 0...2, defaultValue: 1.0)
        optionalDouble(p.topP, label: "top_p", range: 0...1, defaultValue: 1.0)
        note("思考模式下 temperature 无效，top_p 低于 0.95 会被抬到 0.95；presence/frequency_penalty 已废弃，不会发送。")
        detailPicker(p, options: [("auto", "不发送（等同 original）"), ("low", "low（缩到 512×512）"), ("high", "high（等同 original）"), ("original", "original（保留原图）")])
        note("图片会缩放到约 1300×1300 像素当量，每张最多 1024 tokens。deepseek-flash 支持图片，deepseek-v4-pro 不支持。")
    }

    @ViewBuilder
    private func kimi(_ p: Binding<ProviderParams>) -> some View {
        let m = model.lowercased()
        maxTokensRow(p, label: "最大输出 tokens（max_completion_tokens）")
        note("思考模式下官方建议 ≥ 16000，以保证推理和正文都能输出完整。")
        if m.hasPrefix("kimi-k3") {
            effortPicker(p, label: "推理强度（reasoning_effort）", options: [("default", "跟随默认（max）"), ("low", "low"), ("high", "high"), ("max", "max")])
            note("kimi-k3 始终进行推理，不接受 thinking 参数。")
        } else if m.contains("k2.7") {
            Toggle("保留历史推理（thinking.keep = all）", isOn: p.thinkingKeep)
            note("kimi-k2.7-code 思考固定开启，只接受 {\"type\":\"enabled\",\"keep\":\"all\"}。")
        } else {
            Picker("思考模式（thinking.type）", selection: p.thinking) {
                Text("跟随默认（开启）").tag("default")
                Text("开启").tag("enabled")
                Text("关闭").tag("disabled")
            }
            Toggle("保留历史推理（thinking.keep = all）", isOn: p.thinkingKeep)
            note("kimi-k2.6 可关闭思考；关闭后 temperature 由模型固定为 0.6。")
        }
        note("Kimi 的 temperature、top_p、n、presence/frequency_penalty 为固定值，传入会报错，因此一律不发送；图片不支持 detail 参数，分辨率建议不超过 4K。")
    }

    @ViewBuilder
    private func anthropic(_ p: Binding<ProviderParams>) -> some View {
        maxTokensRow(p, label: "最大输出 tokens（max_tokens）")
        Picker("思考（thinking.type）", selection: p.thinking) {
            Text("跟随模型默认").tag("default")
            Text("自适应（adaptive）").tag("adaptive")
            Text("关闭").tag("disabled")
        }
        effortPicker(p, label: "推理强度（output_config.effort）", options: [("default", "跟随默认"), ("low", "low"), ("medium", "medium"), ("high", "high"), ("max", "max")])
        optionalDouble(p.temperature, label: "temperature", range: 0...1, defaultValue: 1.0)
        note("Claude 5 系列已移除 temperature / top_p，开启会返回 400；仅旧模型可用。")
    }

    @ViewBuilder
    private func gemini(_ p: Binding<ProviderParams>) -> some View {
        maxTokensRow(p, label: "最大输出 tokens（maxOutputTokens）")
        effortPicker(p, label: "思考（thinkingConfig）", options: [("default", "跟随模型默认"), ("none", "关闭（thinkingBudget 0）"), ("low", "low"), ("medium", "medium"), ("high", "high")])
        note("gemini-3 系列发送 thinkingLevel；gemini-2.5 系列换算为 thinkingBudget。2.5 Pro 无法关闭思考。")
        optionalDouble(p.temperature, label: "temperature", range: 0...2, defaultValue: 1.0)
        optionalDouble(p.topP, label: "topP", range: 0...1, defaultValue: 0.95)
    }

    @ViewBuilder
    private func custom(_ p: Binding<ProviderParams>) -> some View {
        Picker("输出上限字段名", selection: p.maxTokensField) {
            Text("max_tokens（多数兼容端点）").tag("auto")
            Text("max_tokens").tag("max_tokens")
            Text("max_completion_tokens").tag("max_completion_tokens")
        }
        maxTokensRow(p, label: "最大输出 tokens")
        Picker("思考模式（thinking.type）", selection: p.thinking) {
            Text("不发送").tag("default")
            Text("开启").tag("enabled")
            Text("关闭").tag("disabled")
        }
        effortPicker(p, label: "推理强度（reasoning_effort）", options: [("default", "不发送"), ("none", "none"), ("minimal", "minimal"), ("low", "low"), ("medium", "medium"), ("high", "high"), ("max", "max")])
        optionalDouble(p.temperature, label: "temperature", range: 0...2, defaultValue: 1.0)
        optionalDouble(p.topP, label: "top_p", range: 0...1, defaultValue: 1.0)
        detailPicker(p, options: [("auto", "不发送"), ("low", "low"), ("high", "high"), ("original", "original")])
        VStack(alignment: .leading, spacing: 4) {
            Text("额外请求体字段（JSON 对象，会合并进请求）")
            TextEditor(text: p.extraJSON).font(.system(.body, design: .monospaced)).frame(minHeight: 60)
            if !p.wrappedValue.extraJSONIsValid {
                Text("不是合法的 JSON 对象，发送时会报错").font(.caption).foregroundColor(.red)
            } else {
                Text("示例：{\"stop\": [\"###\"], \"response_format\": {\"type\": \"text\"}}").font(.caption).foregroundColor(.secondary)
            }
        }
    }

    // MARK: - 通用控件

    private func maxTokensRow(_ p: Binding<ProviderParams>, label: String) -> some View {
        LabeledContent(label) {
            TextField("", value: p.maxTokens, format: .number.grouping(.never)).frame(width: 90)
        }
    }

    private func effortPicker(_ p: Binding<ProviderParams>, label: String, options: [(String, String)]) -> some View {
        Picker(label, selection: p.reasoningEffort) {
            ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
        }
    }

    private func detailPicker(_ p: Binding<ProviderParams>, options: [(String, String)]) -> some View {
        Picker("图片细节（image_url.detail）", selection: p.imageDetail) {
            ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
        }
    }

    /// 可选数值：开关决定是否发送，滑块调整值
    private func optionalDouble(_ value: Binding<Double?>, label: String, range: ClosedRange<Double>, defaultValue: Double) -> some View {
        HStack {
            Toggle("发送 \(label)", isOn: Binding(get: { value.wrappedValue != nil }, set: { value.wrappedValue = $0 ? defaultValue : nil }))
            if let v = value.wrappedValue {
                Slider(value: Binding(get: { v }, set: { value.wrappedValue = $0 }), in: range, step: 0.05).frame(width: 160)
                Text(String(format: "%.2f", v)).font(.system(.body, design: .monospaced)).frame(width: 44, alignment: .trailing)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.caption).foregroundColor(.secondary)
    }
}
