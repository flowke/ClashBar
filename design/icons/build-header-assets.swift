import CoreGraphics
import Foundation
import ImageIO

enum HeaderAssetError: Error {
    case invalidImage(URL)
    case missingContext
    case cannotWrite(URL)
}

let designDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let repositoryDirectory = designDirectory.deletingLastPathComponent().deletingLastPathComponent()
let resourceDirectory = repositoryDirectory.appendingPathComponent("Sources/ClashBar/Resources/Assets.xcassets")

let sleepSourceURL = designDirectory.appendingPathComponent("monochrome-g/icon-sleep.png")
let sleepOutputURL = resourceDirectory.appendingPathComponent("BrandHeaderSleep.imageset/logo-header-sleep.png")
try Data(contentsOf: sleepSourceURL).write(to: sleepOutputURL, options: .atomic)
print("Prepared BrandHeaderSleep: latest G outline artwork")

for (source, asset, fileName) in [
    ("menu-bar-emerald/Lnf10.png", "BrandHeader", "logo-header.png"),
    ("menu-bar-emerald/eDYDX.png", "BrandHeaderTun", "logo-header-tun.png"),
] {
    let sourceURL = designDirectory.appendingPathComponent(source)
    let assetURL = resourceDirectory.appendingPathComponent("\(asset).imageset/\(fileName)")
    try Data(contentsOf: sourceURL).write(to: assetURL, options: .atomic)
    print("Prepared \(asset): original emerald artwork")
}

let warningSourceURL = designDirectory.appendingPathComponent("monochrome-g/icon-warning.png")
guard let warningSource = CGImageSourceCreateWithURL(warningSourceURL as CFURL, nil),
      let warningImage = CGImageSourceCreateImageAtIndex(warningSource, 0, nil)
else { throw HeaderAssetError.invalidImage(warningSourceURL) }

guard let context = CGContext(
    data: nil,
    width: warningImage.width,
    height: warningImage.height,
    bitsPerComponent: 8,
    bytesPerRow: warningImage.width * 4,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
    let pixels = context.data?.assumingMemoryBound(to: UInt8.self)
else { throw HeaderAssetError.missingContext }

context.draw(warningImage, in: CGRect(x: 0, y: 0, width: warningImage.width, height: warningImage.height))
for pixel in 0..<(warningImage.width * warningImage.height) {
    let offset = pixel * 4
    let alpha = Double(pixels[offset + 3]) / 255
    pixels[offset] = UInt8((255 * alpha).rounded())
    pixels[offset + 1] = UInt8((176 * alpha).rounded())
    pixels[offset + 2] = UInt8((32 * alpha).rounded())
}

let outputURL = resourceDirectory.appendingPathComponent("BrandHeaderWarning.imageset/logo-header-warning.png")
guard let tintedWarning = context.makeImage(),
      let destination = CGImageDestinationCreateWithURL(outputURL as CFURL, "public.png" as CFString, 1, nil)
else { throw HeaderAssetError.cannotWrite(outputURL) }
CGImageDestinationAddImage(destination, tintedWarning, nil)
guard CGImageDestinationFinalize(destination) else { throw HeaderAssetError.cannotWrite(outputURL) }
print("Prepared BrandHeaderWarning: yellow outline with the final G expression and no badge")
