#!/usr/bin/env bash
#
# generate-makefile.sh - Generate standardized Makefile from operator-sdk
#
# Downloads the specified operator-sdk version, scaffolds a temp project
# to extract the SDK-generated Makefile, then applies standardization
# patches (ENGINE variable, ARCH detection, include lines).
#
# Usage:
#   ./tools/scripts/generate-makefile.sh [--sdk-version VERSION] [--output PATH] [--dry-run]
#
# Environment Variables:
#   OPERATOR_SDK_VERSION  - operator-sdk version to use (default: v1.36.1)
#   OUTPUT_MAKEFILE       - path to write the generated Makefile (default: Makefile)
#   DRY_RUN               - if "true", print diff instead of writing (default: false)
#
# This script is CI-platform agnostic and can be called from:
#   - GitLab CI (.gitlab-ci.yml)
#   - GitHub Actions (.github/workflows/*.yml)
#   - Local development (./tools/scripts/generate-makefile.sh)
#

set -euo pipefail

# --- Configuration ---
OPERATOR_SDK_VERSION="${OPERATOR_SDK_VERSION:-}"
OUTPUT_MAKEFILE="${OUTPUT_MAKEFILE:-Makefile}"
DRY_RUN="${DRY_RUN:-false}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# --- Parse arguments ---
while [[ $# -gt 0 ]]; do
    case $1 in
        --sdk-version)
            OPERATOR_SDK_VERSION="$2"
            shift 2
            ;;
        --output)
            OUTPUT_MAKEFILE="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN="true"
            shift
            ;;
        --help|-h)
            head -17 "$0" | tail -13
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# --- Detect host platform ---
detect_platform() {
    local os arch
    os="$(uname -s | tr '[:upper:]' '[:lower:]')"
    arch="$(uname -m)"
    case "$arch" in
        x86_64)  arch="amd64" ;;
        aarch64) arch="arm64" ;;
        # arm64 stays arm64 — no force to amd64!
    esac
    echo "${os}_${arch}"
}

PLATFORM="$(detect_platform)"

if [[ -z "${OPERATOR_SDK_VERSION}" ]]; then
    echo "ERROR: --sdk-version is required"
    exit 1
fi

echo "==> Platform: ${PLATFORM}"
echo "==> SDK Version: ${OPERATOR_SDK_VERSION}"

# --- Create temp workspace ---
TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

echo "==> Working in temp directory: ${TMPDIR}"

# --- Download operator-sdk ---
download_operator_sdk() {
    local sdk_binary="${TMPDIR}/operator-sdk"
    local base_url="https://github.com/operator-framework/operator-sdk/releases/download/${OPERATOR_SDK_VERSION}"
    local download_url="${base_url}/operator-sdk_${PLATFORM}"
    local checksums_url="${base_url}/checksums.txt"

    echo "==> Downloading operator-sdk ${OPERATOR_SDK_VERSION}..."
    if ! curl -sSLo "${sdk_binary}" "${download_url}"; then
        echo "ERROR: Failed to download operator-sdk from ${download_url}"
        exit 1
    fi

    # Verify checksum
    echo "==> Verifying checksum..."
    if curl -sSLo "${TMPDIR}/checksums.txt" "${checksums_url}"; then
        local expected_sum
        expected_sum=$(grep "operator-sdk_${PLATFORM}$" "${TMPDIR}/checksums.txt" | awk '{print $1}')
        if [ -n "${expected_sum}" ]; then
            local actual_sum
            actual_sum=$(sha256sum "${sdk_binary}" 2>/dev/null || shasum -a 256 "${sdk_binary}" | awk '{print $1}')
            actual_sum=$(echo "${actual_sum}" | awk '{print $1}')
            if [ "${actual_sum}" != "${expected_sum}" ]; then
                echo "ERROR: Checksum mismatch!"
                echo "  Expected: ${expected_sum}"
                echo "  Actual:   ${actual_sum}"
                exit 1
            fi
            echo "==> Checksum verified"
        else
            echo "WARNING: Could not find checksum for operator-sdk_${PLATFORM} in checksums.txt"
        fi
    else
        echo "WARNING: Could not download checksums.txt — skipping verification"
    fi

    chmod +x "${sdk_binary}"
    echo "==> Downloaded operator-sdk to ${sdk_binary}"
}

