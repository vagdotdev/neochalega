import AppKit
import QuartzCore
import SwiftUI

@main
enum AppMain {
    static let delegate = AppDelegate()

    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            exit(Int32(Engine.selfTest()))
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.delegate = delegate
        delegate.start()
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let engine = Engine()
    private var statusItem: NSStatusItem!
    private var panel: NSPanel!
    private var iconTimer: Timer?
    private var outsideMonitor: Any?
    private let panelSize = NSSize(width: 300, height: 430)

    func start() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = MenuGlyph.image(on: false, angle: 0)
            button.action = #selector(togglePanel)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        buildPanel()
        refreshIcon()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.openPanel(animated: true)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard engine.isActive else { return .terminateNow }
        engine.disarmAndWait()
        return .terminateNow
    }

    private func buildPanel() {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        let host = NSHostingView(rootView: Panel(engine: engine))
        host.frame = NSRect(origin: .zero, size: panelSize)
        host.wantsLayer = true
        host.layer?.cornerRadius = 18
        host.layer?.masksToBounds = true
        panel.contentView = host
        self.panel = panel
    }

    @objc private func togglePanel() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showMenu()
            return
        }
        if panel.isVisible {
            closePanel(animated: true)
        } else {
            openPanel(animated: true)
        }
    }

    private func showMenu() {
        let menu = NSMenu()
        let turn = NSMenuItem(
            title: engine.phase == .on ? "Turn off" : "Turn on",
            action: #selector(toggleThrottle),
            keyEquivalent: ""
        )
        turn.target = self
        menu.addItem(turn)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Neochalega", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
        if let button = statusItem.button {
            button.action = #selector(togglePanel)
            button.target = self
        }
    }

    @objc private func toggleThrottle() {
        engine.toggle()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func openPanel(animated: Bool) {
        guard let button = statusItem.button, let window = button.window else { return }
        let buttonFrame = window.convertToScreen(button.convert(button.bounds, to: nil))
        var frame = NSRect(origin: .zero, size: panelSize)
        frame.origin.x = buttonFrame.midX - panelSize.width / 2
        frame.origin.y = buttonFrame.minY - panelSize.height - 6
        let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? frame
        if frame.maxX > screen.maxX { frame.origin.x = screen.maxX - frame.width - 8 }
        if frame.minX < screen.minX { frame.origin.x = screen.minX + 8 }
        let start = frame.offsetBy(dx: 0, dy: 10)
        panel.setFrame(animated ? start : frame, display: false)
        panel.alphaValue = animated ? 0 : 1
        panel.orderFrontRegardless()
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(frame, display: true)
                panel.animator().alphaValue = 1
            }
        }
        outsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePanel(animated: true)
        }
        iconTimer?.invalidate()
        iconTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            self?.refreshIcon()
        }
    }

    private func closePanel(animated: Bool) {
        if let outsideMonitor {
            NSEvent.removeMonitor(outsideMonitor)
            self.outsideMonitor = nil
        }
        guard panel.isVisible else { return }
        let end = panel.frame.offsetBy(dx: 0, dy: 8)
        if animated {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().setFrame(end, display: true)
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                self?.panel.orderOut(nil)
                self?.slowIcon()
            })
        } else {
            panel.orderOut(nil)
            slowIcon()
        }
    }

    private func slowIcon() {
        iconTimer?.invalidate()
        if engine.phase == .on {
            iconTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
                self?.refreshIcon()
            }
        } else {
            iconTimer = nil
            refreshIcon()
        }
    }

    private func refreshIcon() {
        let on = engine.phase == .on || engine.phase == .arming
        let angle = on ? CACurrentMediaTime().truncatingRemainder(dividingBy: 4) / 4 * .pi * 2 : 0
        statusItem.button?.image = MenuGlyph.image(on: on, angle: angle)
    }
}

enum MenuGlyph {
    static func image(on: Bool, angle: Double) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let color = on ? NSColor(srgbRed: 1, green: 0.42, blue: 0.16, alpha: 1) : NSColor.labelColor
            color.setStroke()
            let ring = NSBezierPath(ovalIn: NSRect(x: 1.5, y: 1.5, width: 15, height: 15))
            ring.lineWidth = 1.4
            ring.stroke()
            for i in 0..<4 {
                let a = angle + Double(i) * .pi / 2
                let path = NSBezierPath()
                path.move(to: NSPoint(x: center.x + CGFloat(cos(a)) * 3.2, y: center.y + CGFloat(sin(a)) * 3.2))
                path.line(to: NSPoint(x: center.x + CGFloat(cos(a)) * 5.6, y: center.y + CGFloat(sin(a)) * 5.6))
                path.lineWidth = 1.5
                path.lineCapStyle = .round
                path.stroke()
            }
            return true
        }
        image.isTemplate = !on
        return image
    }
}
