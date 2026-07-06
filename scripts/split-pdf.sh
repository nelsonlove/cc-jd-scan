#!/usr/bin/env bash
# Split a PDF by page ranges.
# Usage: split-pdf.sh input.pdf output.pdf 3-7
#        split-pdf.sh input.pdf output.pdf 1,3,5-8
# Requires: poppler (pdfseparate, pdfunite) or ghostscript

set -euo pipefail

if [[ $# -lt 3 ]]; then
    echo "Usage: split-pdf.sh input.pdf output.pdf <page-spec>" >&2
    exit 2
fi

input="$1"
output="$2"
spec="$3"

if ! command -v pdfseparate &>/dev/null; then
    echo "Error: pdfseparate (poppler) not found" >&2
    exit 1
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# Parse page spec into individual page numbers
pages=()
IFS=',' read -ra parts <<< "$spec"
for part in "${parts[@]}"; do
    if [[ "$part" == *-* ]]; then
        start="${part%-*}"
        end="${part#*-}"
        for ((i=start; i<=end; i++)); do
            pages+=("$i")
        done
    else
        pages+=("$part")
    fi
done

# Extract individual pages
for p in "${pages[@]}"; do
    pdfseparate -f "$p" -l "$p" "$input" "$tmpdir/page-%d.pdf" 2>/dev/null
done

# Combine into output
if [ ${#pages[@]} -eq 1 ]; then
    cp "$tmpdir/page-${pages[0]}.pdf" "$output"
else
    page_files=()
    for p in "${pages[@]}"; do
        page_files+=("$tmpdir/page-$p.pdf")
    done
    pdfunite "${page_files[@]}" "$output" 2>/dev/null
fi

echo "Created $output (${#pages[@]} pages)"