# --- Scaffold temp project and extract Makefile ---
generate_sdk_makefile() {
    local scaffold_dir="${TMPDIR}/scaffold"
    mkdir -p "${scaffold_dir}"

    echo "==> Scaffolding temp ansible operator project..."
    cd "${scaffold_dir}"
    "${TMPDIR}/operator-sdk" init \
        --plugins ansible \
        --domain example.com \
        --project-name temp-operator \
        || echo "WARNING: operator-sdk init returned non-zero (may still have generated files)"

    echo "==> Scaffold directory contents:"
    ls -la "${scaffold_dir}/"

    if [[ ! -f "${scaffold_dir}/Makefile" ]]; then
        echo "ERROR: operator-sdk init did not generate a Makefile"
        exit 1
    fi

    echo "==> SDK Makefile generated ($(wc -l < "${scaffold_dir}/Makefile") lines)"
    cp "${scaffold_dir}/Makefile" "${TMPDIR}/Makefile.sdk"
    cd "${REPO_ROOT}"
}

# --- Apply standardization patches ---
patch_makefile() {
    local makefile="${TMPDIR}/Makefile.sdk"
    local patched="${TMPDIR}/Makefile.patched"

    echo "==> Applying standardization patches..."

    # Read the SDK Makefile and apply patches
    cp "${makefile}" "${patched}"

    # 1. Comment out VERSION — each operator sets this in operator.mk
    awk '{
        if ($0 ~ /^VERSION \?=/) {
            print "# " $0 " # Set in operator.mk"
        } else {
            print
        }
    }' "${patched}" > "${patched}.tmp" && mv "${patched}.tmp" "${patched}"
    echo "    - Commented out VERSION (owned by operator.mk)"

    # 2. Fix ARCH detection — ensure correct mapping without arm64->amd64 force
    awk '{
        # Fix the bugged ARCH line that forces arm64 to amd64
        if ($0 ~ /sed.*x86_64.*amd64.*aarch64.*arm64.*arm64.*amd64/) {
            gsub(/\| sed .s\/arm64\/amd64\/.*$/, "")
            # Trim trailing whitespace and closing paren
            gsub(/[[:space:]]+\)$/, ")")
        }
        print
    }' "${patched}" > "${patched}.tmp" && mv "${patched}.tmp" "${patched}"
    echo "    - Fixed ARCH detection (no arm64->amd64 force)"

    # 3. Add OPERATOR_SDK_VERSION variable if not present
    if ! grep -q 'OPERATOR_SDK_VERSION' "${patched}"; then
        # Use awk to insert after the (now commented) VERSION line
        awk -v ver="${OPERATOR_SDK_VERSION}" '
            /^# VERSION \?=/ {
                print
                print ""
                print "# Operator SDK version for tool downloads"
                print "OPERATOR_SDK_VERSION ?= " ver
                next
            }
            { print }
        ' "${patched}" > "${patched}.tmp" && mv "${patched}.tmp" "${patched}"
        echo "    - Added OPERATOR_SDK_VERSION variable"
    fi

    # 4. Update hardcoded operator-sdk version references to use the variable
    awk '{
        gsub(/\/releases\/download\/v[0-9.]+\/operator-sdk_/, "/releases/download/$(OPERATOR_SDK_VERSION)/operator-sdk_")
        gsub(/\/releases\/download\/v[0-9.]+\/ansible-operator_/, "/releases/download/$(OPERATOR_SDK_VERSION)/ansible-operator_")
        print
    }' "${patched}" > "${patched}.tmp" && mv "${patched}.tmp" "${patched}"
    echo "    - Updated tool download URLs to use OPERATOR_SDK_VERSION"

    # 5. Fix IMG default — SDK uses 'controller:latest', we need $(IMAGE_TAG_BASE):$(VERSION)
    awk '{
        if ($0 ~ /^IMG \?= controller:latest/) {
            print "IMG ?= $(IMAGE_TAG_BASE):$(VERSION)"
        } else {
            print
        }
    }' "${patched}" > "${patched}.tmp" && mv "${patched}.tmp" "${patched}"
    echo "    - Fixed IMG default to use IMAGE_TAG_BASE:VERSION"

    # 6. Comment out IMAGE_TAG_BASE — each operator sets this in operator.mk
    awk '{
        if ($0 ~ /^IMAGE_TAG_BASE \?=/) {
            print "# IMAGE_TAG_BASE ?= quay.io/<org>/<operator-name>  # Set in operator.mk"
        } else {
            print
        }
    }' "${patched}" > "${patched}.tmp" && mv "${patched}.tmp" "${patched}"
    echo "    - Commented out IMAGE_TAG_BASE (owned by operator.mk)"

    # 7. Append include lines at the end
    cat >> "${patched}" <<'INCLUDES'

