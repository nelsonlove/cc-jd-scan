# jd-scan — Claude Code Plugin

Self-contained scan-triage plugin for Claude Code. OCRs scanned PDFs using Apple Vision, segments multi-page scans into individual documents, and files each into paperless-ngx (with Vision text layer preserved) and the JD `01.01` capture inbox.

## What it does

1. **OCR** — Apple Vision framework via `ocr.swift`. Outputs per-page JSON (text + confidence) and optionally page images for visual inspection.
2. **Segment** — Claude visually inspects page images + OCR text to detect document boundaries and classify each document.
3. **Text-layer PDF** — `ocr.swift --text-layer-pdf` embeds an invisible Vision OCR text layer into the PDF, making it searchable without altering the original scan appearance.
4. **File** — `paperless-ingest.sh` uploads the searchable PDF to paperless-ngx (setting a `JDID` custom field for later routing) and copies it to the `01.01` capture inbox.

Documents stage in `01.01` and are tagged with their JDID in paperless. Routing from `01.01` to the final category folder is a separate future step.

## Scripts

| Script | Purpose |
|--------|---------|
| `scripts/ocr.swift` | Apple Vision OCR — JSON output or `--text-layer-pdf` mode |
| `scripts/split-pdf.sh` | Split a PDF by page range/spec (requires poppler) |
| `scripts/paperless-ingest.sh` | Upload to paperless-ngx + copy to 01.01 inbox |
| `scripts/test-text-layer.sh` | Smoke test for the Vision text-layer pipeline |

## Requirements

- macOS (Apple Vision framework, Swift)
- `poppler` (for `pdfseparate`, `pdfunite`, `pdftotext`) — install via Homebrew: `brew install poppler`
- A running paperless-ngx instance

## Configuration

The plugin reads machine-specific config from `~/.config/jd-scan/` (not committed to this repo):

| File | Purpose |
|------|---------|
| `~/.config/jd-scan/url` | Paperless-ngx base URL (e.g. `https://paperless.example.com`) |
| `~/.config/jd-scan/paperless.token` | Paperless-ngx API token (one line, no trailing newline) |

You can also set `PAPERLESS_URL` and `PAPERLESS_TOKEN` as environment variables, or pass `--url` / `--token-file` flags directly to `paperless-ingest.sh`.

URL resolution order: `--url` flag → `$PAPERLESS_URL` env → `~/.config/jd-scan/url`

Token resolution order: `$PAPERLESS_TOKEN` env → `--token-file` flag → `~/.config/jd-scan/paperless.token`

## Skill

The `skills/scan-triage/SKILL.md` skill drives the full workflow. It uses `${CLAUDE_PLUGIN_ROOT}/scripts/…` for all tool invocations (no hardcoded paths, no `~/.local/bin` dependency).

For JDID classification, the skill reads `~/.local/share/jd/jd-index.yaml` directly — it does not depend on the `jd` CLI.

## Running the text-layer smoke test

```sh
bash scripts/test-text-layer.sh
```

Generates an image-only PDF fixture, runs Vision OCR text-layer mode, then asserts `pdftotext` can extract the known words. Requires poppler and Swift.
