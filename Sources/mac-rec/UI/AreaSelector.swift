import AppKit

/// ⌘⇧5-style free-form region picker: dims every display, lets the user drag
/// a rectangle, Esc (or a plain click) cancels. Returns the region in the
/// coordinates the capture engine wants: display points, top-left origin,
/// relative to the display the drag happened on.
@MainActor
final class AreaSelector {
    private static var active: AreaSelector?

    typealias Selection = (displayID: UInt32, rect: CGRect)

    private var windows: [SelectorWindow] = []
    private let completion: (Selection?) -> Void

    private init(completion: @escaping (Selection?) -> Void) {
        self.completion = completion
    }

    static func begin(completion: @escaping (Selection?) -> Void) {
        guard active == nil else { return }
        let selector = AreaSelector(completion: completion)
        active = selector
        selector.show()
    }

    private func show() {
        NSApp.activate(ignoringOtherApps: true)
        for screen in NSScreen.screens {
            let w = SelectorWindow(screen: screen) { [weak self] result in
                self?.finish(with: result, on: screen)
            }
            windows.append(w)
            w.makeKeyAndOrderFront(nil)
        }
    }

    private func finish(with rect: CGRect?, on screen: NSScreen) {
        for w in windows { w.orderOut(nil) }
        windows.removeAll()
        AreaSelector.active = nil

        guard let rect, rect.width >= 20, rect.height >= 20 else {
            completion(nil)
            return
        }
        guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            completion(nil)
            return
        }
        // Window-local coords are bottom-left; the engine wants top-left.
        let topLeft = CGRect(
            x: rect.minX,
            y: screen.frame.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
        completion((num.uint32Value, topLeft))
    }
}

@MainActor
private final class SelectorWindow: NSWindow {
    init(screen: NSScreen, onDone: @escaping (CGRect?) -> Void) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size), onDone: onDone)
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {  // Esc
            (contentView as? SelectionView)?.cancel()
        }
    }
}

@MainActor
private final class SelectionView: NSView {
    private let onDone: (CGRect?) -> Void
    private var startPoint: NSPoint?
    private var currentRect: NSRect = .zero
    private var finished = false

    init(frame: NSRect, onDone: @escaping (CGRect?) -> Void) {
        self.onDone = onDone
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) { fatalError() }

    func cancel() {
        guard !finished else { return }
        finished = true
        onDone(nil)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        let p = convert(event.locationInWindow, from: nil)
        currentRect = NSRect(
            x: min(start.x, p.x),
            y: min(start.y, p.y),
            width: abs(p.x - start.x),
            height: abs(p.y - start.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard !finished else { return }
        finished = true
        onDone(currentRect.width >= 20 && currentRect.height >= 20 ? currentRect : nil)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.25).setFill()
        bounds.fill()

        guard currentRect.width > 0 else {
            drawHint()
            return
        }
        // Punch the selection out of the dim layer.
        NSColor.clear.setFill()
        currentRect.fill(using: .copy)
        NSColor.white.setStroke()
        let border = NSBezierPath(rect: currentRect.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        border.stroke()

        let label = "\(Int(currentRect.width)) × \(Int(currentRect.height))"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.6),
        ]
        let size = label.size(withAttributes: attrs)
        label.draw(
            at: NSPoint(x: currentRect.minX, y: max(4, currentRect.minY - size.height - 4)),
            withAttributes: attrs
        )
    }

    private func drawHint() {
        let hint = "drag to select the recording area — Esc to cancel"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 15, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ]
        let size = hint.size(withAttributes: attrs)
        hint.draw(
            at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2),
            withAttributes: attrs
        )
    }
}
