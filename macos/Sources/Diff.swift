import AppKit
import CoreGraphics

/// Comparaison avant / après : où la page a-t-elle changé ?
struct DiffResult {
    let percent: Double              // part de la page qui a changé
    let regions: [CGRect]            // zones modifiées (pixels, origine en haut à gauche)
    let heightBefore: Int
    let heightAfter: Int

    var unchanged: Bool { regions.isEmpty && heightBefore == heightAfter }
}

enum Differ {
    /// Pixels RVBA d'une image, à une largeur donnée (origine en haut à gauche).
    static func rgba(_ img: CGImage, width: Int) -> (pixels: [UInt8], width: Int, height: Int) {
        let scale = Double(width) / Double(img.width)
        let h = max(1, Int((Double(img.height) * scale).rounded()))
        var buf = [UInt8](repeating: 0, count: width * h * 4)
        buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: h, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.interpolationQuality = .medium
            // CGContext a l'origine en bas : on retourne pour lire de haut en bas
            ctx.translateBy(x: 0, y: CGFloat(h))
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: width, height: h))
        }
        return (buf, width, h)
    }

    static func compare(_ before: CGImage, _ after: CGImage, cell: Int = 12, tolerance: Int = 48) -> DiffResult {
        let w = min(after.width, 1440)
        let a = rgba(before, width: w), b = rgba(after, width: w)
        let h = max(a.height, b.height)
        let cols = (w + cell - 1) / cell, rows = (h + cell - 1) / cell
        var changed = [Bool](repeating: false, count: cols * rows)
        for y in 0..<h {
            let r = y / cell
            for x in 0..<w {
                let c = x / cell
                if changed[r * cols + c] { continue }
                let inA = y < a.height, inB = y < b.height
                if inA != inB { changed[r * cols + c] = true; continue }
                let i = (y * w + x) * 4
                let d = abs(Int(a.pixels[i]) - Int(b.pixels[i])) + abs(Int(a.pixels[i + 1]) - Int(b.pixels[i + 1]))
                    + abs(Int(a.pixels[i + 2]) - Int(b.pixels[i + 2]))
                if d > tolerance { changed[r * cols + c] = true }
            }
        }
        // Regroupe les cases modifiées voisines en zones
        var seen = [Bool](repeating: false, count: changed.count)
        var regions: [CGRect] = []
        var count = 0
        for start in changed.indices where changed[start] && !seen[start] {
            var stack = [start]
            seen[start] = true
            var minC = cols, minR = rows, maxC = 0, maxR = 0
            while let k = stack.popLast() {
                count += 1
                let r = k / cols, c = k % cols
                minC = min(minC, c); maxC = max(maxC, c); minR = min(minR, r); maxR = max(maxR, r)
                for (dr, dc) in [(0, 1), (0, -1), (1, 0), (-1, 0), (1, 1), (-1, -1), (1, -1), (-1, 1)] {
                    let nr = r + dr, nc = c + dc
                    guard nr >= 0, nr < rows, nc >= 0, nc < cols else { continue }
                    let n = nr * cols + nc
                    if changed[n] && !seen[n] { seen[n] = true; stack.append(n) }
                }
            }
            let scale = Double(after.width) / Double(w)
            regions.append(CGRect(x: Double(minC * cell) * scale, y: Double(minR * cell) * scale,
                                  width: Double((maxC - minC + 1) * cell) * scale, height: Double((maxR - minR + 1) * cell) * scale))
        }
        let scaleH = Double(after.width) / Double(w)
        return DiffResult(percent: Double(count) / Double(max(1, changed.count)) * 100, regions: regions,
                          heightBefore: Int(Double(a.height) * scaleH), heightAfter: Int(Double(b.height) * scaleH))
    }

    /// L'image « après » avec les zones modifiées entourées.
    static func overlay(_ after: CGImage, _ diff: DiffResult) -> NSImage {
        let size = NSSize(width: after.width, height: after.height)
        let img = NSImage(size: size)
        img.lockFocus()
        NSImage(cgImage: after, size: size).draw(in: NSRect(origin: .zero, size: size))
        for r in diff.regions {
            let flipped = NSRect(x: r.minX, y: size.height - r.maxY, width: r.width, height: r.height).insetBy(dx: -3, dy: -3)
            NSColor(srgbRed: 1, green: 0.32, blue: 0.32, alpha: 0.18).setFill()
            flipped.fill()
            let p = NSBezierPath(roundedRect: flipped, xRadius: 4, yRadius: 4)
            p.lineWidth = 3
            NSColor(srgbRed: 1, green: 0.32, blue: 0.32, alpha: 0.95).setStroke()
            p.stroke()
        }
        img.unlockFocus()
        return img
    }
}
