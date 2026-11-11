// Draws the Awake app icon in a hand-drawn style: ink sketch of a coffee cup with
// a loose watercolor wash on paper. Writes a 1024×1024 PNG (path = first argument).
import AppKit

let S: CGFloat = 1024

// Deterministic randomness so the icon is the same on every build.
var seed: UInt64 = 42
func rnd() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
func rnd(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * rnd() }

// Turn a smooth path into evenly spaced points.
func points(_ p: NSBezierPath, step: CGFloat = 6) -> [[CGPoint]] {
    var subpaths: [[CGPoint]] = [], cur: [CGPoint] = []
    let flat = p.flattened
    var pts = [NSPoint](repeating: .zero, count: 3)
    for i in 0..<flat.elementCount {
        switch flat.element(at: i, associatedPoints: &pts) {
        case .moveTo: if cur.count > 1 { subpaths.append(cur) }; cur = [pts[0]]
        case .lineTo:
            let a = cur.last!, b = pts[0], d = hypot(b.x - a.x, b.y - a.y), n = max(1, Int(d / step))
            for k in 1...n { let t = CGFloat(k) / CGFloat(n); cur.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)) }
        case .closePath: if let f = cur.first { cur.append(f) }
        default: break
        }
    }
    if cur.count > 1 { subpaths.append(cur) }
    return subpaths
}

// Wobble points with smooth, low-frequency noise (a shaky hand, not jagged noise).
func wobble(_ pts: [CGPoint], amount: CGFloat) -> [CGPoint] {
    let f1 = rnd(0.02, 0.05), f2 = rnd(0.07, 0.12), p1 = rnd(0, 6.28), p2 = rnd(0, 6.28), p3 = rnd(0, 6.28)
    let dx = rnd(-amount, amount) * 0.6, dy = rnd(-amount, amount) * 0.6
    return pts.enumerated().map { i, p in
        let t = CGFloat(i)
        return CGPoint(x: p.x + dx + amount * (sin(t * f1 + p1) + 0.4 * sin(t * f2 + p2)),
                       y: p.y + dy + amount * (sin(t * f1 + p3) + 0.4 * cos(t * f2 + p1)))
    }
}

// Ink stroke: traced twice like a quick sketch; the second pass drifts a little.
func ink(_ path: NSBezierPath, width: CGFloat = 13, passes: Int = 2, color: NSColor) {
    for sub in points(path) {
        for pass in 0..<passes {
            var pts = wobble(sub, amount: pass == 0 ? 5 : 8)
            if sub.first != sub.last, pts.count > 2 {   // open line: overshoot the ends a bit
                let a = pts[0], b = pts[1], y = pts[pts.count - 1], z = pts[pts.count - 2]
                let o = rnd(2, 5)
                pts.insert(CGPoint(x: a.x + (a.x - b.x) * o, y: a.y + (a.y - b.y) * o), at: 0)
                pts.append(CGPoint(x: y.x + (y.x - z.x) * o, y: y.y + (y.y - z.y) * o))
            }
            let b = NSBezierPath(); b.lineCapStyle = .round; b.lineJoinStyle = .round
            b.lineWidth = width * (pass == 0 ? 1 : 0.45)
            b.move(to: pts[0]); for q in pts.dropFirst() { b.line(to: q) }
            color.withAlphaComponent(pass == 0 ? 0.92 : 0.45).setStroke(); b.stroke()
        }
    }
}

// Watercolor wash: a few translucent, wobbly, slightly offset layers.
func wash(_ path: NSBezierPath, color: NSColor, offset: CGPoint = CGPoint(x: 14, y: -10)) {
    for _ in 0..<4 {
        for sub in points(path, step: 10) {
            let pts = wobble(sub, amount: 9)
            let b = NSBezierPath(); b.move(to: CGPoint(x: pts[0].x + offset.x, y: pts[0].y + offset.y))
            for p in pts.dropFirst() { b.line(to: CGPoint(x: p.x + offset.x, y: p.y + offset.y)) }
            b.close(); color.withAlphaComponent(0.22).setFill(); b.fill()
        }
    }
}

