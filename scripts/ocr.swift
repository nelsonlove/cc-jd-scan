#!/usr/bin/env swift

// jd-scan OCR helper
// Uses Apple Vision framework to OCR PDF pages.
// Usage: swift ocr.swift <input.pdf> [--pages 1-3,5,7-9] [--images]
//        swift ocr.swift --text-layer-pdf <output.pdf> <input.pdf>
// Output (default): JSON array of {page, text, confidence} to stdout.
// Output (--text-layer-pdf): searchable PDF with invisible Vision OCR text layer.
// With --images, also saves page images to a temp dir and includes paths.

import Foundation
import Vision
import CoreGraphics
import CoreText
import ImageIO

// MARK: - Argument parsing

var args = CommandLine.arguments.dropFirst()
var pdfPath: String?
var pageRanges: [ClosedRange<Int>]?
var outputImages = false
var imageDPI: CGFloat = 200
var textLayerPDFOutput: String?

while let arg = args.first {
    args = args.dropFirst()
    switch arg {
    case "--pages":
        guard let spec = args.first else {
            fputs("Error: --pages requires a value (e.g. 1-3,5,7-9)\n", stderr)
            exit(1)
        }
        args = args.dropFirst()
        pageRanges = parsePageSpec(spec)
    case "--images":
        outputImages = true
    case "--dpi":
        guard let val = args.first, let dpi = Double(val) else {
            fputs("Error: --dpi requires a number\n", stderr)
            exit(1)
        }
        args = args.dropFirst()
        imageDPI = CGFloat(dpi)
    case "--text-layer-pdf":
        guard let outPath = args.first else {
            fputs("Error: --text-layer-pdf requires an output path\n", stderr)
            exit(1)
        }
        args = args.dropFirst()
        textLayerPDFOutput = outPath
    default:
        if pdfPath == nil {
            pdfPath = arg
        } else {
            fputs("Error: unexpected argument '\(arg)'\n", stderr)
            exit(1)
        }
    }
}

guard let inputPath = pdfPath else {
    fputs("Usage:\n", stderr)
    fputs("  ocr.swift <input.pdf> [--pages 1-3,5] [--images] [--dpi 200]\n", stderr)
    fputs("  ocr.swift --text-layer-pdf <output.pdf> <input.pdf>\n", stderr)
    exit(1)
}

// MARK: - Helpers

func parsePageSpec(_ spec: String) -> [ClosedRange<Int>] {
    spec.split(separator: ",").compactMap { part in
        let trimmed = part.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("-") {
            let bounds = trimmed.split(separator: "-").compactMap { Int($0) }
            guard bounds.count == 2 else { return nil }
            return bounds[0]...bounds[1]
        } else if let n = Int(trimmed) {
            return n...n
        }
        return nil
    }
}

func shouldProcessPage(_ page: Int) -> Bool {
    guard let ranges = pageRanges else { return true }
    return ranges.contains { $0.contains(page) }
}

/// Render a CGPDFPage to a CGImage at the given DPI.
func renderPage(_ pdfPage: CGPDFPage, dpi: CGFloat) -> CGImage? {
    let mediaBox = pdfPage.getBoxRect(.mediaBox)
    let scale = dpi / 72.0
    let width = Int(mediaBox.width * scale)
    let height = Int(mediaBox.height * scale)

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.scaleBy(x: scale, y: scale)
    ctx.drawPDFPage(pdfPage)
    return ctx.makeImage()
}

/// Run VNRecognizeTextRequest on a CGImage; returns observations.
func recognizeText(in cgImage: CGImage) -> [VNRecognizedTextObservation] {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    do { try handler.perform([request]) }
    catch { fputs("Warning: OCR failed: \(error)\n", stderr) }
    return request.results ?? []
}

// MARK: - Text-layer PDF mode

