import AppKit
import CoreGraphics
import Foundation
import ImageIO

let fm = FileManager.default

/// 生成白色极简精工版方案 A（纯白珠光阳极铝圆角方框 + 哑光石墨钛金挂锁）
func renderMasterCGImage(pixelSize: Int) -> CGImage {
    let size = CGFloat(pixelSize)
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(
        data: nil,
        width: pixelSize,
        height: pixelSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!

    ctx.setAllowsAntialiasing(true)
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high

    let inset = size * 0.09765625
    let iconRect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let cornerRadius = iconRect.width * 0.225
    let squirclePath = CGPath(roundedRect: iconRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    // 1. 外部柔和环境投影（适配浅色/深色 Dock）
    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -size * 0.020),
        blur: size * 0.040,
        color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.24)
    )
    ctx.addPath(squirclePath)
    ctx.setFillColor(CGColor(srgbRed: 0.98, green: 0.98, blue: 0.99, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    // 2. 纯白哑光珠光表面渐变（顶部纯白 -> 底部极淡冷灰）
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.clip()

    let bgColors = [
        CGColor(srgbRed: 1.00, green: 1.00, blue: 1.00, alpha: 1),
        CGColor(srgbRed: 0.965, green: 0.968, blue: 0.975, alpha: 1),
        CGColor(srgbRed: 0.91, green: 0.915, blue: 0.928, alpha: 1)
    ] as CFArray
    if let bgGrad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 0.55, 1.0]) {
        ctx.drawLinearGradient(
            bgGrad,
            start: CGPoint(x: iconRect.midX, y: iconRect.maxY),
            end: CGPoint(x: iconRect.midX, y: iconRect.minY),
            options: []
        )
    }

    // 顶部柔和白光高光
    let innerRect = iconRect.insetBy(dx: size * 0.008, dy: size * 0.008)
    let innerPath = CGPath(roundedRect: innerRect, cornerWidth: cornerRadius - size * 0.006, cornerHeight: cornerRadius - size * 0.006, transform: nil)
    ctx.addPath(innerPath)
    ctx.setStrokeColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95))
    ctx.setLineWidth(size * 0.006)
    ctx.strokePath()
    ctx.restoreGState()

    // 外缘极细浅银灰轮廓，保证在白色背景下依然清晰锐利
    ctx.saveGState()
    ctx.addPath(squirclePath)
    ctx.setStrokeColor(CGColor(srgbRed: 0.78, green: 0.79, blue: 0.82, alpha: 0.75))
    ctx.setLineWidth(size * 0.005)
    ctx.strokePath()
    ctx.restoreGState()

    // 3. 居中深石墨钛金挂锁（高对比度、极简 shadcn/ui Zinc 质感）
    let cx = size * 0.5
    let bodyW = size * 0.34
    let bodyH = size * 0.27
    let bodyX = cx - bodyW / 2
    let bodyY = size * 0.285
    let bodyRect = CGRect(x: bodyX, y: bodyY, width: bodyW, height: bodyH)
    let bodyRadius = size * 0.036

    let shackleRadius = bodyW * 0.31
    let shackleCenterY = bodyY + bodyH + shackleRadius * 0.26
    let shackleStrokeW = size * 0.044

    let shacklePath = CGMutablePath()
    shacklePath.move(to: CGPoint(x: cx - shackleRadius, y: bodyY + bodyH - size * 0.01))
    shacklePath.addLine(to: CGPoint(x: cx - shackleRadius, y: shackleCenterY))
    shacklePath.addArc(center: CGPoint(x: cx, y: shackleCenterY), radius: shackleRadius, startAngle: .pi, endAngle: 0, clockwise: true)
    shacklePath.addLine(to: CGPoint(x: cx + shackleRadius, y: bodyY + bodyH - size * 0.01))
    let strokedShackle = shacklePath.copy(strokingWithWidth: shackleStrokeW, lineCap: .butt, lineJoin: .round, miterLimit: 4)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.012), blur: size * 0.022, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.18))
    ctx.addPath(strokedShackle)
    ctx.setFillColor(CGColor(srgbRed: 0.22, green: 0.23, blue: 0.26, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(strokedShackle)
    ctx.clip()
    let shackleColors = [
        CGColor(srgbRed: 0.44, green: 0.45, blue: 0.49, alpha: 1),
        CGColor(srgbRed: 0.24, green: 0.25, blue: 0.28, alpha: 1),
        CGColor(srgbRed: 0.14, green: 0.14, blue: 0.16, alpha: 1),
        CGColor(srgbRed: 0.34, green: 0.35, blue: 0.38, alpha: 1)
    ] as CFArray
    if let sGrad = CGGradient(colorsSpace: colorSpace, colors: shackleColors, locations: [0.0, 0.35, 0.72, 1.0]) {
        ctx.drawLinearGradient(
            sGrad,
            start: CGPoint(x: cx - shackleRadius - shackleStrokeW, y: shackleCenterY + shackleRadius),
            end: CGPoint(x: cx + shackleRadius + shackleStrokeW, y: bodyY + bodyH),
            options: []
        )
    }
    ctx.restoreGState()

    // 锁体（深石墨哑光金属）
    let bodyPath = CGPath(roundedRect: bodyRect, cornerWidth: bodyRadius, cornerHeight: bodyRadius, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.016), blur: size * 0.028, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.24))
    ctx.addPath(bodyPath)
    ctx.setFillColor(CGColor(srgbRed: 0.12, green: 0.12, blue: 0.14, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    let metalColors = [
        CGColor(srgbRed: 0.26, green: 0.27, blue: 0.30, alpha: 1),
        CGColor(srgbRed: 0.14, green: 0.145, blue: 0.165, alpha: 1),
        CGColor(srgbRed: 0.08, green: 0.082, blue: 0.095, alpha: 1)
    ] as CFArray
    if let mGrad = CGGradient(colorsSpace: colorSpace, colors: metalColors, locations: [0.0, 0.45, 1.0]) {
        ctx.drawLinearGradient(
            mGrad,
            start: CGPoint(x: bodyRect.minX, y: bodyRect.maxY),
            end: CGPoint(x: bodyRect.maxX, y: bodyRect.minY),
            options: []
        )
    }
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.16))
    ctx.fill(CGRect(x: bodyRect.minX, y: bodyRect.maxY - size * 0.010, width: bodyRect.width, height: size * 0.010))
    ctx.restoreGState()

    // 钥匙孔（亮银白镂空感）
    let holeCircleR = size * 0.030
    let holeCenterY = bodyRect.midY + size * 0.020
    let slotW = size * 0.024
    let slotH = size * 0.060

    let keyholePath = CGMutablePath()
    keyholePath.addEllipse(in: CGRect(x: cx - holeCircleR, y: holeCenterY - holeCircleR, width: holeCircleR * 2, height: holeCircleR * 2))
    let slotRect = CGRect(x: cx - slotW / 2, y: holeCenterY - slotH - holeCircleR * 0.25, width: slotW, height: slotH)
    keyholePath.addRoundedRect(in: slotRect, cornerWidth: size * 0.006, cornerHeight: size * 0.006)

    ctx.saveGState()
    ctx.addPath(keyholePath)
    ctx.setFillColor(CGColor(srgbRed: 0.96, green: 0.97, blue: 0.98, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    return ctx.makeImage()!
}

func pngData(from cgImage: CGImage) throws -> Data {
    let mutableData = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(mutableData, "public.png" as CFString, 1, nil) else {
        throw NSError(domain: "IconGen", code: 1)
    }
    CGImageDestinationAddImage(dest, cgImage, nil)
    guard CGImageDestinationFinalize(dest) else {
        throw NSError(domain: "IconGen", code: 2)
    }
    return mutableData as Data
}

func appendUInt32BE(_ value: UInt32, to data: inout Data) {
    var be = value.bigEndian
    withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
}

let outputIcnsPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Assets/AppIcon.icns"
let outputURL = URL(fileURLWithPath: outputIcnsPath)
try fm.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

let chunks: [(fourCC: String, px: Int)] = [
    ("icp4", 16),
    ("icp5", 32),
    ("icp6", 64),
    ("ic07", 128),
    ("ic08", 256),
    ("ic09", 512),
    ("ic10", 1024),
    ("ic11", 32),
    ("ic12", 64),
    ("ic13", 256),
    ("ic14", 512)
]

var body = Data()
var cache: [Int: Data] = [:]
for (fourCC, px) in chunks {
    let png: Data
    if let cached = cache[px] {
        png = cached
    } else {
        let generated = try pngData(from: renderMasterCGImage(pixelSize: px))
        cache[px] = generated
        png = generated
    }
    body.append(contentsOf: fourCC.utf8)
    appendUInt32BE(UInt32(8 + png.count), to: &body)
    body.append(png)
}

var icns = Data()
icns.append(contentsOf: "icns".utf8)
appendUInt32BE(UInt32(8 + body.count), to: &icns)
icns.append(body)
try icns.write(to: outputURL, options: .atomic)
print("Generated white ICNS (\(icns.count) bytes) at \(outputIcnsPath)")
