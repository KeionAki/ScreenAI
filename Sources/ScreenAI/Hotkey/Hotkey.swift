import Foundation
import AppKit
import Carbon.HIToolbox

/// 全局快捷键定义（Carbon 修饰键位掩码 + 虚拟键码）。
struct Hotkey: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let `default` = Hotkey(keyCode: UInt32(kVK_ANSI_A), carbonModifiers: UInt32(cmdKey | shiftKey))
    /// 单键模式的默认值：F5
    static let defaultSingle = Hotkey(keyCode: UInt32(kVK_F5), carbonModifiers: 0)
    /// 「分析并键入」默认 ⌘⇧D；单键默认 F6
    static let defaultType = Hotkey(keyCode: UInt32(kVK_ANSI_D), carbonModifiers: UInt32(cmdKey | shiftKey))
    static let defaultTypeSingle = Hotkey(keyCode: UInt32(kVK_F6), carbonModifiers: 0)
    /// 「停止键入」默认 ⌘⇧.；单键默认 F8
    static let defaultStop = Hotkey(keyCode: UInt32(kVK_ANSI_Period), carbonModifiers: UInt32(cmdKey | shiftKey))
    static let defaultStopSingle = Hotkey(keyCode: UInt32(kVK_F8), carbonModifiers: 0)

    /// 单键模式下禁止使用的键（会让系统无法正常输入或操作）
    static let forbiddenSingleKeys: Set<Int> = [kVK_Space, kVK_Return, kVK_Tab, kVK_Delete, kVK_ForwardDelete, kVK_Escape, kVK_ANSI_KeypadEnter]

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// 从按键事件构造；allowSingleKey 为 true 时允许没有修饰键的单键。
    init?(event: NSEvent, allowSingleKey: Bool = false) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        let code = UInt32(event.keyCode)
        guard Hotkey.keyName(code) != nil else { return nil }
        let hasPrimaryModifier = mods & UInt32(cmdKey | optionKey | controlKey) != 0
        if allowSingleKey {
            // 单键模式：不带修饰键（Shift 也不带），且不能是功能性按键
            guard mods == 0, !Hotkey.forbiddenSingleKeys.contains(Int(code)) else { return nil }
        } else {
            // 组合键模式：至少需要 ⌘ / ⌃ / ⌥ 之一，避免劫持普通按键
            guard hasPrimaryModifier else { return nil }
        }
        self.init(keyCode: code, carbonModifiers: mods)
    }

    var isSingleKey: Bool { carbonModifiers == 0 }

    /// 单键会在所有应用中被占用时的提醒（字母、数字、标点等）
    var singleKeyWarning: String? {
        guard isSingleKey else { return nil }
        let code = Int(keyCode)
        if Hotkey.functionKeys.contains(code) || Hotkey.navigationKeys.contains(code) || Hotkey.keypadKeys.contains(code) { return nil }
        return "「\(displayString)」作为单键快捷键后，在所有应用中按下它都会触发截图而无法正常输入，建议改用 F 功能键。"
    }

    static let functionKeys: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19]
    static let navigationKeys: Set<Int> = [kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown, kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow]
    static let keypadKeys: Set<Int> = [kVK_ANSI_Keypad0, kVK_ANSI_Keypad1, kVK_ANSI_Keypad2, kVK_ANSI_Keypad3, kVK_ANSI_Keypad4, kVK_ANSI_Keypad5, kVK_ANSI_Keypad6, kVK_ANSI_Keypad7, kVK_ANSI_Keypad8, kVK_ANSI_Keypad9, kVK_ANSI_KeypadDecimal, kVK_ANSI_KeypadPlus, kVK_ANSI_KeypadMinus, kVK_ANSI_KeypadMultiply, kVK_ANSI_KeypadDivide, kVK_ANSI_KeypadEquals, kVK_ANSI_KeypadClear]

    var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + (Hotkey.keyName(keyCode) ?? "?")
    }

    static func keyName(_ code: UInt32) -> String? {
        let map: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
            kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
            kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
            kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
            kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "PgUp", kVK_PageDown: "PgDn",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
            kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
            kVK_ANSI_KeypadDecimal: "Num.", kVK_ANSI_KeypadPlus: "Num+", kVK_ANSI_KeypadMinus: "Num-", kVK_ANSI_KeypadMultiply: "Num*",
            kVK_ANSI_KeypadDivide: "Num/", kVK_ANSI_KeypadEquals: "Num=", kVK_ANSI_KeypadClear: "NumClear",
            kVK_ANSI_Keypad0: "Num0", kVK_ANSI_Keypad1: "Num1", kVK_ANSI_Keypad2: "Num2", kVK_ANSI_Keypad3: "Num3",
            kVK_ANSI_Keypad4: "Num4", kVK_ANSI_Keypad5: "Num5", kVK_ANSI_Keypad6: "Num6", kVK_ANSI_Keypad7: "Num7",
            kVK_ANSI_Keypad8: "Num8", kVK_ANSI_Keypad9: "Num9", kVK_ANSI_KeypadEnter: "NumEnter",
        ]
        return map[Int(code)]
    }
}

/// 快捷键动作
enum HotkeyAction: UInt32, CaseIterable {
    case capture = 1     // 分析并显示
    case typeCode = 2    // 分析并键入
    case stopTyping = 3  // 停止键入

    var displayName: String {
        switch self {
        case .capture: return "分析并显示"
        case .typeCode: return "分析并键入"
        case .stopTyping: return "停止键入"
        }
    }
}

/// 基于 Carbon RegisterEventHotKey 的全局快捷键，不需要辅助功能权限，不受焦点影响。
/// 支持同时注册多个动作。
final class HotkeyManager {
    static let shared = HotkeyManager()

    var onTrigger: ((HotkeyAction) -> Void)?
    private var refs: [HotkeyAction: EventHotKeyRef] = [:]
    private var current: [HotkeyAction: Hotkey] = [:]
    private var handlerRef: EventHandlerRef?
    private static let signature: OSType = 0x53414931 // "SAI1"

    private init() {}

    func registered(_ action: HotkeyAction) -> Hotkey? { current[action] }

    @discardableResult
    func register(_ hotkey: Hotkey, for action: HotkeyAction) -> Bool {
        unregister(action)
        installHandlerIfNeeded()
        let hkID = EventHotKeyID(signature: HotkeyManager.signature, id: action.rawValue)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(hotkey.keyCode, hotkey.carbonModifiers, hkID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let r = ref else {
            Log.app.error("注册快捷键失败（\(action.displayName, privacy: .public)）: \(status)")
            return false
        }
        refs[action] = r
        current[action] = hotkey
        Log.app.info("已注册快捷键 \(action.displayName, privacy: .public) = \(hotkey.displayString, privacy: .public)")
        return true
    }

    func unregister(_ action: HotkeyAction) {
        if let r = refs[action] {
            UnregisterEventHotKey(r)
            refs[action] = nil
        }
        current[action] = nil
    }

    func unregisterAll() {
        for action in HotkeyAction.allCases { unregister(action) }
    }

    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let callback: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let event = event, let userData = userData else { return OSStatus(eventNotHandledErr) }
            var hkID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard status == noErr, hkID.signature == HotkeyManager.signature,
                  let action = HotkeyAction(rawValue: hkID.id) else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { manager.onTrigger?(action) }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, selfPtr, &handlerRef)
    }
}
