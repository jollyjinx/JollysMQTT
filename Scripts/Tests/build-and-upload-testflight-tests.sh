#!/bin/bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly FIXTURE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/jollysmqtt-testflight-script-test.XXXXXX")"
readonly OUTPUT_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/jollysmqtt-testflight-output-test.XXXXXX")"

cleanup() {
    rm -rf -- "${FIXTURE_ROOT}" "${OUTPUT_ROOT}"
}
trap cleanup EXIT

fail() {
    printf 'test failure: %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    local text="$1"
    local expected="$2"

    [[ "${text}" == *"${expected}"* ]] ||
        fail "expected output to contain: ${expected}"
}

mkdir -p "${FIXTURE_ROOT}/Tools" "${FIXTURE_ROOT}/JollysMQTT.xcodeproj"
cp "${REPOSITORY_ROOT}/Tools/build-and-upload-testflight.sh" \
    "${REPOSITORY_ROOT}/Tools/prepare-macos-archive.sh" \
    "${REPOSITORY_ROOT}/Tools/xcode_git_version.sh" \
    "${FIXTURE_ROOT}/Tools/"
chmod +x "${FIXTURE_ROOT}/Tools/"*.sh

git -C "${FIXTURE_ROOT}" init -q -b main
git -C "${FIXTURE_ROOT}" config user.name "JollysMQTT Tests"
git -C "${FIXTURE_ROOT}" config user.email "tests@invalid.example"
git -C "${FIXTURE_ROOT}" add .
git -C "${FIXTURE_ROOT}" commit -q -m "Test fixture"

readonly RELEASE_SCRIPT="${FIXTURE_ROOT}/Tools/build-and-upload-testflight.sh"
readonly MOCK_XCODEBUILD="${OUTPUT_ROOT}/mock-xcodebuild.sh"
export CODESIGN_BIN="${OUTPUT_ROOT}/mock-codesign.sh"
export MOCK_SIGNING_LOG="${OUTPUT_ROOT}/signing.log"
export MOCK_EXPORT_LOG="${OUTPUT_ROOT}/export.log"

cat >"${CODESIGN_BIN}" <<'MOCK'
#!/bin/bash
set -euo pipefail
printf '%s\n' "$*" >>"${MOCK_SIGNING_LOG}"
app_path="${!#}"
case "$1" in
    --verify) ;;
    --display)
        if [[ "$2" == --entitlements ]]; then
            cat "${app_path}/MockEntitlements.plist"
        elif [[ "$2" == --extract-certificates=* ]]; then
            printf 'fixture signing certificate' >"${2#*=}0"
        else
            exit 1
        fi
        ;;
    --remove-signature)
        rm "${app_path}/Contents/_CodeSignature/CodeResources"
        ;;
    --force)
        [[ "$2" == --sign && "$3" == "$(printf 'fixture signing certificate' | shasum -a 1 | awk '{print $1}')" ]]
        if [[ "${MOCK_LOSE_ENTITLEMENTS:-false}" == true ]]; then
            /usr/libexec/PlistBuddy -c 'Delete :com.apple.developer.icloud-services' "${app_path}/MockEntitlements.plist"
        fi
        ;;
    *) exit 1 ;;
esac
MOCK
chmod +x "${CODESIGN_BIN}"

cat >"${MOCK_XCODEBUILD}" <<'MOCK'
#!/bin/bash
set -euo pipefail

archive_path=""
marketing_version=""
build_version=""
destination=""
show_build_settings=false
export_archive=false
while (($# > 0)); do
    case "$1" in
        -exportArchive)
            export_archive=true
            shift
            ;;
        -showBuildSettings)
            show_build_settings=true
            shift
            ;;
        -archivePath)
            archive_path="$2"
            shift 2
            ;;
        -destination)
            destination="$2"
            shift 2
            ;;
        MARKETING_VERSION=*)
            marketing_version="${1#*=}"
            shift
            ;;
        CURRENT_PROJECT_VERSION=*)
            build_version="${1#*=}"
            shift
            ;;
        *)
            shift
            ;;
    esac
done

if [[ "${export_archive}" == true ]]; then
    printf 'export\n' >>"${MOCK_EXPORT_LOG}"
elif [[ "${show_build_settings}" == true ]]; then
    printf '    MARKETING_VERSION = 0.1.0\n'
elif [[ -n "${archive_path}" ]]; then
    app_directory="${archive_path}/Products/Applications/JollysMQTT.app"
    mkdir -p "${app_directory}"
    cat >"${app_directory}/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>eu.jinx.jollymqtt</string>
