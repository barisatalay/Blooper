// App ikonu üretici: AppKit ile çizer, iconset PNG'lerini basar.
// Kullanım: swift scripts/make-icon.swift <çıktı-dizini>
import AppKit

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build/Blooper.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func draw(size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let s = size / 1024.0

    // Big Sur tarzı squircle: kenarlardan ~%10 boşluk
    let inset = 100 * s
    let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let squircle = NSBezierPath(roundedRect: rect, xRadius: 185 * s, yRadius: 185 * s)
    let gradient = NSGradient(starting: NSColor(calibratedRed: 1.00, green: 0.45, blue: 0.32, alpha: 1),
                              ending: NSColor(calibratedRed: 0.55, green: 0.13, blue: 0.38, alpha: 1))!
    gradient.draw(in: squircle, angle: -70)

    // Konuşma balonu (beyaz, kuyruğu sol-alt)
    let bubbleRect = NSRect(x: 235 * s, y: 340 * s, width: 554 * s, height: 380 * s)
    let bubble = NSBezierPath(roundedRect: bubbleRect, xRadius: 90 * s, yRadius: 90 * s)
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: 330 * s, y: 360 * s))
    tail.line(to: NSPoint(x: 290 * s, y: 245 * s))
    tail.line(to: NSPoint(x: 445 * s, y: 350 * s))
    tail.close()
    NSColor.white.setFill()
    bubble.fill()
    tail.fill()

    // Balon içi: iki "metin" çubuğu
    let barColor = NSColor(calibratedWhite: 0.72, alpha: 1)
    barColor.setFill()
    NSBezierPath(roundedRect: NSRect(x: 320 * s, y: 600 * s, width: 384 * s, height: 46 * s),
                 xRadius: 23 * s, yRadius: 23 * s).fill()
    NSColor(calibratedWhite: 0.35, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 320 * s, y: 500 * s, width: 280 * s, height: 46 * s),
                 xRadius: 23 * s, yRadius: 23 * s).fill()

    // Kırmızı yazım-denetimi kıvrımı (ikinci çubuğun altında)
    let squiggle = NSBezierPath()
    squiggle.lineWidth = 26 * s
    squiggle.lineCapStyle = .round
    squiggle.lineJoinStyle = .round
    let y0: CGFloat = 432 * s
    let amp: CGFloat = 22 * s
    squiggle.move(to: NSPoint(x: 320 * s, y: y0))
    var up = true
    var x = 320 * s + 35 * s
    while x <= 600 * s {
        squiggle.line(to: NSPoint(x: x, y: up ? y0 + amp : y0 - amp))
        up.toggle()
        x += 35 * s
    }
    NSColor(calibratedRed: 0.92, green: 0.20, blue: 0.16, alpha: 1).setStroke()
    squiggle.stroke()

    img.unlockFocus()
    return img
}

func savePNG(_ image: NSImage, px: Int, name: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!
        .write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
}

for base in [16, 32, 128, 256, 512] {
    let img = draw(size: CGFloat(base * 2))
    savePNG(img, px: base, name: "icon_\(base)x\(base).png")
    savePNG(img, px: base * 2, name: "icon_\(base)x\(base)@2x.png")
}

// Menübar template ikonu: tek renk siluet (balon + delik olarak kıvrım).
// Sistem, template'i açık/koyu temaya göre kendisi boyar.
func drawMenuBar(px: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: px, height: px))
    img.lockFocus()
    let s = px / 18.0

    let bubble = NSBezierPath(roundedRect: NSRect(x: 1 * s, y: 5 * s, width: 16 * s, height: 12 * s),
                              xRadius: 4 * s, yRadius: 4 * s)
    let tail = NSBezierPath()
    tail.move(to: NSPoint(x: 4.5 * s, y: 6 * s))
    tail.line(to: NSPoint(x: 3 * s, y: 1.5 * s))
    tail.line(to: NSPoint(x: 8.5 * s, y: 5.5 * s))
    tail.close()
    NSColor.black.setFill()
    bubble.fill()
    tail.fill()

    // Kıvrım balondan "delinir" (destinationOut) — template'te delik şeffaf kalır
    NSGraphicsContext.current?.compositingOperation = .destinationOut
    let squiggle = NSBezierPath()
    squiggle.lineWidth = 1.9 * s
    squiggle.lineCapStyle = .round
    squiggle.lineJoinStyle = .round
    let y0: CGFloat = 9 * s
    let amp: CGFloat = 1.4 * s
    squiggle.move(to: NSPoint(x: 4 * s, y: y0))
    var up = true
    var x: CGFloat = 6 * s
    while x <= 14 * s {
        squiggle.line(to: NSPoint(x: x, y: up ? y0 + amp : y0 - amp))
        up.toggle()
        x += 2.5 * s
    }
    NSColor.black.setStroke()
    squiggle.stroke()

    img.unlockFocus()
    return img
}

// Tek dosya, 36px (retina); app 18pt boyutuyla yükler
savePNG(drawMenuBar(px: 36), px: 36, name: "MenuBarIcon.png")
print("OK: \(outDir)")
