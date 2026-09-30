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

cat >"${MOCK_XCODEBUILD}" <<'MOCK'
#!/bin/bash
set -euo pipefail

archive_path=""
marketing_version=""
build_version=""
destination=""
show_build_settings=false
while (($# > 0)); do
    case "$1" in
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

if [[ "${show_build_settings}" == true ]]; then
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
            if [[ "${MOCK_SIGN_MACOS_RESOURCE_BUNDLES:-false}" == true ]]; then
                mkdir -p "${bundle_directory}/Contents/_CodeSignature"
                : >"${bundle_directory}/Contents/_CodeSignature/CodeResources"
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
assert_contains "${macos_archive_command}" 'CODE_SIGNING_ALLOWED=NO'
if [[ "${macos_archive_command}" == *'CODE_SIGN_IDENTITY='* ]]; then
    fail "macOS archive must leave signing to App Store export"
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

if MOCK_SIGN_MACOS_RESOURCE_BUNDLES=true \
    XCODEBUILD_BIN="${MOCK_XCODEBUILD}" "${RELEASE_SCRIPT}" --archive-only \
    --version 0.2.0 --output-dir "${OUTPUT_ROOT}/signed-resource-bundles" \
    >"${OUTPUT_ROOT}/signed-resource-bundles.log" 2>&1
then
    fail "macOS archive with signed package resource bundles was accepted"
fi
assert_contains "$(<"${OUTPUT_ROOT}/signed-resource-bundles.log")" \
    "has a nested code signature"

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