<key>CFBundleShortVersionString</key><string>${MOCK_ARCHIVE_MARKETING_VERSION:-${marketing_version}}</string>
<key>CFBundleVersion</key><string>${build_version}</string>
</dict></plist>
PLIST
    if [[ "${destination}" == "generic/platform=macOS" ]]; then
        mkdir -p "${app_directory}/Contents"
        mv "${app_directory}/Info.plist" "${app_directory}/Contents/Info.plist"
        cat >"${app_directory}/MockEntitlements.plist" <<ENTITLEMENTS
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>com.apple.security.app-sandbox</key><${MOCK_SANDBOX_VALUE:-true}/>
<key>com.apple.security.network.client</key><true/>
<key>com.apple.developer.icloud-services</key><array><string>CloudKit</string></array>
<key>com.apple.developer.icloud-container-identifiers</key><array><string>iCloud.eu.jinx.jollymqtt</string></array>
</dict></plist>
ENTITLEMENTS
        if [[ "${MOCK_UNSIGNED_APP:-false}" == true ]]; then
            : >"${app_directory}/MockEntitlements.plist"
        fi
        for bundle_name in \
            JollysMQTTPackage_JollysMQTT.bundle \
            swift-nio-ssl_NIOSSL.bundle \
            swift-nio_NIOPosix.bundle
        do
            bundle_directory="${app_directory}/Contents/Resources/${bundle_name}"
            mkdir -p "${bundle_directory}/Contents"
            cat >"${bundle_directory}/Contents/Info.plist" <<BUNDLE_PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>test.${bundle_name}</string>
<key>CFBundlePackageType</key><string>BNDL</string>
</dict></plist>
BUNDLE_PLIST
            if [[ "${MOCK_SIGN_MACOS_RESOURCE_BUNDLES:-true}" == true ]]; then
                mkdir -p "${bundle_directory}/Contents/_CodeSignature"
                : >"${bundle_directory}/Contents/_CodeSignature/CodeResources"
            fi
            if [[ "${MOCK_EXECUTABLE_BUNDLE:-false}" == true ]]; then
                plutil -insert CFBundleExecutable -string unexpected "${bundle_directory}/Contents/Info.plist"
            fi
            if [[ "${MOCK_NESTED_CODE:-false}" == true ]]; then
                mkdir -p "${bundle_directory}/Contents/Nested.bundle/Contents/_CodeSignature"
            fi
            if [[ "${MOCK_UNDECLARED_EXECUTABLE:-false}" == true ]]; then
                cp /bin/echo "${bundle_directory}/Contents/undeclared"
            fi
        done
    fi
fi
MOCK
chmod +x "${MOCK_XCODEBUILD}"

first_preflight="$(
    TMPDIR="${OUTPUT_ROOT}/" XCODEBUILD_BIN="${MOCK_XCODEBUILD}" \
        "${RELEASE_SCRIPT}" --preflight
)"
assert_contains "${first_preflight}" "version:      0.1.0"
first_output="$(awk -F ': +' '$1 == "  output" { print $2 }' <<<"${first_preflight}")"
[[ -d "${first_output}" ]] || fail "first preflight output directory was not created"

second_preflight="$(
    TMPDIR="${OUTPUT_ROOT}/" XCODEBUILD_BIN="${MOCK_XCODEBUILD}" \
        "${RELEASE_SCRIPT}" --preflight
)"
second_output="$(awk -F ': +' '$1 == "  output" { print $2 }' <<<"${second_preflight}")"
[[ "${second_output}" == "${first_output}-retry-2" ]] ||
    fail "retry output was not suffixed with -retry-2: ${second_output}"
[[ -d "${second_output}" ]] || fail "retry preflight output directory was not created"

dry_run_output="$(
    XCODEBUILD_BIN="${MOCK_XCODEBUILD}" "${RELEASE_SCRIPT}" --dry-run \
        --output-dir "${OUTPUT_ROOT}/dry-run"
)"
ios_archive_command="$(grep -F 'generic/platform=iOS' <<<"${dry_run_output}")"
macos_archive_command="$(grep -F 'generic/platform=macOS' <<<"${dry_run_output}")"
assert_contains "${ios_archive_command}" 'CODE_SIGN_IDENTITY=Apple\ Development'
assert_contains "${ios_archive_command}" 'CODE_SIGN_STYLE=Automatic'
assert_contains "${macos_archive_command}" 'CODE_SIGN_IDENTITY=Apple\ Development'
assert_contains "${macos_archive_command}" 'CODE_SIGN_STYLE=Automatic'
if [[ "${macos_archive_command}" == *'CODE_SIGNING_ALLOWED=NO'* ]]; then
    fail "macOS archive signing must embed the app entitlements before export"
fi
assert_contains "${dry_run_output}" "CODE_SIGN_STYLE=Automatic"
marketing_argument_count="$(
    grep -F -c 'MARKETING_VERSION=0.1.0' <<<"${dry_run_output}"
)"
[[ "${marketing_argument_count}" == 2 ]] ||
    fail "expected project marketing version on both archive commands"

explicit_version_output="$(
    XCODEBUILD_BIN="${MOCK_XCODEBUILD}" "${RELEASE_SCRIPT}" --dry-run \
        --version 0.2.0 --output-dir "${OUTPUT_ROOT}/explicit-version"
)"
assert_contains "${explicit_version_output}" "version:      0.2.0"
assert_contains "${explicit_version_output}" "MARKETING_VERSION=0.2.0"

