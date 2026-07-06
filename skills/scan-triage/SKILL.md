---
name: scan-triage
description: Use when processing scanned documents — OCR (Apple Vision), segment multi-page PDFs into individual documents, classify each, and file into paperless-ngx (Vision text-layer preserved) + the JD 01.01 capture inbox (staged, not yet routed to category folder). Trigger when the user says "scan triage", "process scans", "OCR this", or drops a PDF for filing.
---

# Scan → OCR → Segment → File (paperless + 01.01 staging)

Process scanned multi-page PDFs into individual documents, file each into paperless-ngx with a JDID tag and a searchable Vision text layer, and copy to the `01.01` capture inbox. Documents stage there pending final routing to their category folder (a separate future step).

## Tools

- **OCR / text-layer**: `swift "${CLAUDE_PLUGIN_ROOT}/scripts/ocr.swift" <pdf> [--pages X-Y] [--images]`
- **PDF split**: `bash "${CLAUDE_PLUGIN_ROOT}/scripts/split-pdf.sh" <input.pdf> <output.pdf> <page-spec>`
- **Ingest**: `"${CLAUDE_PLUGIN_ROOT}/scripts/paperless-ingest.sh" --pdf <path> --jdid <JDID> --title "YYYY-MM-DD description"`
- **JD index** (read-only): `~/.local/share/jd/jd-index.yaml` — YAML map of JDID → title; grep or read it to look up valid IDs

## Workflow

### 1. Identify the PDF

If no path is given, check the JD capture inbox (`01.01`; resolved from `$JD_CAPTURE_INBOX` env → `~/.config/jd-scan/inbox` → default `$HOME/Documents/00-09 System/01 Capture/01.01 Inbox for 01 Capture`) for unprocessed PDFs. If multiple are present, list them and ask which to process.

### 2. OCR all pages

```sh
swift "${CLAUDE_PLUGIN_ROOT}/scripts/ocr.swift" <pdf> --images
```

This outputs JSON with per-page text and confidence, plus page images in a temp directory (path printed to stderr).

Read the JSON output. If any page has confidence below 0.5, warn the user — the scan may need preprocessing (deskew, contrast adjustment via ImageMagick).

### 3. Read page images

Use the Read tool to visually examine each page image from the `--images` output. This is critical for:
- Detecting document boundaries (letterheads, form headers, date changes)
- Understanding documents that OCR poorly (handwriting, tables, photos)
- Verifying OCR accuracy

### 4. Segment into documents

Analyze the OCR text AND page images together to identify document boundaries. Look for:
- New letterhead or header
- Different sender/recipient
- Date discontinuities
- Form type changes
- Blank separator pages
- Visual layout changes (letter vs form vs receipt)

Group consecutive pages into documents. For each document determine:
- **Description**: What is this document?
- **Date**: When was it created/received?
- **JDID**: Which JD ID should it be tagged with in paperless? Consult `~/.local/share/jd/jd-index.yaml` — grep it for likely categories and pick a valid ID. When uncertain, use `xx.01` (category unsorted / inbox).
- **Actionable?**: Does this document require follow-up action?
- **Proposed filename**: `YYYY-MM-DD description.pdf`

Do NOT call `jd which`, `jd search`, `jd mv`, or `jd new`. Read the index directly.

### 5. Present classification table and WAIT FOR APPROVAL

Show the user:

| Pages | Document | Date | JDID (paperless tag) | Action needed? |
|-------|----------|------|----------------------|----------------|
| 1-3 | Letter from BKT re: discovery | 2026-02-28 | `26.21` | Review deadlines |
| 4-5 | Capital One statement Feb 2026 | 2026-02-01 | `26.27` | None (filing only) |
| 6 | Star Market receipt | 2026-01-15 | `45.02` | None |

**Wait for user approval before proceeding.** Ask about any uncertain classifications.

### 6. Split, OCR text layer, and ingest — per approved document

For each approved document:

1. **Split to temp file** (named with the final filename):
   ```sh
   bash "${CLAUDE_PLUGIN_ROOT}/scripts/split-pdf.sh" input.pdf /tmp/"YYYY-MM-DD description.pdf" <page-spec>
   ```

2. **Add Vision text layer**:
   ```sh
   swift "${CLAUDE_PLUGIN_ROOT}/scripts/ocr.swift" --text-layer-pdf /tmp/"YYYY-MM-DD description+ocr.pdf" /tmp/"YYYY-MM-DD description.pdf"
   ```

3. **Ingest into paperless + copy to 01.01**:
   ```sh
   "${CLAUDE_PLUGIN_ROOT}/scripts/paperless-ingest.sh" \
     --pdf /tmp/"YYYY-MM-DD description+ocr.pdf" \
     --jdid <JDID> \
     --title "YYYY-MM-DD description"
   ```
   This does both: uploads the searchable PDF to paperless-ngx (setting the JDID custom field) and copies it to the `01.01` capture inbox.

**Note on staging**: After this step the document is searchable in paperless (tagged with its JDID) and present in `01.01`. It is NOT yet moved to its final category folder (e.g. `26.21 Court documents/`). Routing from `01.01` to the category folder is a separate future step. Tell the user: "Filed to paperless (JDID=XX.YY) and staged in 01.01."

### 7. Handle actionable items

If a document needs follow-up, note it in the session summary for the user to capture into their task manager. Do not call `jd_omnifocus_create_task` or any `jd`-prefixed tool. Example summary line:

> ACTION NEEDED — `2026-02-28 BKT discovery deadline letter.pdf` (JDID 26.21): Review deadlines

### 8. Clean up

- Remove temp split/OCR files created in `/tmp/`.
- Ask user whether to delete or keep the original multi-page PDF.
- Report summary: each document, its paperless URL (printed by ingest script), its 01.01 copy path, and any actions needed.

## Rules

- **Always get approval** before splitting or ingesting (step 5 → step 6).
- **Use `--images`** — visual inspection catches what OCR misses.
- **Date-prefix filenames** — `YYYY-MM-DD description.pdf` for chronological sorting.
- **When uncertain about JDID, use `xx.01`** rather than guessing; flag it to the user.
- **Flag low-confidence OCR** — don't silently file documents you can't read.
- **Never delete the original** without explicit user approval.
- **One document = one file** — don't combine unrelated pages.
- **Preserve page order** within each document.
- **The "Destination" column is the JDID** (paperless tag + future routing hint), not a filesystem path.

## Filename conventions

```
YYYY-MM-DD description.pdf
```

Examples:
- `2026-02-28 BKT discovery deadline letter.pdf`
- `2026-02-01 Capital One statement.pdf`
- `2026-01-15 Star Market receipt.pdf`

## Preprocessing (if needed)

If scan quality is poor, suggest preprocessing before OCR:

```sh
# Deskew
convert input.pdf -deskew 40% deskewed.pdf

# Increase contrast
convert input.pdf -contrast-stretch 1%x1% enhanced.pdf

# Both
convert input.pdf -deskew 40% -contrast-stretch 1%x1% cleaned.pdf
```

Then re-run OCR on the preprocessed version.

## paperless-ingest.sh URL and token config

The script resolves the paperless URL (in order): `--url` flag → `$PAPERLESS_URL` env → `~/.config/jd-scan/url`. The API token resolves: `$PAPERLESS_TOKEN` env → `--token-file` flag → `~/.config/jd-scan/paperless.token`. Neither hostname nor token is committed to this repo.
