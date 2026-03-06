#!/usr/bin/env bash
#
# sync-to-repo.sh — Sync Makefile standardization files to a target GitHub repo
#
# Copies makefiles/common.mk (and optionally a generated Makefile) to
# a target repo. Updates Dockerfile FROM line.
# Creates a PR if changes are needed. Fails if a stale PR already exists.
#
# Usage:
#   ./tools/scripts/sync-to-repo.sh \
#     --repo ORG/REPO \
#     --branch main \
#     --sdk-version v1.36.1 \
#     --source-dir /path/to/source \
#     [--dry-run]
#
# Environment:
#   CROSS_REPO_PAT  — GitHub PAT with repo access (required unless --dry-run)
#

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────
REPO=""
DEFAULT_BRANCH=""
SDK_VERSION=""
SOURCE_DIR=""
MAKEFILE_PATH=""
CHANGELOG_PATH=""
DRY_RUN="false"
SYNC_BRANCH="automation/makefile-sync"

# ── Parse args ────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
    case $1 in
        --repo)          REPO="$2";           shift 2 ;;
        --branch)        DEFAULT_BRANCH="$2"; shift 2 ;;
        --sdk-version)   SDK_VERSION="$2";    shift 2 ;;
        --source-dir)    SOURCE_DIR="$2";     shift 2 ;;
        --makefile)      MAKEFILE_PATH="$2";  shift 2 ;;
        --changelog)     CHANGELOG_PATH="$2"; shift 2 ;;
        --sync-branch)   SYNC_BRANCH="$2";    shift 2 ;;
        --dry-run)       DRY_RUN="true";      shift ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# ── Validate ──────────────────────────────────────────────────
for var in REPO DEFAULT_BRANCH SOURCE_DIR; do
    if [ -z "${!var}" ]; then
        echo "ERROR: --$(echo $var | tr '[:upper:]' '[:lower:]' | tr '_' '-') is required"
        exit 1
    fi
done

if [ "${DRY_RUN}" != "true" ] && [ -z "${CROSS_REPO_PAT:-}" ]; then
    echo "ERROR: CROSS_REPO_PAT environment variable is required"
    exit 1
fi

ORG="${REPO%%/*}"

echo ""
echo "============================================"
echo " Syncing ${REPO}"
echo " Branch: ${DEFAULT_BRANCH}"
[ -n "${SDK_VERSION}" ] && echo " SDK: ${SDK_VERSION}"
echo " Dry run: ${DRY_RUN}"
echo "============================================"

# ── Clone target repo ─────────────────────────────────────────
WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

# Configure credential helper scoped to github.com
if [ -n "${CROSS_REPO_PAT:-}" ]; then
    git config --global credential.https://github.com.helper \
        '!f() { echo "username=x-access-token"; echo "password='"${CROSS_REPO_PAT}"'"; }; f'
fi

echo "Cloning ${REPO}..."
git clone --depth 1 --branch "${DEFAULT_BRANCH}" \
    "https://github.com/${REPO}.git" "${WORK_DIR}"

# ── Copy synced files ─────────────────────────────────────────
mkdir -p "${WORK_DIR}/makefiles/"
cp "${SOURCE_DIR}/makefiles/common.mk" "${WORK_DIR}/makefiles/common.mk"
echo "Copied makefiles/common.mk"

# Copy generated Makefile if provided
if [ -n "${MAKEFILE_PATH}" ] && [ -f "${MAKEFILE_PATH}" ]; then
    cp "${MAKEFILE_PATH}" "${WORK_DIR}/Makefile"
    echo "Copied generated Makefile from ${MAKEFILE_PATH}"
fi

# Update Dockerfile FROM line (only when SDK version is explicitly provided)
if [ -n "${SDK_VERSION}" ] && [ -f "${WORK_DIR}/Dockerfile" ]; then
    sed -i "s|^FROM quay.io/operator-framework/ansible-operator:.*|FROM quay.io/operator-framework/ansible-operator:${SDK_VERSION}|" \
        "${WORK_DIR}/Dockerfile"
fi

# ── Check if changes are needed ───────────────────────────────
cd "${WORK_DIR}"

# No changes at all vs default branch?
if git diff --quiet && [ -z "$(git ls-files --others --exclude-standard)" ]; then
    echo "No changes needed for ${REPO} — already up to date"
    exit 0
fi

# ── Dry run ───────────────────────────────────────────────────
if [ "${DRY_RUN}" = "true" ]; then
    echo ""
    echo "=== Dry run: changes for ${REPO} ==="
    git diff --stat
    git diff
    echo ""
    git ls-files --others --exclude-standard | while read -r f; do
        echo "New file: ${f}"
    done
    exit 0
