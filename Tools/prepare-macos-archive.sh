#!/bin/bash

# Keep the app's Xcode-generated entitlements while allowing Mac App Store
# export to seal SwiftPM's codeless bundles as resources, not nested code.
set -euo pipefail

readonly CODESIGN_BIN="${CODESIGN_BIN:-/usr/bin/codesign}"

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

(($# == 1)) || die "usage: prepare-macos-archive.sh PATH.xcarchive"
readonly ARCHIVE_PATH="$1"
readonly APP_PATH="${ARCHIVE_PATH}/Products/Applications/JollysMQTT.app"
[[ -d "${APP_PATH}/Contents" ]] || die "macOS app not found: ${APP_PATH}"

readonly TEMP_DIRECTORY="$(mktemp -d "${TMPDIR:-/tmp}/jollysmqtt-archive-signing.XXXXXX")"
trap 'rm -rf -- "${TEMP_DIRECTORY}"' EXIT

extract_entitlements() {
    local destination="$1"
    "${CODESIGN_BIN}" --display --entitlements - --xml "${APP_PATH}" >"${destination}"
    plutil -lint "${destination}" >/dev/null || die "macOS app has no valid signed entitlements"
    local entitlement
    for entitlement in com.apple.security.app-sandbox com.apple.security.network.client; do
        [[ "$(/usr/libexec/PlistBuddy -c "Print :${entitlement}" "${destination}" 2>/dev/null)" == true ]] ||
            die "macOS app must have ${entitlement}=true before export"
    done
    # Canonicalize the dictionary order for an exact before/after comparison.
    plutil -convert xml1 "${destination}"
}

# Validate the signed app and every resource bundle before changing anything.
"${CODESIGN_BIN}" --verify --strict "${APP_PATH}"
extract_entitlements "${TEMP_DIRECTORY}/before.plist"
"${CODESIGN_BIN}" --display --extract-certificates="${TEMP_DIRECTORY}/certificate-" "${APP_PATH}"
[[ -s "${TEMP_DIRECTORY}/certificate-0" ]] || die "macOS archive needs a certificate-signed app"
readonly SIGNING_IDENTITY="$(shasum -a 1 "${TEMP_DIRECTORY}/certificate-0" | awk '{print $1}')"

resource_bundles=()
while IFS= read -r -d '' resource_bundle; do
    resource_bundles+=("${resource_bundle}")
    info_plist="${resource_bundle}/Contents/Info.plist"
    [[ -f "${info_plist}" ]] || die "resource bundle is missing Contents/Info.plist: ${resource_bundle}"
    if plutil -extract CFBundleExecutable raw -o - "${info_plist}" >/dev/null 2>&1; then
        die "resource bundle contains an executable and needs distribution signing: ${resource_bundle}"
    fi
    while IFS= read -r -d '' entry; do
        case "${entry}" in
            "${resource_bundle}/Contents/_CodeSignature") ;;
            */_CodeSignature|*/MacOS|*/Frameworks|*/PlugIns|*/XPCServices|*/Helpers)
                die "resource bundle contains nested code and needs distribution signing: ${entry}"
                ;;
        esac
        if [[ -f "${entry}" ]] && /usr/bin/file -b "${entry}" | /usr/bin/grep -Eq 'Mach-O|ELF|PE32'; then
            die "resource bundle contains executable code and needs distribution signing: ${entry}"
        fi
    done < <(find "${resource_bundle}" -mindepth 1 -print0)
done < <(find "${APP_PATH}/Contents/Resources" -maxdepth 1 -type d -name '*.bundle' -print0)

for resource_bundle in "${resource_bundles[@]}"; do
    if [[ -d "${resource_bundle}/Contents/_CodeSignature" ]]; then
        "${CODESIGN_BIN}" --remove-signature "${resource_bundle}"
        # codesign removes the signature files but leaves an empty directory.
        if [[ -d "${resource_bundle}/Contents/_CodeSignature" ]]; then
            rmdir "${resource_bundle}/Contents/_CodeSignature"
        fi
    fi
done

# Re-seal only the containing app with its original certificate and metadata.
# Never use --deep: executable frameworks keep their own signatures.
"${CODESIGN_BIN}" --force --sign "${SIGNING_IDENTITY}" \
    --preserve-metadata=identifier,entitlements,requirements,flags,runtime \
    "${APP_PATH}"
"${CODESIGN_BIN}" --verify --strict "${APP_PATH}"
extract_entitlements "${TEMP_DIRECTORY}/after.plist"
cmp -s "${TEMP_DIRECTORY}/before.plist" "${TEMP_DIRECTORY}/after.plist" ||
    die "macOS app entitlements changed while preparing the archive; nothing may be uploaded"

for resource_bundle in "${resource_bundles[@]}"; do
    [[ ! -e "${resource_bundle}/Contents/_CodeSignature" ]] ||
        die "resource bundle still has a nested code signature: ${resource_bundle}"
done

printf 'Verified macOS app signature and preserved all entitlements, including App Sandbox.\n'
printf 'Verified %d codeless macOS resource bundle(s) have no nested signatures in %s\n' \
    "${#resource_bundles[@]}" "${ARCHIVE_PATH}"
