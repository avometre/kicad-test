#!/usr/bin/env bash
set -euo pipefail

# BoardDiff KiCad DRC & CI Review GitHub Action runner script
# Dependencies: curl, python3, git

URL="${INPUT_URL:-}"
TOKEN="${INPUT_TOKEN:-}"
OWNER="${INPUT_OWNER:-}"
REPO="${INPUT_REPO:-}"
FILE="${INPUT_FILE:-}"
FAIL_ON="${INPUT_FAIL_ON:-errors}"
TIMEOUT="${INPUT_TIMEOUT:-600}"
GITHUB_TOKEN="${INPUT_GITHUB_TOKEN:-}"

URL="${URL%/}"
FAIL_ON="$(echo "$FAIL_ON" | tr '[:upper:]' '[:lower:]')"
if [ "$FAIL_ON" != "errors" ] && [ "$FAIL_ON" != "warnings" ] && [ "$FAIL_ON" != "never" ]; then
    FAIL_ON="errors"
fi

if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || [ "$TIMEOUT" -le 0 ]; then
    TIMEOUT=600
fi

POLL_INTERVAL="${BOARDDIFF_POLL_INTERVAL:-5}"

set_output() {
    local name="$1"
    local value="$2"
    if [ -n "${GITHUB_OUTPUT:-}" ]; then
        echo "${name}=${value}" >> "$GITHUB_OUTPUT"
    fi
}

# 1. Validate required inputs
MISSING=0
if [ -z "$URL" ]; then
    echo "::error::BoardDiff URL is required (input: 'url')" >&2
    MISSING=1
fi
if [ -z "$TOKEN" ]; then
    echo "::error::BoardDiff API token is required (input: 'token')" >&2
    MISSING=1
fi
if [ -z "$OWNER" ]; then
    echo "::error::BoardDiff owner slug is required (input: 'owner')" >&2
    MISSING=1
fi
if [ -z "$REPO" ]; then
    echo "::error::BoardDiff repo slug is required (input: 'repo')" >&2
    MISSING=1
fi
if [ "$MISSING" -ne 0 ]; then
    exit 1
fi

api_request() {
    local method="$1"
    local path="$2"
    shift 2
    local response
    response=$(curl -s -S -w "\n%{http_code}" -X "$method" \
        -H "Authorization: Bearer ${TOKEN}" \
        "$@" \
        "${URL}${path}" 2>&1)
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        API_HTTP_CODE="000"
        API_BODY="curl network failure: ${response}"
        return $exit_code
    fi
    API_HTTP_CODE=$(echo "$response" | tail -n1)
    API_BODY=$(echo "$response" | sed '$d')
    return 0
}

# 2. Verify token against /api/v1/user
echo "Verifying BoardDiff API token against ${URL}..."
if ! api_request "GET" "/api/v1/user" -H "Accept: application/json"; then
    echo "::error::Could not connect to BoardDiff at ${URL}. ${API_BODY}" >&2
    exit 1
fi

if [ "$API_HTTP_CODE" = "401" ]; then
    echo "::error::Authentication failed (HTTP 401): Missing or invalid BoardDiff API token." >&2
    exit 1
fi
if [ "$API_HTTP_CODE" = "403" ]; then
    echo "::error::Forbidden (HTTP 403): BoardDiff API token lacks required scope." >&2
    exit 1
