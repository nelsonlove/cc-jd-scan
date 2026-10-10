#!/usr/bin/env bash
# paperless-ingest.sh — file a Vision text-layer PDF into paperless-ngx,
# set a JDID custom field, and copy it to the JD capture inbox.
#
# Usage:
#   paperless-ingest.sh --pdf <path> --jdid <JDID> [options]
#
# Options:
#   --pdf <path>          Path to the (Vision text-layer) PDF to ingest
#   --jdid <JDID>         Johnny Decimal ID to stamp on the document
#   --title <title>       Document title (default: PDF basename without .pdf)
#   --url <base>          Paperless-ngx base URL
#   --token-file <path>   File containing the API token (one line, no trailing newline required)
#   --inbox <dir>         JD capture inbox directory (default: see below)
#   --no-inbox            Skip copying to the capture inbox
#   --no-paperless        Skip the paperless-ngx upload (inbox copy only)
#
# URL resolution (in order):
#   1. --url <base> argument
#   2. $PAPERLESS_URL environment variable
#   3. ~/.config/jd-scan/url (first line, trimmed)
#   If none resolves, exits with an error message to stderr.
#
# Token resolution (in order):
#   1. $PAPERLESS_TOKEN environment variable
#   2. --token-file <path> argument
#   3. ~/.config/jd-scan/paperless.token (if it exists)
#
# Inbox resolution (in order):
#   1. --inbox <dir> argument
#   2. $JD_CAPTURE_INBOX environment variable
#   3. ~/.config/jd-scan/inbox (first line, trimmed)
#   4. $HOME/Documents/00-09 System/01 Capture/01.01 Inbox for 01 Capture (fallback)
#
# Diagnostics go to stderr. The token and URL hostname are never printed or logged.
# On success, prints the document id and URL to stdout.

set -euo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
PAPERLESS_URL="${PAPERLESS_URL:-}"   # resolved below after arg parsing; preserves inherited env var
POLL_TIMEOUT=120
POLL_INTERVAL=2

# ── Argument parsing ─────────────────────────────────────────────────────────
PDF_PATH=""
JDID=""
TITLE=""
URL_ARG=""
TOKEN_FILE=""
INBOX=""
DO_INBOX=1
DO_PAPERLESS=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pdf)        PDF_PATH="$2"; shift 2 ;;
        --jdid)       JDID="$2"; shift 2 ;;
        --title)      TITLE="$2"; shift 2 ;;
        --url)        URL_ARG="${2%/}"; shift 2 ;;  # strip trailing slash; resolved below
        --token-file) TOKEN_FILE="$2"; shift 2 ;;
        --inbox)      INBOX="$2"; shift 2 ;;
        --no-inbox)   DO_INBOX=0; shift ;;
        --no-paperless) DO_PAPERLESS=0; shift ;;
        -h|--help)
            sed -n '2,/^set /{ /^#/p }' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ── URL resolution ─────────────────────────────────────────────────────────────
if [[ -n "$URL_ARG" ]]; then
    PAPERLESS_URL="${URL_ARG%/}"
elif [[ -n "${PAPERLESS_URL:-}" ]]; then
    PAPERLESS_URL="${PAPERLESS_URL%/}"   # already set from env? strip trailing slash
elif [[ -f "$HOME/.config/jd-scan/url" ]]; then
    PAPERLESS_URL=$(tr -d '[:space:]' < "$HOME/.config/jd-scan/url")
    PAPERLESS_URL="${PAPERLESS_URL%/}"
fi

if [[ -z "${PAPERLESS_URL:-}" ]]; then
    echo "error: no paperless URL: set --url, PAPERLESS_URL, or ~/.config/jd-scan/url" >&2
    exit 1
fi

