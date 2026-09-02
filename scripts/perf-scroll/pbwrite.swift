import AppKit
import CoreGraphics
import Foundation

// Clipboard-capture driver: writes `count` unique items to a named NSPasteboard, one every `interval` seconds, so a
// Scopy launched with SCOPY_SERVICE_MONITOR_PASTEBOARD=<name> ingests them exactly like real copies on that board.
// usage: pbwrite <pasteboardName> text|rich|image <count> <intervalSeconds> [sizeArg]
//   text  : plain UTF-8 text of sizeArg bytes (default 2000); index + random suffix keep every item unique
//   rich  : HTML + RTF + plain text of a document with roughly sizeArg bytes of prose (default 2000), like a browser
//           copy: headings, paragraphs and bold runs built as one NSAttributedString
//   image : a sizeArg x sizeArg PNG (default 2000) drawn as a gradient plus the index as text; sets .png and .tiff
// Each item: build the payload, clearContents(), write one NSPasteboardItem carrying all representations, sleep
// `interval`. Prints one line per item: ISO8601 wall-clock time with milliseconds, index, changeCount after the write,
// and the representation sizes.

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
guard args.count >= 5, ["text", "rich", "image"].contains(args[2]),
      let count = Int(args[3]), count > 0, let interval = Double(args[4]), interval >= 0 else {
    FileHandle.standardError.write(Data("usage: pbwrite <pasteboardName> text|rich|image <count> <intervalSeconds> [sizeArg]\n".utf8))
    exit(64)
}
let scenario = args[2]
let size = max(16, args.count > 5 ? (Int(args[5]) ?? 2000) : 2000)
let pasteboard = NSPasteboard(name: NSPasteboard.Name(args[1]))
let iso = ISO8601DateFormatter()
iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
iso.timeZone = TimeZone.current

func textBody(index: Int) -> String {
    var s = "pbwrite text item \(index) \(UUID().uuidString)\n"
    var line = 0
    while s.utf8.count < size {
        line += 1
        s += "item \(index) line \(line): the quick brown fox jumps over the lazy dog 0123456789\n"
    }
    return String(decoding: Array(s.utf8.prefix(size)), as: UTF8.self) // ASCII only, so the cut is exact
}

func richDocument(index: Int) -> NSAttributedString {
    let doc = NSMutableAttributedString()
    let body = NSFont.systemFont(ofSize: 14), bold = NSFont.boldSystemFont(ofSize: 14)
    let h1 = NSFont.boldSystemFont(ofSize: 24), h2 = NSFont.boldSystemFont(ofSize: 18)
    func append(_ text: String, _ font: NSFont) { doc.append(NSAttributedString(string: text, attributes: [.font: font])) }
    append("pbwrite rich item \(index) \(UUID().uuidString)\n", h1)
    var para = 0
    while doc.string.utf8.count < size {
        para += 1
        if para % 3 == 1 { append("Section \(para) of item \(index)\n", h2) }
        append("Paragraph \(para) of item \(index): ", body)
        append("bold run \(para)", bold)
        append(" followed by ordinary prose that keeps going for a while so the copy resembles a web page selection. ", body)
        append("Another bold run", bold)
        append(" and a closing sentence.\n", body)
    }
    return doc
}

func imageData(index: Int) -> (png: Data, tiff: Data) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let t = CGFloat(index % 7) / 7
    let colors = [CGColor(srgbRed: 0.2 + 0.7 * t, green: 0.3, blue: 0.9 - 0.6 * t, alpha: 1),
                  CGColor(srgbRed: 0.9 - 0.7 * t, green: 0.8, blue: 0.2 + 0.5 * t, alpha: 1)]
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size, y: size), options: [])
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    let label = "pbwrite image \(index)\n\(UUID().uuidString)"
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: CGFloat(max(12, size / 16))),
                                                .foregroundColor: NSColor.white]
    NSAttributedString(string: label, attributes: attrs).draw(at: CGPoint(x: CGFloat(size) * 0.05, y: CGFloat(size) * 0.5))
    NSGraphicsContext.restoreGraphicsState()
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return (rep.representation(using: .png, properties: [:])!, rep.tiffRepresentation!)
}

for index in 1...count {
    let item = NSPasteboardItem()
    var sizes: [String] = []
    switch scenario {
    case "text":
        let text = textBody(index: index)
        _ = item.setString(text, forType: .string)
        sizes = ["text=\(text.utf8.count)"]
    case "rich", "rtf", "html":
        let doc = richDocument(index: index)
        let range = NSRange(location: 0, length: doc.length)
        let rtf = doc.rtf(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])!
        let html = try! doc.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
        if scenario != "rtf" { _ = item.setData(html, forType: .html) }
        if scenario != "html" { _ = item.setData(rtf, forType: .rtf) }
        _ = item.setString(doc.string, forType: .string)
        sizes = ["html=\(html.count)", "rtf=\(rtf.count)", "text=\(doc.string.utf8.count)"]
    default:
        let (png, tiff) = imageData(index: index)
        _ = item.setData(png, forType: .png)
        _ = item.setData(tiff, forType: .tiff)
        sizes = ["png=\(png.count)", "tiff=\(tiff.count)", "px=\(size)x\(size)"]
    }
    pasteboard.clearContents()
    let ok = pasteboard.writeObjects([item])
    print("\(iso.string(from: Date())) item \(index)/\(count) changeCount \(pasteboard.changeCount) \(ok ? "ok" : "WRITE-FAILED") \(sizes.joined(separator: " "))")
    Thread.sleep(forTimeInterval: interval)
}