let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// Paper card with soft shadow and a little grain.
let card = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.28).cgColor)
NSColor(red: 0.985, green: 0.955, blue: 0.90, alpha: 1).setFill(); card.fill()
ctx.restoreGState()
ctx.saveGState(); card.addClip()
for _ in 0..<2600 {
    NSColor(red: 0.55, green: 0.42, blue: 0.3, alpha: rnd(0.02, 0.07)).setFill()
    let s = rnd(1.5, 4); NSBezierPath(ovalIn: NSRect(x: rnd(100, 924), y: rnd(100, 924), width: s, height: s)).fill()
}

let inkColor = NSColor(red: 0.20, green: 0.14, blue: 0.12, alpha: 1)
let orange = NSColor(red: 0.96, green: 0.50, blue: 0.22, alpha: 1)
let coffee = NSColor(red: 0.50, green: 0.28, blue: 0.16, alpha: 1)

// Shapes
let rimRect = NSRect(x: 300, y: 560, width: 350, height: 60)
let cupBody = NSBezierPath()            // body outline, open at the top (rim ellipse closes it)
cupBody.move(to: NSPoint(x: 300, y: 590))
cupBody.line(to: NSPoint(x: 305, y: 450))
cupBody.curve(to: NSPoint(x: 405, y: 340), controlPoint1: NSPoint(x: 310, y: 380), controlPoint2: NSPoint(x: 345, y: 340))
cupBody.line(to: NSPoint(x: 545, y: 340))
cupBody.curve(to: NSPoint(x: 645, y: 450), controlPoint1: NSPoint(x: 605, y: 340), controlPoint2: NSPoint(x: 640, y: 380))
cupBody.line(to: NSPoint(x: 650, y: 590))
let cupFill = cupBody.copy() as! NSBezierPath
cupFill.close()
cupFill.append(NSBezierPath(ovalIn: rimRect))   // include the rim area
let rim = NSBezierPath(ovalIn: rimRect)
let coffeeTop = NSBezierPath(ovalIn: rimRect.insetBy(dx: 26, dy: 11).offsetBy(dx: 0, dy: -4))
let handle = NSBezierPath()             // only the part outside the cup
handle.appendArc(withCenter: NSPoint(x: 655, y: 490), radius: 72, startAngle: 105, endAngle: -100, clockwise: true)
let saucer = NSBezierPath(ovalIn: NSRect(x: 235, y: 285, width: 540, height: 80))

// Saucer first, then an opaque paper-colored cup on top so the back of the saucer is hidden.
wash(saucer, color: orange.blended(withFraction: 0.45, of: .white)!)
ink(saucer, width: 12, color: inkColor)
NSColor(red: 0.985, green: 0.955, blue: 0.90, alpha: 1).setFill(); cupFill.fill()
wash(cupFill, color: orange)
wash(coffeeTop, color: coffee, offset: CGPoint(x: 5, y: -3))
ink(handle, width: 14, color: inkColor)
ink(cupBody, width: 14, color: inkColor)
ink(rim, width: 12, color: inkColor)
ink(coffeeTop, width: 7, passes: 1, color: inkColor.withAlphaComponent(0.7))

// Steam squiggles, uneven like real ones
for (x, top) in [(400.0, 790.0), (478.0, 830.0), (556.0, 775.0)] as [(CGFloat, CGFloat)] {
    let s = NSBezierPath()
    s.move(to: NSPoint(x: x, y: 655))
    s.curve(to: NSPoint(x: x + 8, y: top), controlPoint1: NSPoint(x: x - 55, y: 705), controlPoint2: NSPoint(x: x + 55, y: top - 60))
    ink(s, width: 10, passes: 2, color: inkColor.withAlphaComponent(0.75))
}
// A few doodle sparkles: "wide awake"
for (cx, cy) in [(250.0, 720.0), (770.0, 760.0)] as [(CGFloat, CGFloat)] {
    for a in stride(from: 0.0, to: CGFloat.pi, by: CGFloat.pi / 2) {
        let l = NSBezierPath(); l.move(to: NSPoint(x: cx - 26 * cos(a), y: cy - 26 * sin(a))); l.line(to: NSPoint(x: cx + 26 * cos(a), y: cy + 26 * sin(a)))
        ink(l, width: 9, passes: 1, color: orange.blended(withFraction: 0.3, of: inkColor)!)
    }
}
ctx.restoreGState()
img.unlockFocus()

var rect = NSRect(x: 0, y: 0, width: S, height: S)
let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
let rep = NSBitmapImageRep(cgImage: cg); rep.size = NSSize(width: S, height: S)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