# ── Inbox resolution ───────────────────────────────────────────────────────────
if [[ -z "$INBOX" ]]; then
    if [[ -n "${JD_CAPTURE_INBOX:-}" ]]; then
        INBOX="$JD_CAPTURE_INBOX"
    elif [[ -f "$HOME/.config/jd-scan/inbox" ]]; then
        INBOX=$(tr -d '\n' < "$HOME/.config/jd-scan/inbox" | sed 's/[[:space:]]*$//')
    else
        INBOX="$HOME/Documents/00-09 System/01 Capture/01.01 Inbox for 01 Capture"
    fi
fi

# ── Validation ───────────────────────────────────────────────────────────────
errors=0

if [[ -z "$PDF_PATH" ]]; then
    echo "error: --pdf is required" >&2
    errors=1
elif [[ ! -f "$PDF_PATH" ]]; then
    echo "error: PDF not found: $PDF_PATH" >&2
    errors=1
fi

if [[ -z "$JDID" ]]; then
    echo "error: --jdid is required" >&2
    errors=1
fi

[[ $errors -eq 1 ]] && exit 1

# ── Title default ─────────────────────────────────────────────────────────────
if [[ -z "$TITLE" ]]; then
    TITLE=$(basename "$PDF_PATH" .pdf)
fi

# ── Token resolution ──────────────────────────────────────────────────────────
TOKEN=""
if [[ -n "${PAPERLESS_TOKEN:-}" ]]; then
    TOKEN="$PAPERLESS_TOKEN"
elif [[ -n "$TOKEN_FILE" ]]; then
    if [[ ! -f "$TOKEN_FILE" ]]; then
        echo "error: token file not found: $TOKEN_FILE" >&2
        exit 1
    fi
    TOKEN=$(tr -d '[:space:]' < "$TOKEN_FILE")
elif [[ -f "$HOME/.config/jd-scan/paperless.token" ]]; then
    TOKEN=$(tr -d '[:space:]' < "$HOME/.config/jd-scan/paperless.token")
fi

if [[ -z "$TOKEN" ]]; then
    echo "error: no Paperless API token found." >&2
    echo "  Set PAPERLESS_TOKEN, pass --token-file, or place token in ~/.config/jd-scan/paperless.token" >&2
    exit 1
fi

# ── Helper: curl with auth (token never echoed) ───────────────────────────────
pl_curl() {
    curl --silent --fail-with-body \
        -H "Authorization: Token $TOKEN" \
        -H "Accept: application/json; version=9" \
        "$@"
}

# Wrapper that prints the error body to stderr on failure instead of silently discarding it.
pl_curl_checked() {
    local out rc
    out=$(pl_curl "$@") || { rc=$?; echo "error: paperless API call failed (curl $rc). Response: ${out:0:300}" >&2; return $rc; }
    printf '%s' "$out"
}

# ── Step 1: Inbox copy ────────────────────────────────────────────────────────
if [[ $DO_INBOX -eq 1 ]]; then
    if [[ ! -d "$INBOX" ]]; then
        echo "info: creating inbox directory: $INBOX" >&2
        mkdir -p "$INBOX"
    fi
    INBOX_DEST="$INBOX/$(basename "$PDF_PATH")"
    cp "$PDF_PATH" "$INBOX_DEST"
    echo "info: inbox copy → $INBOX_DEST" >&2
fi

