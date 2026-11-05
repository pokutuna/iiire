import AppKit

/// メニューバーのアイコン。アプリのアイコン (Resources/AppIcon.svg) と同じく、波形の棒 2 本とテキストカーソル (I) を描く。
/// 状態は、薄くする部分で表す
enum MenuBarGlyph {
    enum State { case idle, recording, transcribing, unavailable }

    static func image(_ state: State) -> NSImage { images[state]! }

    private static let images: [State: NSImage] = [
        .idle: draw(bars: 1, cursor: 1),
        .recording: draw(bars: 1, cursor: 0.35),      // 聞いている
        .transcribing: draw(bars: 0.35, cursor: 1),   // 書いている
        .unavailable: draw(bars: 0.35, cursor: 0.35),
    ]

    /// 座標は AppIcon.svg の値から、図形を囲む枠の左上を原点にしたもの (幅 494、高さ 636)
    private static func draw(bars: CGFloat, cursor: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 18), flipped: true) { rect in
            let scale = 16 / 636.0
            let transform = NSAffineTransform()
            transform.translateX(by: (rect.width - 494 * scale) / 2, yBy: (rect.height - 636 * scale) / 2)
            transform.scale(by: scale)
            transform.concat()

            NSColor.black.withAlphaComponent(bars).setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 198, width: 104, height: 240), xRadius: 52, yRadius: 52).fill()
            NSBezierPath(roundedRect: NSRect(x: 160, y: 118, width: 104, height: 400), xRadius: 52, yRadius: 52).fill()

            let beam = NSBezierPath()
            beam.move(to: NSPoint(x: 372, y: 38)); beam.line(to: NSPoint(x: 372, y: 598))
            beam.move(to: NSPoint(x: 288, y: 38)); beam.line(to: NSPoint(x: 456, y: 38))
            beam.move(to: NSPoint(x: 288, y: 598)); beam.line(to: NSPoint(x: 456, y: 598))
            beam.lineWidth = 76
            beam.lineCapStyle = .round
            NSColor.black.withAlphaComponent(cursor).setStroke()
            beam.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}
