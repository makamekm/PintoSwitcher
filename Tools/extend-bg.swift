// Расширяет фон DMG вправо, продлевая крайний правый столбец пикселей, чтобы фон
// не обрывался, если Finder откроет окно шире заданного.
// Использование: swift Tools/extend-bg.swift in.png out.png <новая ширина>
import AppKit

let args = CommandLine.arguments
guard args.count == 4, let newWidth = Int(args[3]),
      let image = NSImage(contentsOfFile: args[1]),
      let src = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    print("usage: extend-bg in.png out.png width"); exit(1)
}
let w = src.width, h = src.height
guard newWidth > w else { print("ширина уже \(w)"); exit(1) }
let ctx = CGContext(data: nil, width: newWidth, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Правый столбец, растянутый на всю добавленную ширину.
if let edge = src.cropping(to: CGRect(x: w - 2, y: 0, width: 1, height: h)) {
    ctx.draw(edge, in: CGRect(x: w - 1, y: 0, width: newWidth - w + 1, height: h))
}
ctx.draw(src, in: CGRect(x: 0, y: 0, width: w, height: h))
let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
print("\(args[2]): \(newWidth)x\(h)")