# ── Step 2: Paperless ingest ──────────────────────────────────────────────────
if [[ $DO_PAPERLESS -eq 1 ]]; then

    # 2a. Ensure JDID custom field exists
    echo "info: checking custom fields..." >&2
    CF_RESPONSE=$(pl_curl_checked "${PAPERLESS_URL}/api/custom_fields/")
    FIELD_ID=$(echo "$CF_RESPONSE" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for f in data.get('results', []):
    if f['name'] == 'JDID':
        print(f['id'])
        break
")

    if [[ -z "$FIELD_ID" ]]; then
        echo "info: creating JDID custom field…" >&2
        CREATE_RESPONSE=$(pl_curl_checked \
            -X POST "${PAPERLESS_URL}/api/custom_fields/" \
            -H "Content-Type: application/json" \
            -d '{"name":"JDID","data_type":"string"}')
        FIELD_ID=$(echo "$CREATE_RESPONSE" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
        echo "info: created JDID custom field id=$FIELD_ID" >&2
    else
        echo "info: JDID custom field exists, id=$FIELD_ID" >&2
    fi

    # 2b. Upload the PDF
    echo "info: uploading $(basename "$PDF_PATH")…" >&2
    UPLOAD_RESPONSE=$(pl_curl_checked \
        -X POST "${PAPERLESS_URL}/api/documents/post_document/" \
        -F "document=@${PDF_PATH}" \
        -F "title=${TITLE}")

    # Response is a bare JSON string (quoted UUID); fail loudly if the body is a dict/list/error instead.
    TASK_UUID=$(echo "$UPLOAD_RESPONSE" | python3 -c "
import sys, json
val = json.load(sys.stdin)
if not isinstance(val, str):
    print('error: expected a task UUID string from post_document, got: ' + json.dumps(val)[:200], file=sys.stderr)
    sys.exit(1)
print(val)
") || { echo "error: bad upload response" >&2; exit 1; }
    echo "info: task UUID=$TASK_UUID" >&2

    # 2c. Poll until terminal status
    echo "info: polling for task completion (timeout ${POLL_TIMEOUT}s)..." >&2
    elapsed=0
    DOC_ID=""
    while [[ $elapsed -lt $POLL_TIMEOUT ]]; do
        TASK_RESPONSE=$(pl_curl_checked "${PAPERLESS_URL}/api/tasks/?task_id=${TASK_UUID}")
        STATUS=$(echo "$TASK_RESPONSE" | python3 -c "
import sys, json
items = json.load(sys.stdin)
if items:
    print(items[0].get('status', ''))
else:
    print('WAITING')
")
        case "$STATUS" in
            SUCCESS)
                DOC_ID=$(echo "$TASK_RESPONSE" | python3 -c "
import sys, json
items = json.load(sys.stdin)
print(items[0].get('related_document', ''))
")
                break
                ;;
            FAILURE)
                REASON=$(echo "$TASK_RESPONSE" | python3 -c "import sys,json; a=json.load(sys.stdin); print((a[0].get('result') if a else '') or 'unknown')" 2>/dev/null || echo unknown)
                echo "error: paperless task failed: $REASON" >&2
                exit 1
                ;;
            PENDING|STARTED|WAITING)
                echo "info: status=$STATUS (${elapsed}s elapsed)..." >&2
                sleep "$POLL_INTERVAL"
                elapsed=$((elapsed + POLL_INTERVAL))
                ;;
            *)
                echo "error: unexpected task status: $STATUS" >&2
                exit 1
                ;;
        esac
    done

    if [[ -z "$DOC_ID" ]]; then
        echo "error: timed out waiting for paperless task after ${POLL_TIMEOUT}s" >&2
        exit 1
    fi

    echo "info: document created, id=$DOC_ID" >&2

    # NOTE: this PATCH replaces the document's custom_fields array (sets only JDID). Fine here — freshly-ingested docs have no other fields.
    # 2d. PATCH the JDID custom field
    echo "info: setting JDID=$JDID on document ${DOC_ID}..." >&2
    PATCH_PAYLOAD=$(python3 -c "
import json, sys
payload = {'custom_fields': [{'field': int(sys.argv[1]), 'value': sys.argv[2]}]}
print(json.dumps(payload))
" "$FIELD_ID" "$JDID")

    pl_curl_checked \
        -X PATCH "${PAPERLESS_URL}/api/documents/${DOC_ID}/" \
        -H "Content-Type: application/json" \
        -d "$PATCH_PAYLOAD" > /dev/null

    echo "info: JDID field set" >&2

    # 2e. Report
    echo "${DOC_ID}"
    echo "${PAPERLESS_URL}/documents/${DOC_ID}/"
fi
