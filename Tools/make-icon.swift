import AppKit

// Draws the app icon: a mouse seen from above, with the wheel button picked
// out, since that button is what this app exists for. Generated rather than
// checked in as a binary, so it can be adjusted and rebuilt.

let size: CGFloat = 1024
guard let context = CGContext(
    data: nil,
    width: Int(size),
    height: Int(size),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else { exit(1) }

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// Rounded square background, in the proportions macOS app icons use.
let margin = size * 0.085
let plate = CGRect(x: margin, y: margin, width: size - margin * 2, height: size - margin * 2)
let platePath = CGPath(roundedRect: plate, cornerWidth: plate.width * 0.235, cornerHeight: plate.width * 0.235, transform: nil)

context.saveGState()
context.addPath(platePath)
context.clip()
let backdrop = CGGradient(
    colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
    colors: [color(60, 64, 74), color(28, 30, 36)] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(backdrop, start: CGPoint(x: 0, y: size), end: CGPoint(x: 0, y: 0), options: [])
context.restoreGState()

// Mouse body: a capsule, rounder at the top than the bottom.
let bodyWidth = size * 0.36
let bodyHeight = size * 0.54
let body = CGRect(x: (size - bodyWidth) / 2, y: (size - bodyHeight) / 2, width: bodyWidth, height: bodyHeight)
let bodyPath = CGMutablePath()
let topRadius = bodyWidth / 2
let bottomRadius = bodyWidth * 0.42
bodyPath.move(to: CGPoint(x: body.minX, y: body.minY + bottomRadius))
bodyPath.addLine(to: CGPoint(x: body.minX, y: body.maxY - topRadius))
bodyPath.addArc(tangent1End: CGPoint(x: body.minX, y: body.maxY), tangent2End: CGPoint(x: body.midX, y: body.maxY), radius: topRadius)
bodyPath.addArc(tangent1End: CGPoint(x: body.maxX, y: body.maxY), tangent2End: CGPoint(x: body.maxX, y: body.maxY - topRadius), radius: topRadius)
bodyPath.addLine(to: CGPoint(x: body.maxX, y: body.minY + bottomRadius))
bodyPath.addArc(tangent1End: CGPoint(x: body.maxX, y: body.minY), tangent2End: CGPoint(x: body.midX, y: body.minY), radius: bottomRadius)
bodyPath.addArc(tangent1End: CGPoint(x: body.minX, y: body.minY), tangent2End: CGPoint(x: body.minX, y: body.minY + bottomRadius), radius: bottomRadius)
bodyPath.closeSubpath()

context.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.05, color: color(0, 0, 0, 0.45))
context.addPath(bodyPath)
context.setFillColor(color(247, 248, 250))
context.fillPath()
context.setShadow(offset: .zero, blur: 0, color: nil)

// The split between the two main buttons, stopping at the wheel.
let wheelWidth = bodyWidth * 0.17
let wheelHeight = bodyHeight * 0.21
let wheel = CGRect(
    x: body.midX - wheelWidth / 2,
    y: body.maxY - bodyHeight * 0.42,
    width: wheelWidth,
    height: wheelHeight
)

// Seams: the split between the two buttons runs from the top edge down to the
// wheel, and the buttons end below it. Without these the mouse reads as a
// blank capsule with a stray mark on it.
context.setStrokeColor(color(203, 208, 217))
context.setLineWidth(size * 0.014)
context.setLineCap(.round)
context.move(to: CGPoint(x: body.midX, y: body.maxY - size * 0.012))
context.addLine(to: CGPoint(x: body.midX, y: wheel.maxY + size * 0.018))
context.strokePath()

let seamY = wheel.minY - size * 0.028
context.move(to: CGPoint(x: body.minX + size * 0.012, y: seamY))
context.addCurve(
    to: CGPoint(x: body.maxX - size * 0.012, y: seamY),
    control1: CGPoint(x: body.midX - bodyWidth * 0.25, y: seamY - size * 0.016),
    control2: CGPoint(x: body.midX + bodyWidth * 0.25, y: seamY - size * 0.016)
)
context.strokePath()

// The wheel button itself, in the accent colour: the point of the app.
let wheelPath = CGPath(roundedRect: wheel, cornerWidth: wheelWidth / 2, cornerHeight: wheelWidth / 2, transform: nil)
context.addPath(wheelPath)
context.setFillColor(color(10, 132, 255))
context.fillPath()

guard let image = context.makeImage() else { exit(1) }
let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
let bitmap = NSBitmapImageRep(cgImage: image)
guard let data = bitmap.representation(using: .png, properties: [:]) else { exit(1) }
try data.write(to: URL(fileURLWithPath: output))
print("wrote \(output)")
