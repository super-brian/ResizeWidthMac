import AppKit
import Carbon

/// Global hotkeys via Carbon. Not MainActor-isolated so the C event handler can call into it safely.
final class HotkeyManager {
    var onAction: ((SnapAction) -> Void)?

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlerRef: EventHandlerRef?
    private var installed = false

    enum HotKeyID: UInt32 {
        case verticalUp = 1
        case verticalDown = 2
        case spanRight = 3
        case spanLeft = 4
        case moveDisplayRight = 5
        case moveDisplayLeft = 6
        case spanHalfUp = 7
        case spanHalfDown = 8
        case halfLeft = 9
        case halfRight = 10

        var action: SnapAction {
            switch self {
            case .verticalUp: return .verticalUp
            case .verticalDown: return .verticalDown
            case .spanRight: return .spanRight
            case .spanLeft: return .spanLeft
            case .moveDisplayRight: return .moveDisplayRight
            case .moveDisplayLeft: return .moveDisplayLeft
            case .spanHalfUp: return .spanHalfUp
            case .spanHalfDown: return .spanHalfDown
            case .halfLeft: return .halfLeft
            case .halfRight: return .halfRight
            }
        }

        static func action(for id: UInt32) -> SnapAction? {
            HotKeyID(rawValue: id)?.action
        }
    }

    func registerDefaults() {
        uninstallHandlerIfNeeded()
        unregisterAll()
        installHandler()

        // Shift+Control+Up / Down
        register(id: .verticalUp, keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(shiftKey | controlKey))
        register(id: .verticalDown, keyCode: UInt32(kVK_DownArrow), modifiers: UInt32(shiftKey | controlKey))
        // Option+Command+Left / Right — cycle left/right width 50% → 75% → 33%
        register(id: .halfLeft, keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(optionKey | cmdKey))
        register(id: .halfRight, keyCode: UInt32(kVK_RightArrow), modifiers: UInt32(optionKey | cmdKey))
        // Shift+Option+Command+Right / Left — span across displays
        register(id: .spanRight, keyCode: UInt32(kVK_RightArrow), modifiers: UInt32(shiftKey | optionKey | cmdKey))
        register(id: .spanLeft, keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(shiftKey | optionKey | cmdKey))
        // Shift+Option+Command+Up / Down — span twin display at top/bottom half
        register(id: .spanHalfUp, keyCode: UInt32(kVK_UpArrow), modifiers: UInt32(shiftKey | optionKey | cmdKey))
        register(id: .spanHalfDown, keyCode: UInt32(kVK_DownArrow), modifiers: UInt32(shiftKey | optionKey | cmdKey))
        // Shift+Control+Right / Left — move window to adjacent display (Windows Win+Shift+Arrow)
        register(id: .moveDisplayRight, keyCode: UInt32(kVK_RightArrow), modifiers: UInt32(shiftKey | controlKey))
        register(id: .moveDisplayLeft, keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(shiftKey | controlKey))
    }

    func unregisterAll() {
        for ref in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }

    private func register(id: HotKeyID, keyCode: UInt32, modifiers: UInt32) {
        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x52574D41), id: id.rawValue) // 'RWMA'
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status == noErr, let hotKeyRef {
            hotKeyRefs.append(hotKeyRef)
        } else {
            NSLog("ResizeWidthMac: failed to register hotkey id=%u status=%d", id.rawValue, status)
        }
    }

    private func installHandler() {
        guard !installed else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { (_, event, userData) -> OSStatus in
                guard let userData, let event else {
                    return OSStatus(eventNotHandledErr)
                }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                let err = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard err == noErr else { return err }

                if let action = HotkeyManager.HotKeyID.action(for: hotKeyID.id) {
                    DispatchQueue.main.async {
                        manager.onAction?(action)
                    }
                }
                return noErr
            },
            1,
            &eventType,
            userData,
            &handlerRef
        )
        installed = status == noErr
        if !installed {
            NSLog("ResizeWidthMac: failed to install hotkey handler status=%d", status)
        }
    }

    private func uninstallHandlerIfNeeded() {
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        installed = false
    }
}
