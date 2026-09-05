import AppKit

let BORDER_WIDTH: CGFloat = 3
let CORNER_RADIUS: CGFloat = 11     // macOS の窓の角丸 (Big Sur 以降おおむね 10〜12pt)
let TINT_HEIGHT: CGFloat = 28       // 標準タイトルバーの高さ
let TINT_ALPHA: CGFloat = 0.35

/// 枠 + タイトルバー相当の色帯を描く。frame は対象窓を BORDER_WIDTH だけ外に広げたもの
final class BorderView: NSView {
    var color: NSColor = .systemRed { didSet { needsDisplay = true } }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let outer = bounds
        let inner = outer.insetBy(dx: BORDER_WIDTH, dy: BORDER_WIDTH)   // = 対象窓の矩形

        // 枠: 外周の角丸 (半径 = 窓の角丸 + 枠幅) と内周の角丸 (窓の角丸) の差分を塗る
        let path = NSBezierPath(roundedRect: outer, xRadius: CORNER_RADIUS + BORDER_WIDTH, yRadius: CORNER_RADIUS + BORDER_WIDTH)
        path.append(NSBezierPath(roundedRect: inner, xRadius: CORNER_RADIUS, yRadius: CORNER_RADIUS).reversed)
        color.setFill()
        path.fill()

        // タイトル帯: 窓の上端 TINT_HEIGHT を半透明で覆う (上の角だけ丸める)
        let tintRect = NSRect(x: inner.minX, y: inner.maxY - min(TINT_HEIGHT, inner.height),
                              width: inner.width, height: min(TINT_HEIGHT, inner.height))
        let tint = NSBezierPath()
        let r = CORNER_RADIUS
        tint.move(to: NSPoint(x: tintRect.minX, y: tintRect.minY))
        tint.line(to: NSPoint(x: tintRect.maxX, y: tintRect.minY))
        tint.line(to: NSPoint(x: tintRect.maxX, y: tintRect.maxY - r))
        tint.appendArc(withCenter: NSPoint(x: tintRect.maxX - r, y: tintRect.maxY - r), radius: r, startAngle: 0, endAngle: 90)
        tint.line(to: NSPoint(x: tintRect.minX + r, y: tintRect.maxY))
        tint.appendArc(withCenter: NSPoint(x: tintRect.minX + r, y: tintRect.maxY - r), radius: r, startAngle: 90, endAngle: 180)
        tint.close()
        color.withAlphaComponent(TINT_ALPHA).setFill()
        tint.fill()
    }
}

/// クリック透過・影なしの透明ウィンドウ。対象窓の直上に order される
final class OverlayWindow: NSWindow {
    let borderView = BorderView()

    static func make() -> OverlayWindow {
        OverlayWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                      styleMask: .borderless, backing: .buffered, defer: false)
    }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .normal
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        contentView = borderView
    }

    var color: NSColor {
        get { borderView.color }
        set { borderView.color = newValue }
    }

    /// 対象窓の AppKit 座標 frame に合わせて配置し、対象の直上に順序付ける
    func track(targetFrame: NSRect, targetWindowID: CGWindowID) {
        let f = targetFrame.insetBy(dx: -BORDER_WIDTH, dy: -BORDER_WIDTH)
        if frame != f { setFrame(f, display: true) }
        order(.above, relativeTo: Int(targetWindowID))
    }
}