fi
if [ "$API_HTTP_CODE" != "200" ]; then
    err_msg=$(echo "$API_BODY" | python3 -c "import sys, json
try:
    d = json.loads(sys.stdin.read() or '{}')
    print(d.get('error') or d.get('message') or '')
except Exception:
    print('')
")
    echo "::error::BoardDiff token verification failed (HTTP ${API_HTTP_CODE}): ${err_msg:-Unknown error}" >&2
    exit 1
fi
echo "Token verified successfully."

# 3. Resolve board file(s)
BOARD_FILES=()

if [ -n "$FILE" ]; then
    if [ ! -f "$FILE" ]; then
        echo "::error::Specified board file does not exist: ${FILE}" >&2
        exit 1
    fi
    BOARD_FILES+=("$FILE")
elif [ "${GITHUB_EVENT_NAME:-}" = "pull_request" ] || [ -n "${GITHUB_BASE_REF:-}" ]; then
    BASE_REF="${GITHUB_BASE_REF:-main}"
    if ! git rev-parse --verify "origin/${BASE_REF}" >/dev/null 2>&1 && ! git rev-parse --verify "${BASE_REF}" >/dev/null 2>&1; then
        git fetch origin "${BASE_REF}" >/dev/null 2>&1 || true
    fi
    DIFF_BASE="origin/${BASE_REF}"
    if ! git rev-parse --verify "$DIFF_BASE" >/dev/null 2>&1; then
        DIFF_BASE="${BASE_REF}"
    fi
    if git rev-parse --verify "$DIFF_BASE" >/dev/null 2>&1; then
        while IFS= read -r f; do
            if [ -n "$f" ] && [ -f "$f" ]; then
                BOARD_FILES+=("$f")
            fi
        done < <(git diff --name-only --diff-filter=ACMR "${DIFF_BASE}...HEAD" -- "*.kicad_pcb" 2>/dev/null || true)
    fi
    if [ ${#BOARD_FILES[@]} -eq 0 ]; then
        while IFS= read -r f; do
            if [ -n "$f" ] && [ -f "$f" ]; then
                BOARD_FILES+=("$f")
            fi
        done < <(find . -name "*.kicad_pcb" -not -path "*/.*" -not -path "*/node_modules/*" 2>/dev/null | sed 's|^\./||' | head -n 1)
    fi
else
    BEFORE="${GITHUB_EVENT_BEFORE:-}"
    if [ -z "$BEFORE" ] && [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "${GITHUB_EVENT_PATH:-}" ]; then
        BEFORE=$(python3 -c "import json
try:
    with open('${GITHUB_EVENT_PATH}', 'r') as f:
        print(json.load(f).get('before', ''))
except Exception:
    print('')
" 2>/dev/null || true)
    fi

    if [ -n "$BEFORE" ] && [[ ! "$BEFORE" =~ ^0+$ ]] && git rev-parse --verify "$BEFORE" >/dev/null 2>&1; then
        while IFS= read -r f; do
            if [ -n "$f" ] && [ -f "$f" ]; then
                BOARD_FILES+=("$f")
            fi
        done < <(git diff --name-only --diff-filter=ACMR "${BEFORE}...HEAD" -- "*.kicad_pcb" 2>/dev/null || true)
    fi
    if [ ${#BOARD_FILES[@]} -eq 0 ]; then
        while IFS= read -r f; do
            if [ -n "$f" ] && [ -f "$f" ]; then
                BOARD_FILES+=("$f")
            fi
        done < <(find . -name "*.kicad_pcb" -not -path "*/.*" -not -path "*/node_modules/*" 2>/dev/null | sed 's|^\./||' | head -n 1)
    fi
fi

# 4. If no board files found, skip gracefully
if [ ${#BOARD_FILES[@]} -eq 0 ]; then
    echo "No .kicad_pcb files detected or changed. Skipping BoardDiff DRC."
    set_output "status" "skipped"
    set_output "run-id" ""
    set_output "url" ""
    set_output "errors" "0"
    set_output "warnings" "0"
    set_output "review-number" ""
    set_output "review-url" ""
    exit 0
fi
echo "Target board file(s): ${BOARD_FILES[*]}"

# 5. Query current revision number before upload
echo "Querying repository ${OWNER}/${REPO}..."
api_request "GET" "/api/v1/repos/${OWNER}/${REPO}" -H "Accept: application/json"
if [ "$API_HTTP_CODE" != "200" ]; then
    err_msg=$(echo "$API_BODY" | python3 -c "import sys, json
try:
    d = json.loads(sys.stdin.read() or '{}')
    print(d.get('error') or d.get('message') or '')
except Exception:
    print('')
")
    echo "::error::Failed to query repository ${OWNER}/${REPO} (HTTP ${API_HTTP_CODE}): ${err_msg:-Repository not found or inaccessible}" >&2
    exit 1
fi

PREV_REVISION=$(echo "$API_BODY" | python3 -c "import sys, json
try:
    data = json.loads(sys.stdin.read() or '{}')
    rev = data.get('latestRevision')
    if isinstance(rev, dict) and rev.get('number') is not None:
        print(rev['number'])
    else:
        print('')
except Exception:
    print('')
")

if [ -n "$PREV_REVISION" ]; then
    echo "Current revision number: ${PREV_REVISION}"
else
    echo "No previous revisions found (initial upload)."
fi

# 6. Upload board file(s)
for board_file in "${BOARD_FILES[@]}"; do
    echo "Uploading ${board_file} to ${OWNER}/${REPO}..."
    upload_resp=$(curl -s -S -w "\n%{http_code}" -X POST \
        -H "Authorization: Bearer ${TOKEN}" \
        -F "file=@${board_file}" \
        "${URL}/api/v1/repos/${OWNER}/${REPO}/files" 2>&1)
    upload_exit=$?
    if [ $upload_exit -ne 0 ]; then
        echo "::error::curl upload failed for ${board_file}: ${upload_resp}" >&2
        exit 1
    fi
    upload_code=$(echo "$upload_resp" | tail -n1)
    upload_body=$(echo "$upload_resp" | sed '$d')
    if [ "$upload_code" != "201" ]; then
        err_msg=$(echo "$upload_body" | python3 -c "import sys, json
try:
    d = json.loads(sys.stdin.read() or '{}')
    print(d.get('error') or d.get('message') or '')
except Exception:
    print('')
")
        echo "::error::Failed to upload ${board_file} (HTTP ${upload_code}): ${err_msg:-Upload failed}" >&2
        exit 1
    fi
    echo "Uploaded ${board_file} successfully."
done

# 7. Poll for parse completion (revision number advances)
echo "Waiting for board parsing to complete (timeout: ${TIMEOUT}s)..."
START_PARSE=$(date +%s)
NEW_REVISION=""

while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_PARSE))
    if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
        echo "::error::Timed out after ${TIMEOUT}s waiting for board parsing to finish." >&2
        exit 1
    fi

    sleep "$POLL_INTERVAL"

    api_request "GET" "/api/v1/repos/${OWNER}/${REPO}" -H "Accept: application/json"
    if [ "$API_HTTP_CODE" = "200" ]; then
        CURR_REV=$(echo "$API_BODY" | python3 -c "import sys, json
try:
    data = json.loads(sys.stdin.read() or '{}')
    rev = data.get('latestRevision')
    if isinstance(rev, dict) and rev.get('number') is not None:
        print(rev['number'])
    else:
        print('')
except Exception:
    print('')
")
        if [ -z "$PREV_REVISION" ]; then
            if [ -n "$CURR_REV" ]; then
                NEW_REVISION="$CURR_REV"
                break
            fi
        else
            if [ -n "$CURR_REV" ] && [ "$CURR_REV" -gt "$PREV_REVISION" ]; then
                NEW_REVISION="$CURR_REV"
                break
            fi
        fi
    fi
done

echo "Board parse completed (revision #${NEW_REVISION})."

# 8. Upsert CI Design Review (head rN vs base rN-1)
BRANCH="${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-main}}"
BRANCH="${BRANCH:0:60}"

HEAD_REV="$NEW_REVISION"
BASE_REV=""
if [ -n "$HEAD_REV" ] && [ "$HEAD_REV" -gt 1 ]; then
    BASE_REV=$((HEAD_REV - 1))
fi

echo "Upserting CI design review (r${BASE_REV:-none} → r${HEAD_REV})..."

REVIEW_PAYLOAD=$(python3 -c "import json, sys
branch, head_str, base_str = sys.argv[1], sys.argv[2], sys.argv[3]
head_rev = int(head_str)
base_rev = int(base_str) if base_str.isdigit() else None
payload = {
    'sourceBranch': branch,
    'headRevisionNumber': head_rev,
    'baseRevisionNumber': base_rev,
    'title': f'CI · {branch} · r{head_rev}'
}
print(json.dumps(payload))
" "$BRANCH" "$HEAD_REV" "$BASE_REV")

api_request "POST" "/api/v1/repos/${OWNER}/${REPO}/design-reviews" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "$REVIEW_PAYLOAD"

if [ "$API_HTTP_CODE" != "200" ] && [ "$API_HTTP_CODE" != "201" ]; then
    err_msg=$(echo "$API_BODY" | python3 -c "import sys, json
try:
    d = json.loads(sys.stdin.read() or '{}')
    print(d.get('error') or d.get('message') or '')
except Exception:
    print('')
")
    echo "::error::Failed to upsert CI design review (HTTP ${API_HTTP_CODE}): ${err_msg:-Upsert failed}" >&2
    exit 1
fi

REVIEW_INFO=$(echo "$API_BODY" | python3 -c "import sys, json
try:
    d = json.loads(sys.stdin.read() or '{}')
    print(f\"{d.get('number', '')}\t{d.get('url', '')}\")
except Exception:
    print('\t')
")

REVIEW_NUMBER=$(echo "$REVIEW_INFO" | cut -f1)
REVIEW_REL_URL=$(echo "$REVIEW_INFO" | cut -f2)
REVIEW_URL="${URL}${REVIEW_REL_URL}"
echo "CI design review ready: #${REVIEW_NUMBER} (${REVIEW_URL})"

# 9. Trigger DRC run
echo "Triggering DRC run on branch '${BRANCH}'..."
DRC_PAYLOAD=$(python3 -c "import json, sys; print(json.dumps({'branch': sys.argv[1]}))" "$BRANCH")

api_request "POST" "/api/v1/repos/${OWNER}/${REPO}/drc-runs" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "$DRC_PAYLOAD"

if [ "$API_HTTP_CODE" != "201" ]; then
    err_msg=$(echo "$API_BODY" | python3 -c "import sys, json
try:
    d = json.loads(sys.stdin.read() or '{}')
    print(d.get('error') or d.get('message') or '')
except Exception:
    print('')
")
    echo "::error::Failed to trigger DRC run (HTTP ${API_HTTP_CODE}): ${err_msg:-Trigger failed}" >&2
    exit 1
fi

DRC_RUN_ID=$(echo "$API_BODY" | python3 -c "import sys, json
try:
    data = json.loads(sys.stdin.read() or '{}')
    print(data.get('id') or '')
except Exception:
    print('')
")

if [ -z "$DRC_RUN_ID" ]; then
    echo "::error::DRC run ID missing from response." >&2
    exit 1
fi

echo "DRC run queued (ID: ${DRC_RUN_ID})."

# 10. Poll for DRC completion
echo "Waiting for DRC run to complete (timeout: ${TIMEOUT}s)..."
START_DRC=$(date +%s)
DRC_STATUS=""
ERRORS_COUNT=0
WARNINGS_COUNT=0

while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_DRC))
    if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
        echo "::error::Timed out after ${TIMEOUT}s waiting for DRC run ${DRC_RUN_ID} to complete." >&2
        exit 1
    fi

    sleep "$POLL_INTERVAL"

    api_request "GET" "/api/v1/repos/${OWNER}/${REPO}/drc-runs/${DRC_RUN_ID}" -H "Accept: application/json"
    if [ "$API_HTTP_CODE" != "200" ]; then
        echo "Warning: failed to query DRC run status (HTTP ${API_HTTP_CODE}), retrying..." >&2
        continue
    fi

    DRC_INFO=$(echo "$API_BODY" | python3 -c "import sys, json
try:
    d = json.loads(sys.stdin.read() or '{}')
    status = str(d.get('status') or '').strip().lower()
    errors = int(d.get('errorsCount') or 0)
    warnings = int(d.get('warningsCount') or 0)
    print(f'{status}\t{errors}\t{warnings}')
except Exception:
    print('\t0\t0')
")

    DRC_STATUS=$(echo "$DRC_INFO" | cut -f1)
    ERRORS_COUNT=$(echo "$DRC_INFO" | cut -f2)
    WARNINGS_COUNT=$(echo "$DRC_INFO" | cut -f3)

    case "$DRC_STATUS" in
        passed|warning|failed)
            echo "DRC run finished with status: ${DRC_STATUS} (errors: ${ERRORS_COUNT}, warnings: ${WARNINGS_COUNT})"
            break
            ;;
        queued|running)
            echo "DRC run in progress (status: ${DRC_STATUS}, elapsed: ${ELAPSED}s)..."
            ;;
        *)
            echo "::error::Unexpected DRC run status '${DRC_STATUS}'." >&2
            exit 1
            ;;
    esac
done

# 11. Run link
RUN_URL="${URL}/${OWNER}/${REPO}/ci-drc/${DRC_RUN_ID}"
echo "BoardDiff DRC Report: ${RUN_URL}"

# 12. Sticky PR comment
PR_NUMBER=""
if [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "${GITHUB_EVENT_PATH:-}" ]; then
    PR_NUMBER=$(python3 -c "import json
try:
    with open('${GITHUB_EVENT_PATH}', 'r', encoding='utf-8') as f:
        ev = json.load(f)
        pr = ev.get('pull_request', {}).get('number') or ev.get('issue', {}).get('number')
        print(pr or '')
except Exception:
    print('')
" 2>/dev/null || true)
fi

if [ -n "$PR_NUMBER" ] && [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
    GH_API="${GITHUB_API_URL:-https://api.github.com}"
    GH_API="${GH_API%/}"
    echo "Checking for existing sticky comment on PR #${PR_NUMBER}..."
    COMMENTS_URL="${GH_API}/repos/${GITHUB_REPOSITORY}/issues/${PR_NUMBER}/comments"
    COMMENTS_RESP=$(curl -s -S \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "${COMMENTS_URL}?per_page=100" 2>/dev/null || true)

    COMMENT_ID=$(echo "$COMMENTS_RESP" | python3 -c "import sys, json
marker = '<!-- boarddiff-drc -->'
try:
    comments = json.loads(sys.stdin.read() or '[]')
    if isinstance(comments, list):
        for c in comments:
            if isinstance(c, dict) and marker in (c.get('body') or ''):
                print(c.get('id') or '')
                sys.exit(0)
except Exception:
    pass
print('')
" 2>/dev/null || true)

    COMMENT_PAYLOAD=$(python3 -c "import json, sys
status = sys.argv[1].upper()
errors = sys.argv[2]
warnings = sys.argv[3]
url = sys.argv[4]
review_url = sys.argv[5]
review_num = sys.argv[6]
head_rev = sys.argv[7]
base_rev = sys.argv[8]

if status == 'PASSED':
    status_badge = '✅ **Passed**'
elif status == 'WARNING':
    status_badge = '⚠️ **Warning**'
elif status == 'FAILED':
    status_badge = '❌ **Failed**'
else:
    status_badge = f'**{status}**'

if base_rev:
    diff_label = f'Review #{review_num} (r{base_rev} → r{head_rev})'
else:
    diff_label = f'Review #{review_num} (initial revision r{head_rev})'

diff_link = f'[{diff_label}]({review_url})' if review_url else f'Review #{review_num}'

body = f'''<!-- boarddiff-drc -->
### 🔬 BoardDiff DRC Result: {status_badge}

| Check | Result |
|---|---|
| **Board Diff** | {diff_link} |
| **Status** | \`{status}\` |
| **Errors** | \`{errors}\` |
| **Warnings** | \`{warnings}\` |
| **DRC Report** | [View DRC Run on BoardDiff]({url}) |

> *Yalnızca push edilen \`.kicad_pcb\`; git mirror değil.*
'''
print(json.dumps({'body': body}))
" "$DRC_STATUS" "$ERRORS_COUNT" "$WARNINGS_COUNT" "$RUN_URL" "$REVIEW_URL" "$REVIEW_NUMBER" "$HEAD_REV" "$BASE_REV")

    if [ -n "$COMMENT_ID" ]; then
        echo "Updating sticky comment #${COMMENT_ID} on PR #${PR_NUMBER}..."
        curl -s -S -X PATCH \
            -H "Authorization: Bearer ${GITHUB_TOKEN}" \
            -H "Accept: application/vnd.github+json" \
            -H "Content-Type: application/json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            -d "$COMMENT_PAYLOAD" \
            "${GH_API}/repos/${GITHUB_REPOSITORY}/issues/comments/${COMMENT_ID}" >/dev/null 2>&1 || {
            echo "::warning::Failed to update PR comment." >&2
        }
    else
        echo "Posting sticky comment on PR #${PR_NUMBER}..."
        curl -s -S -X POST \
            -H "Authorization: Bearer ${GITHUB_TOKEN}" \
            -H "Accept: application/vnd.github+json" \
            -H "Content-Type: application/json" \
            -H "X-GitHub-Api-Version: 2022-11-28" \
            -d "$COMMENT_PAYLOAD" \
            "$COMMENTS_URL" >/dev/null 2>&1 || {
            echo "::warning::Failed to post PR comment." >&2
        }
    fi
fi

# 13. Optional GitHub Check Run
if [ -n "${GITHUB_SHA:-}" ] && [ -n "${GITHUB_REPOSITORY:-}" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
    echo "Reporting GitHub Check Run for commit ${GITHUB_SHA:0:7}..."
    GH_API="${GITHUB_API_URL:-https://api.github.com}"
    GH_API="${GH_API%/}"

    CHECK_CONCLUSION="neutral"
    if [ "$DRC_STATUS" = "passed" ]; then
        CHECK_CONCLUSION="success"
    elif [ "$DRC_STATUS" = "failed" ]; then
        CHECK_CONCLUSION="failure"
    elif [ "$DRC_STATUS" = "warning" ]; then
        CHECK_CONCLUSION="neutral"
    fi

    CHECK_PAYLOAD=$(python3 -c "import json, sys
sha = sys.argv[1]
conclusion = sys.argv[2]
review_url = sys.argv[3]
run_url = sys.argv[4]
status = sys.argv[5].upper()
errors = sys.argv[6]
warnings = sys.argv[7]
rev_num = sys.argv[8]

payload = {
    'name': 'BoardDiff DRC',
    'head_sha': sha,
    'status': 'completed',
    'conclusion': conclusion,
    'details_url': review_url or run_url,
    'output': {
        'title': f'BoardDiff DRC: {status}',
        'summary': f'Status: {status} | Errors: {errors} | Warnings: {warnings}\n\n[Review #{rev_num}]({review_url})\n[DRC Report]({run_url})'
    }
}
print(json.dumps(payload))
" "$GITHUB_SHA" "$CHECK_CONCLUSION" "$REVIEW_URL" "$RUN_URL" "$DRC_STATUS" "$ERRORS_COUNT" "$WARNINGS_COUNT" "$REVIEW_NUMBER")

    curl -s -S -X POST \
        -H "Authorization: Bearer ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        -H "Content-Type: application/json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -d "$CHECK_PAYLOAD" \
        "${GH_API}/repos/${GITHUB_REPOSITORY}/check-runs" >/dev/null 2>&1 || {
        echo "::warning::Could not create GitHub Check Run (requires 'checks: write' permission)." >&2
    }
fi

# 14. Set GitHub Action outputs
set_output "status" "$DRC_STATUS"
set_output "run-id" "$DRC_RUN_ID"
set_output "url" "$RUN_URL"
set_output "errors" "$ERRORS_COUNT"
set_output "warnings" "$WARNINGS_COUNT"
set_output "review-number" "$REVIEW_NUMBER"
set_output "review-url" "$REVIEW_URL"

# 15. Determine exit code
case "$FAIL_ON" in
    never)
        exit 0
        ;;
    warnings)
        if [ "$DRC_STATUS" = "failed" ] || [ "$DRC_STATUS" = "warning" ]; then
            echo "::error::BoardDiff DRC finished with status '${DRC_STATUS}' (fail-on: warnings)." >&2
            exit 1
        fi
        exit 0
        ;;
    errors|*)
        if [ "$DRC_STATUS" = "failed" ]; then
            echo "::error::BoardDiff DRC failed with ${ERRORS_COUNT} error(s)." >&2
            exit 1
        fi
        exit 0
        ;;
esac
