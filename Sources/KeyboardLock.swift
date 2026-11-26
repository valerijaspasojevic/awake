// Locks the keyboard so you can wipe it clean. The mouse and trackpad keep working, so you can always click Unlock;
// ⌃⌥⌘U also unlocks, and it unlocks by itself after 2 minutes.
// Uses a CGEvent tap that swallows key presses, modifier keys and media keys (needs Accessibility permission).
import Cocoa

final class KeyboardLock {
    static let maxDuration: TimeInterval = 120

    var onChange: (() -> Void)?
    var isLocked: Bool { tap != nil }
    var remaining: TimeInterval { max(0, (until ?? Date()).timeIntervalSinceNow) }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var until: Date?
    private var timer: Timer?
    private var panel: NSPanel?
    private var countdown: NSTextField?
    fileprivate var modifiers: CGEventFlags = []

    /// Starts the lock for up to `maxDuration`. Returns false if macOS refused the event tap (no Accessibility permission).
    func lock() -> Bool {
        if isLocked { return true }
        let keys: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mask = keys.reduce(CGEventMask(1) << 14) { $0 | (CGEventMask(1) << $1.rawValue) }   // 14 = NX_SYSDEFINED (media keys)
        guard let tap = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: keyboardLockCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return false }
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        until = Date().addingTimeInterval(Self.maxDuration)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer!, forMode: .common)
        showPanel()
        tick()
        onChange?()
        return true
    }

    func unlock() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil; source = nil; until = nil; modifiers = []
        timer?.invalidate(); timer = nil
        panel?.orderOut(nil); panel = nil; countdown = nil
        onChange?()
    }

    fileprivate func reenable() { if let tap { CGEvent.tapEnable(tap: tap, enable: true) } }

    private func tick() {
        if remaining <= 0 { unlock(); return }
        countdown?.stringValue = "Unlocks automatically in \(Self.format(remaining))"
    }

    static func format(_ t: TimeInterval) -> String {
        let s = Int(t.rounded(.up)); return String(format: "%d:%02d", s / 60, s % 60)
    }

    // A small floating window with the countdown and an Unlock button, clickable with the mouse.
    private func showPanel() {
        let title = NSTextField(labelWithString: "Keyboard locked for cleaning")
        let hint = NSTextField(labelWithString: "Click Unlock, or press ⌃⌥⌘U")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .tertiaryLabelColor
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let count = NSTextField(labelWithString: "")
        count.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        count.textColor = .secondaryLabelColor
        let button = NSButton(title: "Unlock Keyboard", target: self, action: #selector(unlockClicked))
        button.bezelColor = .controlAccentColor
        button.keyEquivalent = ""

        let icon = NSImageView(image: NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 28, weight: .regular)
        let text = NSStackView(views: [title, count, hint]); text.orientation = .vertical; text.alignment = .leading; text.spacing = 2
        let row = NSStackView(views: [icon, text, button]); row.spacing = 14; row.alignment = .centerY
        row.edgeInsets = NSEdgeInsets(top: 16, left: 18, bottom: 16, right: 18)

        let p = NSPanel(contentRect: .zero, styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView, .utilityWindow, .hudWindow],
                        backing: .buffered, defer: false)
        p.titleVisibility = .hidden; p.titlebarAppearsTransparent = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.contentView = row
        p.setContentSize(row.fittingSize)
        if let screen = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: screen.midX - p.frame.width / 2, y: screen.maxY - p.frame.height - 40))
        }
        p.orderFrontRegardless()
        panel = p; countdown = count
    }

    @objc private func unlockClicked() { unlock() }
}

private func keyboardLockCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, ref: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let ref { Unmanaged<KeyboardLock>.fromOpaque(ref).takeUnretainedValue().reenable() }
        return Unmanaged.passUnretained(event)
    case .flagsChanged:
        ref.map { Unmanaged<KeyboardLock>.fromOpaque($0).takeUnretainedValue().modifiers = event.flags }
        return nil
    case .keyDown:
        // Escape hatch from the keyboard: Control + Option + Command + U.
        if let ref, event.getIntegerValueField(.keyboardEventKeycode) == 32 {
            let me = Unmanaged<KeyboardLock>.fromOpaque(ref).takeUnretainedValue()
            if me.modifiers.isSuperset(of: [.maskControl, .maskAlternate, .maskCommand]) { DispatchQueue.main.async { me.unlock() } }
        }
        return nil
    case .keyUp:
        return nil
    default:
        // NX_SYSDEFINED also carries some mouse-button events; only swallow the media/brightness/volume keys (subtype 8).
        return NSEvent(cgEvent: event)?.subtype.rawValue == 8 ? nil : Unmanaged.passUnretained(event)
    }
}
