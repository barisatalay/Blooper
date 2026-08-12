// GitHub Social Preview banner'ı üretir (1280x640 oran, 2x piksel).
// Kullanım: swift scripts/make-social-preview.swift docs/assets/social-preview.png
import AppKit

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "docs/assets/social-preview.png"
let W: CGFloat = 1280, H: CGFloat = 640

let img = NSImage(size: NSSize(width: W, height: H))
img.lockFocus()

// Zemin: koyu, hafif eğik gradyan + sağ üstte marka renklerinden yumuşak bir ışıma
NSGradient(starting: NSColor(calibratedRed: 0.09, green: 0.09, blue: 0.11, alpha: 1),
           ending: NSColor(calibratedRed: 0.13, green: 0.10, blue: 0.14, alpha: 1))!
    .draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -30)
let glow = NSGradient(colorsAndLocations:
    (NSColor(calibratedRed: 0.85, green: 0.30, blue: 0.45, alpha: 0.22), 0.0),
    (NSColor.clear, 1.0))!
glow.draw(in: NSBezierPath(ovalIn: NSRect(x: W - 560, y: H - 420, width: 760, height: 620)),
          relativeCenterPosition: .zero)

// Sol: app ikonu
if let icon = NSImage(contentsOfFile: "docs/assets/icon.png") {
    icon.draw(in: NSRect(x: 96, y: (H - 232) / 2, width: 232, height: 232))
}

func draw(_ text: String, x: CGFloat, y: CGFloat, font: NSFont, color: NSColor) {
    NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        .draw(at: NSPoint(x: x, y: y))
}

let textX: CGFloat = 400

// Başlık + tagline
draw("Blooper", x: textX, y: 370, font: .systemFont(ofSize: 96, weight: .bold), color: .white)
let tagline = NSAttributedString(
    string: "Catch your English mistakes while chatting\nwith Claude Code — right in your menu bar.",
    attributes: [.font: NSFont.systemFont(ofSize: 31, weight: .regular),
                 .foregroundColor: NSColor(calibratedWhite: 0.78, alpha: 1)])
tagline.draw(in: NSRect(x: textX, y: 252, width: W - textX - 60, height: 110))

// Alt: örnek düzeltme satırı — ürünün imza görüntüsü
let mono = NSFont.monospacedSystemFont(ofSize: 30, weight: .semibold)
let chip = NSRect(x: textX - 24, y: 128, width: 640, height: 72)
NSColor(calibratedWhite: 1, alpha: 0.06).setFill()
NSBezierPath(roundedRect: chip, xRadius: 14, yRadius: 14).fill()
var cx = textX
let parts: [(String, NSColor)] = [
    ("I am agree", NSColor(calibratedRed: 0.95, green: 0.35, blue: 0.32, alpha: 1)),
    ("  →  ", NSColor(calibratedWhite: 0.6, alpha: 1)),
    ("I agree", NSColor(calibratedRed: 0.35, green: 0.85, blue: 0.45, alpha: 1)),
]
for (s, c) in parts {
    let a = NSAttributedString(string: s, attributes: [.font: mono, .foregroundColor: c])
    a.draw(at: NSPoint(x: cx, y: 146))
    cx += a.size().width
}

img.unlockFocus()

// 2x piksel yaz (GitHub kartı retina'da keskin kalsın)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * 2), pixelsHigh: Int(H * 2),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W * 2, height: H * 2)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
img.draw(in: NSRect(x: 0, y: 0, width: W * 2, height: H * 2))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
print("OK: \(outPath)")
