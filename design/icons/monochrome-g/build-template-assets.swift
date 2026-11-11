import CoreGraphics
import Foundation
import ImageIO

enum TemplateAssetError: Error {
    case invalidImage(URL)
    case missingContext
    case cannotWrite(URL)
}

let designDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repositoryDirectory = designDirectory.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let resourceDirectory = repositoryDirectory.appendingPathComponent("Sources/ClashBar/Resources/Assets.xcassets")
let canvasWidth = 448
let canvasHeight = 352
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
let darkLuminance = (0.2126 * 37 + 0.7152 * 39 + 0.0722 * 42) / 255
let lightLuminance = (0.2126 * 241 + 0.7152 * 242 + 0.0722 * 244) / 255
let states = [
    (node: "A5IDi", name: "sleep", asset: "BrandSleep"),
    (node: "zDtFj", name: "run", asset: "BrandRun"),
    (node: "Fw7dr", name: "tun", asset: "BrandTun"),
    (node: "rt09c", name: "warning", asset: "BrandWarning"),
]

for state in states {
    let sourceURL = designDirectory.appendingPathComponent("source/\(state.node).png")
    guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
          let sourceImage = CGImageSourceCreateImageAtIndex(source, 0, nil),
          sourceImage.width >= canvasWidth, sourceImage.height == canvasHeight,
          let croppedImage = sourceImage.cropping(to: CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
    else { throw TemplateAssetError.invalidImage(sourceURL) }

    guard let context = CGContext(
        data: nil,
        width: canvasWidth,
        height: canvasHeight,
        bitsPerComponent: 8,
        bytesPerRow: canvasWidth * 4,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
        let pixels = context.data?.assumingMemoryBound(to: UInt8.self)
    else { throw TemplateAssetError.missingContext }

    context.draw(croppedImage, in: CGRect(x: 0, y: 0, width: canvasWidth, height: canvasHeight))
    for pixel in 0..<(canvasWidth * canvasHeight) {
        let offset = pixel * 4
        let alpha = Double(pixels[offset + 3]) / 255
        let luminance = alpha > 0
            ? (0.2126 * Double(pixels[offset]) + 0.7152 * Double(pixels[offset + 1]) + 0.0722 * Double(pixels[offset + 2])) / (255 * alpha)
            : lightLuminance
        let coverage = min(1, max(0, (lightLuminance - luminance) / (lightLuminance - darkLuminance)))
        pixels[offset] = 0
        pixels[offset + 1] = 0
        pixels[offset + 2] = 0
        pixels[offset + 3] = UInt8((alpha * coverage * 255).rounded())
    }

    guard let templateImage = context.makeImage() else { throw TemplateAssetError.missingContext }
    let fileName = "icon-\(state.name).png"
    let outputURL = designDirectory.appendingPathComponent(fileName)
    guard let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, "public.png" as CFString, 1, nil)
    else { throw TemplateAssetError.cannotWrite(outputURL) }
    CGImageDestinationAddImage(destination, templateImage, nil)
    guard CGImageDestinationFinalize(destination) else { throw TemplateAssetError.cannotWrite(outputURL) }
    let assetURL = resourceDirectory.appendingPathComponent("\(state.asset).imageset/\(fileName)")
    try Data(contentsOf: outputURL).write(to: assetURL, options: .atomic)
    print("Prepared \(state.asset): \(canvasWidth) × \(canvasHeight), transparent monochrome template")
}