if let outputPath = textLayerPDFOutput {
    let inURL = URL(fileURLWithPath: inputPath)
    guard let pdfDoc = CGPDFDocument(inURL as CFURL) else {
        fputs("Error: could not open PDF at \(inputPath)\n", stderr)
        exit(1)
    }

    let outURL = URL(fileURLWithPath: outputPath)

    // CGContext(url:mediaBox:) — pass nil for the global media box; we'll set it per page.
    var zeroBox = CGRect.zero
    guard let pdfCtx = CGContext(outURL as CFURL, mediaBox: &zeroBox, nil) else {
        fputs("Error: could not create output PDF context at \(outputPath)\n", stderr)
        exit(1)
    }

    let pageCount = pdfDoc.numberOfPages
    fputs("Processing \(pageCount) page(s) for text-layer PDF...\n", stderr)

    guard pageCount > 0 else {
        fputs("Warning: PDF has no pages.\n", stderr)
        pdfCtx.closePDF()
        exit(0)
    }

    for pageNum in 1...pageCount {
        guard let pdfPage = pdfDoc.page(at: pageNum) else {
            fputs("Warning: could not load page \(pageNum)\n", stderr)
            continue
        }

        let mediaBox = pdfPage.getBoxRect(.mediaBox)
        let pageW = mediaBox.width
        let pageH = mediaBox.height

        // Render at 300 DPI for accurate Vision OCR
        guard let cgImage = renderPage(pdfPage, dpi: 300) else {
            fputs("Warning: could not render page \(pageNum)\n", stderr)
            continue
        }

        // Run Vision OCR
        let observations = recognizeText(in: cgImage)
        fputs("  Page \(pageNum): \(observations.count) text observation(s)\n", stderr)

        // Begin a new PDF page with the correct media box
        var pageBox = CGRect(x: 0, y: 0, width: pageW, height: pageH)
        let pageBoxData = Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size)
        let pageInfo = [kCGPDFContextMediaBox as String: pageBoxData] as CFDictionary
        pdfCtx.beginPDFPage(pageInfo)

        // Draw the original PDF page to preserve visual fidelity
        pdfCtx.drawPDFPage(pdfPage)

        // Overlay invisible text so the content stream is searchable.
        // Text draw mode 3 (invisible) = glyphs are not painted but ARE present
        // in the PDF content stream and thus extractable by pdftotext / Preview.
        pdfCtx.setTextDrawingMode(.invisible)

        // Sort: top-to-bottom (higher normalized Y first since Vision origin is
        // bottom-left, same as PDF/Quartz — a higher .midY value is nearer the top
        // of the page), then left-to-right within a line.
        let sorted = observations.sorted { a, b in
            let ay = a.boundingBox.midY
            let by_ = b.boundingBox.midY
            if abs(ay - by_) > 0.005 { return ay > by_ }
            return a.boundingBox.minX < b.boundingBox.minX
        }

        for obs in sorted {
            guard let candidate = obs.topCandidates(1).first else { continue }
            let text = candidate.string
            guard !text.isEmpty else { continue }

            // Vision bounding box: normalized, origin bottom-left (same as Quartz).
            // Map to page points directly — no vertical flip needed.
            let bbox = obs.boundingBox
            let x = bbox.minX * pageW
            let y = bbox.minY * pageH
            let h = bbox.height * pageH

            // Font sized to the observation height so text approximately fills the box.
            let fontSize = max(6.0, h)
            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)

            // Build attributed string with CoreText font attribute
            let cfAttrs = [kCTFontAttributeName: font] as CFDictionary
            guard let cfStr = CFAttributedStringCreate(nil, text as CFString, cfAttrs) else { continue }
            let line = CTLineCreateWithAttributedString(cfStr)

            // Position the baseline at (x, y) — bottom-left of the Vision bbox
            pdfCtx.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(line, pdfCtx)
        }

        pdfCtx.endPDFPage()
    }

    pdfCtx.closePDF()
    fputs("Written: \(outputPath)\n", stderr)
    exit(0)
}

// MARK: - PDF loading (JSON mode)

let url = URL(fileURLWithPath: inputPath)
guard let pdfDoc = CGPDFDocument(url as CFURL) else {
    fputs("Error: could not open PDF at \(inputPath)\n", stderr)
    exit(1)
}

let pageCount = pdfDoc.numberOfPages
var imageDir: String?

if outputImages {
    let tmpDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("jd-scan-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    imageDir = tmpDir.path
}

// MARK: - OCR each page

struct PageResult: Codable {
    let page: Int
    let text: String
    let confidence: Double
    let imagePath: String?
}

var results: [PageResult] = []

guard pageCount > 0 else {
    print("[]")
    exit(0)
}

for pageNum in 1...pageCount {
    guard shouldProcessPage(pageNum) else { continue }
    guard let pdfPage = pdfDoc.page(at: pageNum) else { continue }

    // Render page to CGImage
    let mediaBox = pdfPage.getBoxRect(.mediaBox)
    let scale = imageDPI / 72.0
    let width = Int(mediaBox.width * scale)
    let height = Int(mediaBox.height * scale)

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fputs("Warning: could not create context for page \(pageNum)\n", stderr)
        continue
    }

    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    ctx.scaleBy(x: scale, y: scale)
    ctx.drawPDFPage(pdfPage)

    guard let cgImage = ctx.makeImage() else {
        fputs("Warning: could not render page \(pageNum)\n", stderr)
        continue
    }

    // Save image if requested
    var savedImagePath: String?
    if let dir = imageDir {
        let imgPath = "\(dir)/page-\(String(format: "%03d", pageNum)).png"
        let imgURL = URL(fileURLWithPath: imgPath)
        if let dest = CGImageDestinationCreateWithURL(imgURL as CFURL, "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, cgImage, nil)
            CGImageDestinationFinalize(dest)
            savedImagePath = imgPath
        }
    }

    // Run Vision OCR
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true

    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    do { try handler.perform([request]) }
    catch { fputs("Warning: OCR failed on page \(pageNum): \(error)\n", stderr) }

    var pageText = ""
    var totalConfidence: Double = 0
    var observationCount = 0

    if let observations = request.results {
        for obs in observations {
            if let candidate = obs.topCandidates(1).first {
                pageText += candidate.string + "\n"
                totalConfidence += Double(candidate.confidence)
                observationCount += 1
            }
        }
    }

    let avgConfidence = observationCount > 0 ? totalConfidence / Double(observationCount) : 0

    results.append(PageResult(
        page: pageNum,
        text: pageText.trimmingCharacters(in: .whitespacesAndNewlines),
        confidence: (avgConfidence * 1000).rounded() / 1000,
        imagePath: savedImagePath
    ))
}

// MARK: - Output

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
if let json = try? encoder.encode(results) {
    print(String(data: json, encoding: .utf8)!)
}