fi

# Sync branch already exists?
if git ls-remote --exit-code origin "${SYNC_BRANCH}" >/dev/null 2>&1; then
    echo "Sync branch '${SYNC_BRANCH}' exists, comparing content..."
    git fetch origin "${SYNC_BRANCH}" --depth=1

    # Compare intended tree vs existing sync branch tree
    git add -A
    INTENDED=$(git write-tree)
    EXISTING=$(git rev-parse "FETCH_HEAD^{tree}")

    if [ "${INTENDED}" = "${EXISTING}" ]; then
        echo "Sync branch already has identical content — skipping"
        exit 0
    fi

    echo "ERROR: Sync branch '${SYNC_BRANCH}' exists with different content."
    echo "Merge or close the existing PR in ${REPO} before re-syncing."
    exit 1
fi

# ── Commit and push ──────────────────────────────────────────
git config user.name "AAP Makefile Sync"
git config user.email "aap-makefile-sync[bot]@users.noreply.github.com"
git checkout -b "${SYNC_BRANCH}"

git add makefiles/common.mk
{ git diff --quiet Makefile 2>/dev/null || git add Makefile; }
[ -f Dockerfile ] && { git diff --quiet Dockerfile 2>/dev/null || git add Dockerfile; }

# Build list of actually changed files for the commit message
CHANGED=$(git diff --cached --name-only)
FILE_LINES=""
echo "${CHANGED}" | grep -q '^Makefile$'             && FILE_LINES="${FILE_LINES}  - Makefile (standardized${SDK_VERSION:+, SDK ${SDK_VERSION}})
"
echo "${CHANGED}" | grep -q '^makefiles/common.mk$' && FILE_LINES="${FILE_LINES}  - makefiles/common.mk (shared dev targets)
"
echo "${CHANGED}" | grep -q '^Dockerfile$'           && FILE_LINES="${FILE_LINES}  - Dockerfile (FROM → SDK ${SDK_VERSION})
"

SDK_LINE=""
[ -n "${SDK_VERSION}" ] && SDK_LINE="SDK version: ${SDK_VERSION}"

git commit -m "chore: sync Makefile standardization from gateway-operator

Synced files:
${FILE_LINES}
${SDK_LINE}
Source: aap-gateway-operator (Proposal 0100)

Authored-By: AAP Makefile Sync <aap-makefile-sync[bot]@users.noreply.github.com>"

echo "Pushing branch '${SYNC_BRANCH}'..."
git push origin "${SYNC_BRANCH}"

# ── Create PR ─────────────────────────────────────────────────
# Build PR body with only the files that actually changed
PR_FILES=""
echo "${CHANGED}" | grep -q '^Makefile$'             && PR_FILES="${PR_FILES}- \`Makefile\` — standardized Makefile${SDK_VERSION:+ (SDK ${SDK_VERSION})}
"
echo "${CHANGED}" | grep -q '^makefiles/common.mk$' && PR_FILES="${PR_FILES}- \`makefiles/common.mk\` — shared dev workflow targets
"
echo "${CHANGED}" | grep -q '^Dockerfile$'           && PR_FILES="${PR_FILES}- \`Dockerfile\` — FROM line updated to SDK ${SDK_VERSION}
"

CHANGELOG_SECTION=""
if [ -n "${CHANGELOG_PATH}" ] && [ -f "${CHANGELOG_PATH}" ]; then
    CHANGELOG_SECTION="
$(cat "${CHANGELOG_PATH}")
"
fi

PR_BODY="## Summary

Automated sync of Makefile standardization files from \`aap-gateway-operator\` (Proposal 0100).

### Files synced
${PR_FILES}
${CHANGELOG_SECTION}
### What to do
1. Review the synced files
2. Ensure your operator-specific config is in \`makefiles/operator.mk\` (not synced, operator-owned)
3. Test: \`make help\` should show targets from all three files
4. Merge when ready

---
*Automated by Cross-Repo Makefile Sync*"

echo "Creating PR..."
curl -sS --fail-with-body \
    -H "Authorization: token ${CROSS_REPO_PAT}" \
    -H "Accept: application/vnd.github.v3+json" \
    -X POST \
    "https://api.github.com/repos/${REPO}/pulls" \
    -d "$(jq -n \
        --arg title "chore: sync Makefile standardization (Proposal 0100)" \
        --arg head "${SYNC_BRANCH}" \
        --arg base "${DEFAULT_BRANCH}" \
        --arg body "${PR_BODY}" \
        '{title: $title, head: $head, base: $base, body: $body}')" \
    | jq '{number: .number, html_url: .html_url}'

echo "Done — PR created in ${REPO}"
