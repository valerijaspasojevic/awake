// Awake — tiny menu bar app that keeps your Mac awake (and optionally jiggles the mouse).
import Cocoa
import IOKit.pwr_mgt
import ApplicationServices

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var assertionID: IOPMAssertionID = 0
    private var jiggleTimer: Timer?
    private var stopTimer: Timer?
    private let defaults = UserDefaults.standard

    private let awakeItem = NSMenuItem(title: "Keep Awake", action: #selector(toggleAwake), keyEquivalent: "a")
    private let jiggleItem = NSMenuItem(title: "Jiggle Mouse (stay \"Active\")", action: #selector(toggleJiggle), keyEquivalent: "j")
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    private var isAwake: Bool { assertionID != 0 }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(.separator())
        awakeItem.target = self
        menu.addItem(awakeItem)

        let forItem = NSMenuItem(title: "Keep Awake For", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (title, mins) in [("30 minutes", 30), ("1 hour", 60), ("2 hours", 120), ("4 hours", 240), ("8 hours", 480)] {
            let i = NSMenuItem(title: title, action: #selector(awakeFor(_:)), keyEquivalent: "")
            i.target = self; i.tag = mins
            sub.addItem(i)
        }
        forItem.submenu = sub
        menu.addItem(forItem)

        jiggleItem.target = self
        menu.addItem(jiggleItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Awake", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu

        // Restore last session's choices.
        if defaults.bool(forKey: "awake") { startAwake(minutes: nil) }
        if defaults.bool(forKey: "jiggle") { startJiggle(prompt: false) }
        refresh()
    }

    func applicationWillTerminate(_ notification: Notification) { stopAwake(persist: false) }

    // MARK: Keep awake (power assertion — same thing `caffeinate -d` does)

    @objc private func toggleAwake() {
        isAwake ? stopAwake() : startAwake(minutes: nil)
        refresh()
    }

    @objc private func awakeFor(_ sender: NSMenuItem) {
        startAwake(minutes: sender.tag)
        refresh()
    }

    private func startAwake(minutes: Int?) {
        stopTimer?.invalidate(); stopTimer = nil
        if !isAwake {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Awake menu bar app" as CFString, &assertionID)
        }
        if let minutes {
            let end = Date().addingTimeInterval(TimeInterval(minutes * 60))
            defaults.set(end, forKey: "until")
            stopTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(minutes * 60), repeats: false) { [weak self] _ in
                self?.stopAwake(); self?.refresh()
            }
            defaults.set(false, forKey: "awake")   // timed sessions don't survive a relaunch
        } else {
            defaults.removeObject(forKey: "until")
            defaults.set(true, forKey: "awake")
        }
    }

    private func stopAwake(persist: Bool = true) {
        stopTimer?.invalidate(); stopTimer = nil
        if isAwake { IOPMAssertionRelease(assertionID); assertionID = 0 }
        if persist { defaults.set(false, forKey: "awake"); defaults.removeObject(forKey: "until") }
    }

    // MARK: Mouse jiggle (keeps Slack/Teams "Active"; needs Accessibility permission)

    @objc private func toggleJiggle() {
        jiggleTimer == nil ? startJiggle(prompt: true) : stopJiggle()
        refresh()
    }

    private func startJiggle(prompt: Bool) {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: prompt] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) && prompt {
            let alert = NSAlert()
            alert.messageText = "Allow Accessibility"
            alert.informativeText = "To move the mouse, enable Awake in System Settings → Privacy & Security → Accessibility, then turn Jiggle on again."
            alert.runModal()
            return
        }
        defaults.set(true, forKey: "jiggle")
        jiggleTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            // Only nudge when you've actually been idle, so it never fights your real mouse.
            let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
            guard idle > 25, let pos = CGEvent(source: nil)?.location else { return }
            for p in [CGPoint(x: pos.x + 1, y: pos.y), pos] {
                CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)?
                    .post(tap: .cghidEventTap)
            }
        }
    }

    private func stopJiggle() {
        jiggleTimer?.invalidate(); jiggleTimer = nil
        defaults.set(false, forKey: "jiggle")
    }

    // MARK: UI

    private func refresh() {
        awakeItem.state = isAwake ? .on : .off
        jiggleItem.state = jiggleTimer != nil ? .on : .off
        let symbol = isAwake ? "cup.and.saucer.fill" : "cup.and.saucer"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Awake")
        if !isAwake {
            statusLine.title = "Mac can sleep normally"
        } else if let until = defaults.object(forKey: "until") as? Date {
            statusLine.title = "Awake until " + DateFormatter.localizedString(from: until, dateStyle: .none, timeStyle: .short)
        } else {
            statusLine.title = "Awake indefinitely"
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
