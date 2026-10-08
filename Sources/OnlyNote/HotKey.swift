import Carbon
import Foundation

/// A key, anywhere on the Mac (⌥⌘N), that shows or hides the note. Carbon's hot keys need no
/// permission from the user, unlike watching the keyboard.
final class HotKey {
    private var ref: EventHotKeyRef?
    private static var handler: EventHandlerRef?
    private static var action: (() -> Void)?

    /// ⌥⌘N.
    func register(_ action: @escaping () -> Void) {
        unregister()
        Self.action = action
        if Self.handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { HotKey.action?() }
                return noErr
            }, 1, &spec, nil, &Self.handler)
        }
        let id = EventHotKeyID(signature: OSType(0x4F4E_4F54), id: 1) // "ONOT"
        RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(cmdKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }
}