automatic_version_output="$(
    XCODEBUILD_BIN="${MOCK_XCODEBUILD}" "${RELEASE_SCRIPT}" --dry-run \
        --version auto --output-dir "${OUTPUT_ROOT}/automatic-version"
)"
[[ "${automatic_version_output}" =~ version:[[:space:]]+[0-9]{4}\.[0-9]{2}\.[0-9]{2} ]] ||
    fail "automatic marketing version was not derived from the commit"

archive_only_output="$(
    XCODEBUILD_BIN="${MOCK_XCODEBUILD}" "${RELEASE_SCRIPT}" --archive-only \
        --version 0.2.0 --output-dir "${OUTPUT_ROOT}/archive-only"
)"
assert_contains "${archive_only_output}" "Verified 1 JollysMQTT bundle version(s)"
assert_contains "${archive_only_output}" \
    "Verified 3 codeless macOS resource bundle(s) have no nested signatures"
assert_contains "${archive_only_output}" "Archives ready; upload skipped."
assert_contains "${archive_only_output}" "preserved all entitlements, including App Sandbox"
[[ ! -e "${MOCK_EXPORT_LOG}" ]] || fail "archive-only performed an export"
[[ "$(grep -c '^--remove-signature ' "${MOCK_SIGNING_LOG}")" == 3 ]] ||
    fail "did not remove exactly the three resource signatures"
if grep -q -- '--deep' "${MOCK_SIGNING_LOG}"; then
    fail "preparing the archive must not re-sign executable frameworks"
fi

unsigned_resources_output="$(
    MOCK_SIGN_MACOS_RESOURCE_BUNDLES=false \
        XCODEBUILD_BIN="${MOCK_XCODEBUILD}" "${RELEASE_SCRIPT}" --archive-only \
        --version 0.2.0 --output-dir "${OUTPUT_ROOT}/unsigned-resources"
)"
assert_contains "${unsigned_resources_output}" "Archives ready; upload skipped."

assert_rejected_before_upload() {
    local scenario="$1"
    local expected="$2"
    local setting="$3"
    if env "${setting}" XCODEBUILD_BIN="${MOCK_XCODEBUILD}" "${RELEASE_SCRIPT}" \
        --version 0.2.0 --output-dir "${OUTPUT_ROOT}/${scenario}" \
        >"${OUTPUT_ROOT}/${scenario}.log" 2>&1
    then
        fail "${scenario} was accepted"
    fi
    assert_contains "$(<"${OUTPUT_ROOT}/${scenario}.log")" "${expected}"
    [[ ! -e "${MOCK_EXPORT_LOG}" ]] || fail "${scenario} reached upload"
}

assert_rejected_before_upload unsigned-app 'no valid signed entitlements' MOCK_UNSIGNED_APP=true
assert_rejected_before_upload sandbox-disabled 'com.apple.security.app-sandbox=true' MOCK_SANDBOX_VALUE=false
assert_rejected_before_upload executable-bundle 'contains an executable' MOCK_EXECUTABLE_BUNDLE=true
assert_rejected_before_upload nested-code 'contains nested code' MOCK_NESTED_CODE=true
assert_rejected_before_upload undeclared-executable 'contains executable code' MOCK_UNDECLARED_EXECUTABLE=true
assert_rejected_before_upload lost-entitlements 'entitlements changed' MOCK_LOSE_ENTITLEMENTS=true

if MOCK_ARCHIVE_MARKETING_VERSION=0.1.0 \
    XCODEBUILD_BIN="${MOCK_XCODEBUILD}" "${RELEASE_SCRIPT}" --archive-only \
    --version 0.2.0 --output-dir "${OUTPUT_ROOT}/mismatched-version" \
    >"${OUTPUT_ROOT}/mismatched-version.log" 2>&1
then
    fail "archive with a mismatched marketing version was accepted"
fi
assert_contains "$(<"${OUTPUT_ROOT}/mismatched-version.log")" \
    "has version 0.1.0; expected 0.2.0"

if XCODEBUILD_BIN="${MOCK_XCODEBUILD}" "${RELEASE_SCRIPT}" --preflight \
    --output-dir "${first_output}" >"${OUTPUT_ROOT}/collision.log" 2>&1
then
    fail "explicit existing output directory was accepted"
fi
collision_output="$(<"${OUTPUT_ROOT}/collision.log")"
assert_contains "${collision_output}" "output path already exists"

if XCODEBUILD_BIN="${MOCK_XCODEBUILD}" "${RELEASE_SCRIPT}" --dry-run \
    --version invalid >"${OUTPUT_ROOT}/invalid-version.log" 2>&1
then
    fail "invalid marketing version was accepted"
fi
assert_contains "$(<"${OUTPUT_ROOT}/invalid-version.log")" \
    "--version must be project, auto, or X.Y.Z"

printf 'All TestFlight release-script tests passed.\n'
