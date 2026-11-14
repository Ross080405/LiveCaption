import Carbon

/// 全局快捷键（不需要「辅助功能」权限）。可以同时注册多个，各自只响应自己的按键。
final class HotKey {
    private static var nextID: UInt32 = 1

    private let id: UInt32
    private let action: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.id = HotKey.nextID
        HotKey.nextID += 1
        self.action = action

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var pressed = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &pressed)
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            // 不是自己的按键就交给下一个处理器
            guard status == OSStatus(0), pressed.id == hotKey.id else { return OSStatus(eventNotHandledErr) }
            hotKey.action()
            return 0
        }, 1, &eventType, userData, &handlerRef)
        guard installed == OSStatus(0) else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4C43_4150), id: id)   // 'LCAP'
        let registered = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                             GetApplicationEventTarget(), 0, &hotKeyRef)
        guard registered == OSStatus(0) else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            handlerRef = nil
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
