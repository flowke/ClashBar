import CoreGraphics
import Foundation
import ImageIO

// Use native geometry from the confirmed board, not the older source/ exports.
// Light face/shield fills represent transparent cutouts in a system template.
enum TemplateAssetError: Error {
    case invalidGeometry(String)
    case missingNode(String)
    case missingContext
    case cannotWrite(URL)
}

typealias Node = [String: Any]
let designDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repositoryDirectory = designDirectory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let resourceDirectory = repositoryDirectory.appendingPathComponent("Sources/ClashBar/Resources/Assets.xcassets")
let document = try JSONSerialization.jsonObject(with: Data(contentsOf: repositoryDirectory.appendingPathComponent("ClashBar-Pencil-Migrated.pen"))) as! Node
let exportScale: CGFloat = 4

func findNode(_ id: String, in node: Node) -> Node? {
    if node["id"] as? String == id { return node }
    for child in node["children"] as? [Node] ?? [] {
        if let found = findNode(id, in: child) { return found }
    }
    return nil
}

func number(_ node: Node, _ key: String) -> CGFloat {
    CGFloat((node[key] as? NSNumber)?.doubleValue ?? 0)
}

// The masters use M/L/H/V/C/Z. Reject new commands rather than approximate.
func path(from geometry: String) throws -> CGPath {
    let expression = try NSRegularExpression(pattern: "[A-Za-z]|[-+]?(?:[0-9]*\\.)?[0-9]+(?:[eE][-+]?[0-9]+)?")
    let text = geometry as NSString
    let tokens = expression.matches(in: geometry, range: NSRange(location: 0, length: text.length)).map { text.substring(with: $0.range) }
    var index = 0
    var command = ""
    var current = CGPoint.zero
    var start = CGPoint.zero
    let result = CGMutablePath()

    func coordinate() throws -> CGFloat {
        guard index < tokens.count, let value = Double(tokens[index]) else {
            throw TemplateAssetError.invalidGeometry(geometry)
        }
        index += 1
        return CGFloat(value)
    }

    func point(relative: Bool) throws -> CGPoint {
        let x = try coordinate()
        let y = try coordinate()
        return CGPoint(x: x + (relative ? current.x : 0), y: y + (relative ? current.y : 0))
    }

    while index < tokens.count {
        if tokens[index].first?.isLetter == true {
            command = tokens[index]
            index += 1
        }
        let relative = command == command.lowercased()
        switch command.uppercased() {
        case "M":
            current = try point(relative: relative)
            start = current
            result.move(to: current)
            command = relative ? "l" : "L"
        case "L":
            current = try point(relative: relative)
            result.addLine(to: current)
        case "H":
            current.x = try coordinate() + (relative ? current.x : 0)
            result.addLine(to: current)
        case "V":
            current.y = try coordinate() + (relative ? current.y : 0)
            result.addLine(to: current)
        case "C":
            let first = try point(relative: relative)
            let second = try point(relative: relative)
            let end = try point(relative: relative)
            result.addCurve(to: end, control1: first, control2: second)
            current = end
        case "Z":
            result.closeSubpath()
            current = start
            command = ""
        default:
            throw TemplateAssetError.invalidGeometry(command)
        }
    }
    return result
}

func shapePath(_ node: Node) throws -> CGPath {
    let width = number(node, "width")
    let height = number(node, "height")
    if node["type"] as? String == "ellipse" {
        return CGPath(ellipseIn: CGRect(x: 0, y: 0, width: width, height: height), transform: nil)
    }
    guard let geometry = node["geometry"] as? String,
          let box = node["viewBox"] as? [Double], box.count == 4 else {
        throw TemplateAssetError.invalidGeometry(node["id"] as? String ?? "unknown")
    }
    var transform = CGAffineTransform(a: width / box[2], b: 0, c: 0, d: height / box[3],
                                     tx: -box[0] * width / box[2], ty: -box[1] * height / box[3])
    return try path(from: geometry).copy(using: &transform)!
}

func paint(_ value: Any?, in context: CGContext) -> Bool {
    guard let color = value as? String, color != "#00000000" else { return false }
    // Black alpha is the only ink. Erasing also preserves edge antialiasing.
    switch color.uppercased() {
    case "#25272A": context.setBlendMode(.normal)
    case "#F1F2F4": context.setBlendMode(.clear)
    default: preconditionFailure("Unexpected G-master color: \(color)")
    }
    return true
}

func draw(_ node: Node, in context: CGContext, isRoot: Bool = false) throws {
    guard node["enabled"] as? Bool != false else { return }
    context.saveGState()
    defer { context.restoreGState() }
    if !isRoot { context.translateBy(x: number(node, "x"), y: number(node, "y")) }
    if node["clip"] as? Bool == true {
        context.clip(to: CGRect(x: 0, y: 0, width: number(node, "width"), height: number(node, "height")))
    }
    if let children = node["children"] as? [Node] {
        for child in children { try draw(child, in: context) }
        return
    }
    let shape = try shapePath(node)
    if paint(node["fill"], in: context) {
        context.addPath(shape)
        context.fillPath()
    }
    if paint(node["stroke"], in: context) {
        context.saveGState()
        defer { context.restoreGState() }
        let inner = node["strokeAlignment"] as? String == "inner"
        if inner {
            context.addPath(shape)
            context.clip()
        }
        // Stroke width is in the 112×88 master, after viewBox transformation.
        context.setLineWidth(number(node, "strokeWidth") * (inner ? 2 : 1))
        context.setLineJoin(node["strokeLinejoin"] as? String == "round" ? .round : .miter)
        context.setLineCap(node["strokeLinecap"] as? String == "round" ? .round : .butt)
        context.addPath(shape)
        context.strokePath()
    }
}

guard let overview = findNode("N9jU3", in: document),
      let masters = findNode("ou3yE", in: overview) else {
    throw TemplateAssetError.missingNode("confirmed icon overview or monochrome masters")
}

for state in [
    (node: "A5IDi", name: "sleep", asset: "BrandSleep", width: 112),
    (node: "zDtFj", name: "run", asset: "BrandRun", width: 112),
    (node: "Fw7dr", name: "tun", asset: "BrandTun", width: 128),
    // Warning has 16 unused pixels on its right, with no badge to retain.
    (node: "rt09c", name: "warning", asset: "BrandWarning", width: 112),
] {
    guard let node = findNode(state.node, in: masters) else { throw TemplateAssetError.missingNode(state.node) }
    let width = state.width * Int(exportScale)
    let height = 88 * Int(exportScale)
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else {
        throw TemplateAssetError.missingContext
    }
    context.setFillColor(CGColor(gray: 0, alpha: 1))
    context.setStrokeColor(CGColor(gray: 0, alpha: 1))
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: exportScale, y: -exportScale)
    try draw(node, in: context, isRoot: true)
    guard let image = context.makeImage() else { throw TemplateAssetError.missingContext }
    let fileName = "icon-\(state.name).png"
    let output = designDirectory.appendingPathComponent(fileName)
    guard let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil) else {
        throw TemplateAssetError.cannotWrite(output)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw TemplateAssetError.cannotWrite(output) }
    try Data(contentsOf: output).write(to: resourceDirectory.appendingPathComponent("\(state.asset).imageset/\(fileName)"), options: .atomic)
    print("Prepared \(state.asset) from \(state.node): \(width) × \(height), transparent monochrome template")
}