##@ Includes
# Operator-specific targets and variables
-include makefiles/operator.mk
# Shared dev workflow targets (synced across all operator repos)
-include makefiles/common.mk
INCLUDES
    echo "    - Appended -include lines for operator.mk and common.mk"

    # Clean up .bak files
    rm -f "${patched}.bak"

    cp "${patched}" "${TMPDIR}/Makefile.final"
    echo "==> Patched Makefile ready ($(wc -l < "${TMPDIR}/Makefile.final") lines)"
}

# --- Update Dockerfile FROM line ---
update_dockerfile() {
    local dockerfile="${REPO_ROOT}/Dockerfile"

    if [[ ! -f "${dockerfile}" ]]; then
        echo "==> No Dockerfile found, skipping FROM update"
        return
    fi

    local current_from
    current_from="$(grep '^FROM ' "${dockerfile}" | head -1)"
    local expected_from="FROM quay.io/operator-framework/ansible-operator:${OPERATOR_SDK_VERSION}"

    if [[ "${current_from}" == "${expected_from}" ]]; then
        echo "==> Dockerfile FROM already matches ${OPERATOR_SDK_VERSION}"
    else
        echo "==> Dockerfile FROM update needed:"
        echo "    Current:  ${current_from}"
        echo "    Expected: ${expected_from}"

        if [[ "${DRY_RUN}" == "true" ]]; then
            echo "    (dry-run: not modifying Dockerfile)"
        else
            awk -v new_from="${expected_from}" '
                /^FROM quay.io\/operator-framework\/ansible-operator:/ { print new_from; next }
                { print }
            ' "${dockerfile}" > "${dockerfile}.tmp" && mv "${dockerfile}.tmp" "${dockerfile}"
            echo "    Updated Dockerfile"
        fi
    fi
}

# --- Output / diff ---
output_result() {
    local final="${TMPDIR}/Makefile.final"
    local target="${REPO_ROOT}/${OUTPUT_MAKEFILE}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        echo ""
        echo "==> DRY RUN: Diff between current and generated Makefile:"
        echo "---"
        diff -u "${target}" "${final}" || true
        echo "---"
        echo "==> DRY RUN complete. No files modified."
    else
        cp "${final}" "${target}"
        echo "==> Wrote generated Makefile to ${target}"
    fi
}

# --- Main ---
main() {
    echo "============================================"
    echo " Operator Makefile Generator"
    echo " SDK Version: ${OPERATOR_SDK_VERSION}"
    echo " Output: ${OUTPUT_MAKEFILE}"
    echo " Dry Run: ${DRY_RUN}"
    echo "============================================"
    echo ""

    download_operator_sdk
    generate_sdk_makefile
    patch_makefile
    update_dockerfile
    output_result

    echo ""
    echo "==> Done."
}

main
