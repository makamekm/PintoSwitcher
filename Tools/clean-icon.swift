// Убирает артефакты генерации вокруг иконки: оставляет только связную область,
// содержащую центр изображения, всё остальное делает прозрачным.
// Использование: swift Tools/clean-icon.swift in.png out.png
import AppKit

let args = CommandLine.arguments
guard args.count == 3,
      let image = NSImage(contentsOfFile: args[1]),
      let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("usage: clean-icon in.png out.png"); exit(1)
}
let w = cg.width, h = cg.height
var px = [UInt8](repeating: 0, count: w * h * 4)
let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

let threshold: UInt8 = 24
var keep = [Bool](repeating: false, count: w * h)
var stack = [(w / 2) + (h / 2) * w]
keep[stack[0]] = true
while let i = stack.popLast() {
    let x = i % w, y = i / w
    for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
        let nx = x + dx, ny = y + dy
        guard nx >= 0, ny >= 0, nx < w, ny < h else { continue }
        let j = nx + ny * w
        if !keep[j] && px[j * 4 + 3] > threshold { keep[j] = true; stack.append(j) }
    }
}
// Сохраняем мягкий край: пиксели в 3 px от основной области.
var grown = keep
for _ in 0..<3 {
    var next = grown
    for y in 1..<(h - 1) { for x in 1..<(w - 1) where !grown[x + y * w] {
        if grown[x + 1 + y * w] || grown[x - 1 + y * w] || grown[x + (y + 1) * w] || grown[x + (y - 1) * w] {
            next[x + y * w] = true
        }
    } }
    grown = next
}
var cleared = 0
for i in 0..<(w * h) where !grown[i] && px[i * 4 + 3] > 0 {
    px[i * 4] = 0; px[i * 4 + 1] = 0; px[i * 4 + 2] = 0; px[i * 4 + 3] = 0
    cleared += 1
}
let out = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: out)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("очищено пикселей: \(cleared)")
