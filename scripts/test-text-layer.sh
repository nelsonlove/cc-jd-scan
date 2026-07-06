#!/usr/bin/env bash
# test-text-layer.sh — smoke test for ocr.swift --text-layer-pdf
#
# Creates an image-only PDF fixture containing known text, runs the Vision
# text-layer mode, then asserts pdftotext can extract the recognized words.
#
# Usage: bash packages/jd-scan/tools/test-text-layer.sh [tools-dir]
#   tools-dir defaults to the directory containing this script.

set -euo pipefail

TOOLS_DIR="${1:-$(cd "$(dirname "$0")" && pwd)}"
OCR_SWIFT="$TOOLS_DIR/ocr.swift"

TMPDIR_BASE="$(mktemp -d "${TMPDIR:-/tmp}/jd-scan-textlayer.XXXXXX")"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

FIXTURE_SWIFT="$TMPDIR_BASE/make-fixture.swift"
FIXTURE_PDF="$TMPDIR_BASE/fixture.pdf"
OUTPUT_PDF="$TMPDIR_BASE/out.pdf"

echo "=== jd-scan text-layer PDF test ==="
echo "Tools dir: $TOOLS_DIR"
echo "Tmp dir:   $TMPDIR_BASE"

# ── Step 1: Write and compile a tiny Swift fixture generator ─────────────────
# It draws the known text phrase as rasterized pixels into a bitmap context,
# then embeds the resulting CGImage as an XObject into a one-page PDF.
# The PDF therefore has NO text content stream — only an image stream.

cat > "$FIXTURE_SWIFT" << 'SWIFTEOF'
#!/usr/bin/env swift
import CoreGraphics
import CoreText
import Foundation

guard CommandLine.arguments.count > 1 else {
    fputs("Usage: make-fixture.swift <output.pdf>\n", stderr); exit(1)
}
let outPath = CommandLine.arguments[1]
let knownText = "The quick brown fox jumps 12345"
let W = 612
let H = 200

// Render text as pixels (bitmap context — no PDF text stream)
let cs = CGColorSpaceCreateDeviceRGB()
guard let bmp = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8,
        bytesPerRow: W * 4, space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    fputs("Error: bitmap context\n", stderr); exit(1)
}
bmp.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
bmp.fill(CGRect(x: 0, y: 0, width: W, height: H))
bmp.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
let font = CTFontCreateWithName("Helvetica" as CFString, 36, nil)
let cfAttrs = [kCTFontAttributeName: font] as CFDictionary
let cfStr = CFAttributedStringCreate(nil, knownText as CFString, cfAttrs)!
let line = CTLineCreateWithAttributedString(cfStr)
bmp.textPosition = CGPoint(x: 40, y: 80)
CTLineDraw(line, bmp)

guard let img = bmp.makeImage() else {
    fputs("Error: makeImage\n", stderr); exit(1)
}

// Embed image into PDF (no text content stream — image XObject only)
let outURL = URL(fileURLWithPath: outPath)
var box = CGRect(x: 0, y: 0, width: CGFloat(W), height: CGFloat(H))
guard let pdfCtx = CGContext(outURL as CFURL, mediaBox: &box, nil) else {
    fputs("Error: PDF context\n", stderr); exit(1)
}
var pageBox = box
let boxData = Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size)
pdfCtx.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
pdfCtx.draw(img, in: box)   // CGImage → PDF image XObject, NOT a text stream
pdfCtx.endPDFPage()
pdfCtx.closePDF()
print("Fixture written: \(outPath)")
SWIFTEOF

echo ""
echo "▶ Generating image-only fixture..."
swift "$FIXTURE_SWIFT" "$FIXTURE_PDF"

# ── Step 2: Verify fixture has no extractable text ───────────────────────────
FIXTURE_TEXT=$(pdftotext "$FIXTURE_PDF" - 2>/dev/null)
FIXTURE_CHARS=$(echo -n "$FIXTURE_TEXT" | wc -c | tr -d ' ')
echo "Fixture char count from pdftotext: $FIXTURE_CHARS"
if [ "$FIXTURE_CHARS" -gt 10 ]; then
    echo "WARNING: fixture already has ~$FIXTURE_CHARS chars of text — fixture generation may not be truly image-only"
else
    echo "✓ Fixture confirmed: no extractable text (≤10 chars)"
fi

# ── Step 3: Run ocr.swift --text-layer-pdf ───────────────────────────────────
echo ""
echo "▶ Running Vision text-layer OCR..."
swift "$OCR_SWIFT" --text-layer-pdf "$OUTPUT_PDF" "$FIXTURE_PDF"

# ── Step 4: Extract text with pdftotext and assert ───────────────────────────
echo ""
echo "▶ Checking extracted text..."
EXTRACTED=$(pdftotext "$OUTPUT_PDF" - 2>/dev/null)
echo "Extracted: $EXTRACTED"
echo ""

PASS=true
for word in "quick" "fox" "12345"; do
    if echo "$EXTRACTED" | grep -qi "$word"; then
        echo "PASS: found '$word'"
    else
        echo "FAIL: missing '$word'"
        PASS=false
    fi
done

echo ""
if $PASS; then
    echo "=== RESULT: PASS ==="
    exit 0
else
    echo "=== RESULT: FAIL ==="
    exit 1
fi
