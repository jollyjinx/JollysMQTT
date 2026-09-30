#!/bin/bash

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPOSITORY_ROOT="$(git -C "${SCRIPT_DIR}/.." rev-parse --show-toplevel)"
readonly PROJECT="${REPOSITORY_ROOT}/JollysMQTT.xcodeproj"
readonly SCHEME="${JOLLYSMQTT_SCHEME:-JollysMQTT}"
readonly CONFIGURATION="${JOLLYSMQTT_CONFIGURATION:-Official Release}"
readonly TEAM_ID="${JOLLYSMQTT_TEAM_ID:-5V8J7476Q9}"
readonly XCODEBUILD_BIN="${XCODEBUILD_BIN:-xcodebuild}"
readonly VERSION_SCRIPT="${SCRIPT_DIR}/xcode_git_version.sh"
readonly XCODE_TOOL_PATH="/usr/bin:/bin:/usr/sbin:/sbin:${PATH}"

archive_only=false
dry_run=false
preflight_only=false
output_directory=""
output_directory_is_explicit=false
marketing_version_mode="project"

usage() {
    cat <<'USAGE'
Build and upload the committed JollysMQTT iOS and macOS apps to TestFlight.

Usage:
  build-and-upload-testflight.sh [--archive-only] [--preflight] [--dry-run]
                                 [--version project|auto|X.Y.Z]
                                 [--output-dir PATH]

Options:
  --archive-only     Create and verify both archives without uploading them.
  --preflight        Validate the clean commit and upload configuration without
                     building or uploading.
  --dry-run          Print the commands without building or uploading.
  --version VALUE    Set both archives' marketing version. Default: project
                     (use the Official Release Xcode setting). auto derives
                     YYYY.MM.DD from the commit; X.Y.Z uses an explicit version.
  --output-dir PATH  Store archives and export logs at PATH. The path must not
                     already exist and must be outside the Git worktree.
  -h, --help         Show this help.

The script only accepts a clean Git worktree. It creates one JNX build number
from the commit for both platforms; dirty .0 builds can never be uploaded.
It archives the Official Release configuration so production CloudKit and
push entitlements are used.

By default xcodebuild uses the App Store Connect account configured in Xcode.
For API-key authentication, set all three variables:

  APP_STORE_CONNECT_API_KEY_PATH
  APP_STORE_CONNECT_API_KEY_ID
  APP_STORE_CONNECT_API_ISSUER_ID

Optional overrides:

  JOLLYSMQTT_SCHEME
  JOLLYSMQTT_CONFIGURATION
  JOLLYSMQTT_TEAM_ID
  XCODEBUILD_BIN
USAGE
}

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

print_command() {
    printf '+'
    printf ' %q' "$@"
    printf '\n'
}

run() {
    print_command "$@"
    if [[ "${dry_run}" == false ]]; then
        "$@"
    fi
}

while (($# > 0)); do
    case "$1" in
        --archive-only)
            archive_only=true
            shift
            ;;
        --dry-run)
            dry_run=true
            shift
            ;;
        --preflight)
            preflight_only=true
            shift
            ;;
        --version)
            (($# >= 2)) || die "--version requires project, auto, or X.Y.Z"
            marketing_version_mode="$2"
            shift 2
            ;;
        --output-dir)
            (($# >= 2)) || die "--output-dir requires a path"
            output_directory="$2"
            output_directory_is_explicit=true
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1"
            ;;
    esac
done

if [[ "${marketing_version_mode}" != project &&
      "${marketing_version_mode}" != auto &&
      ! "${marketing_version_mode}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    die "--version must be project, auto, or X.Y.Z"
fi

if [[ "${preflight_only}" == true &&
      ("${archive_only}" == true || "${dry_run}" == true) ]]; then
    die "--preflight cannot be combined with --archive-only or --dry-run"
fi
if [[ "${CONFIGURATION}" != "Official Release" &&
      "${archive_only}" == false &&
      "${dry_run}" == false &&
      "${preflight_only}" == false ]]; then
    die "real uploads require JOLLYSMQTT_CONFIGURATION=Official Release"
fi

command -v "${XCODEBUILD_BIN}" >/dev/null 2>&1 ||
    die "xcodebuild executable not found: ${XCODEBUILD_BIN}"
[[ -d "${PROJECT}" ]] || die "Xcode project not found: ${PROJECT}"
[[ -x "${VERSION_SCRIPT}" ]] || die "version script is not executable: ${VERSION_SCRIPT}"
[[ -n "${TEAM_ID}" ]] || die "JOLLYSMQTT_TEAM_ID must not be empty"

git -C "${REPOSITORY_ROOT}" rev-parse --verify HEAD >/dev/null
if [[ -n "$(git -C "${REPOSITORY_ROOT}" status --porcelain=v1 --untracked-files=normal)" ]]; then
    die "the Git worktree is dirty; commit all intended files before releasing"
fi

version_mode_for_script="${marketing_version_mode}"
if [[ "${version_mode_for_script}" == project ]]; then
    version_mode_for_script=existing
fi
readonly VERSION_SETTINGS="$(${VERSION_SCRIPT} \
    --repo "${REPOSITORY_ROOT}" \
    --marketing-version "${version_mode_for_script}" \
    --require-clean \
    --format xcconfig)"
readonly BUILD_VERSION="$(awk \
    '$1 == "CURRENT_PROJECT_VERSION" && $2 == "=" { print $3 }' \
    <<<"${VERSION_SETTINGS}")"
[[ -n "${BUILD_VERSION}" ]] || die "version script did not produce a build version"
[[ "${BUILD_VERSION}" =~ \.[123]$ ]] ||
    die "committed build version must end in .1, .2, or .3: ${BUILD_VERSION}"

if [[ "${marketing_version_mode}" == project ]]; then
    readonly MARKETING_VERSION="$(
        env PATH="${XCODE_TOOL_PATH}" "${XCODEBUILD_BIN}" \
            -project "${PROJECT}" \
            -scheme "${SCHEME}" \
            -configuration "${CONFIGURATION}" \
            -destination 'generic/platform=iOS' \
            -showBuildSettings |
            awk '/^[[:space:]]*MARKETING_VERSION = / && !found { version=$3; found=1 } END { print version }'
    )"
else
    readonly MARKETING_VERSION="$(awk \
        '$1 == "MARKETING_VERSION" && $2 == "=" { print $3 }' \
        <<<"${VERSION_SETTINGS}")"
fi
[[ "${MARKETING_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "invalid or missing marketing version: ${MARKETING_VERSION:-missing}"

readonly BRANCH_NAME="$(git -C "${REPOSITORY_ROOT}" branch --show-current)"
readonly COMMIT_REVISION="$(git -C "${REPOSITORY_ROOT}" rev-parse --short HEAD)"
readonly COMMIT_SHA="$(git -C "${REPOSITORY_ROOT}" rev-parse HEAD)"

if [[ -z "${output_directory}" ]]; then
    readonly OUTPUT_DIRECTORY_BASE="${TMPDIR:-/tmp}"
    output_directory="${OUTPUT_DIRECTORY_BASE%/}/jollysmqtt-testflight-${MARKETING_VERSION}-${BUILD_VERSION}-${COMMIT_REVISION}"
    retry_number=2
    while [[ -e "${output_directory}" ]]; do
        output_directory="${OUTPUT_DIRECTORY_BASE%/}/jollysmqtt-testflight-${MARKETING_VERSION}-${BUILD_VERSION}-${COMMIT_REVISION}-retry-${retry_number}"
        retry_number=$((retry_number + 1))
    done
elif [[ "${output_directory}" != /* ]]; then
    die "--output-dir must be an absolute path"
fi

case "${output_directory}" in
    "${REPOSITORY_ROOT}"|"${REPOSITORY_ROOT}/"*)
        die "--output-dir must be outside the Git worktree"
        ;;
esac

if [[ "${output_directory_is_explicit}" == true && -e "${output_directory}" ]]; then
    die "output path already exists: ${output_directory}"
fi

readonly IOS_ARCHIVE="${output_directory}/JollysMQTT-iOS.xcarchive"
readonly MACOS_ARCHIVE="${output_directory}/JollysMQTT-macOS.xcarchive"
readonly EXPORT_OPTIONS="${output_directory}/TestFlightExportOptions.plist"

authentication_arguments=(-allowProvisioningUpdates)
authentication_value_count=0
for value in \
    "${APP_STORE_CONNECT_API_KEY_PATH:-}" \
    "${APP_STORE_CONNECT_API_KEY_ID:-}" \
    "${APP_STORE_CONNECT_API_ISSUER_ID:-}"
do
    if [[ -n "${value}" ]]; then
        authentication_value_count=$((authentication_value_count + 1))
    fi
done

if ((authentication_value_count != 0 && authentication_value_count != 3)); then
    die "set all three App Store Connect API-key variables, or none of them"
fi

if ((authentication_value_count == 3)); then
    [[ -f "${APP_STORE_CONNECT_API_KEY_PATH}" ]] ||
        die "App Store Connect API key not found: ${APP_STORE_CONNECT_API_KEY_PATH}"
    authentication_arguments+=(
        -authenticationKeyPath "${APP_STORE_CONNECT_API_KEY_PATH}"
        -authenticationKeyID "${APP_STORE_CONNECT_API_KEY_ID}"
        -authenticationKeyIssuerID "${APP_STORE_CONNECT_API_ISSUER_ID}"
    )
fi

printf 'JollysMQTT TestFlight release\n'
printf '  commit:       %s (%s)\n' "${COMMIT_REVISION}" "${BRANCH_NAME:-detached HEAD}"
printf '  version:      %s\n' "${MARKETING_VERSION}"
printf '  build:        %s\n' "${BUILD_VERSION}"
printf '  configuration: %s\n' "${CONFIGURATION}"
printf '  team:         %s\n' "${TEAM_ID}"
printf '  output:       %s\n' "${output_directory}"
printf '  upload:       %s\n' "$(
    [[ "${archive_only}" == true || "${preflight_only}" == true || "${dry_run}" == true ]] &&
        printf 'no' ||
        printf 'yes'
)"

if [[ "${dry_run}" == false ]]; then
    mkdir "${output_directory}"
fi

write_export_options() {
    plutil -create xml1 "${EXPORT_OPTIONS}"
    plutil -insert destination -string upload "${EXPORT_OPTIONS}"
    plutil -insert method -string app-store-connect "${EXPORT_OPTIONS}"
    plutil -insert signingStyle -string automatic "${EXPORT_OPTIONS}"
    plutil -insert teamID -string "${TEAM_ID}" "${EXPORT_OPTIONS}"
    plutil -insert manageAppVersionAndBuildNumber -bool false "${EXPORT_OPTIONS}"
    plutil -insert uploadSymbols -bool true "${EXPORT_OPTIONS}"
    plutil -lint "${EXPORT_OPTIONS}"
}

if [[ "${archive_only}" == false && "${dry_run}" == false ]]; then
    write_export_options
fi

if [[ "${preflight_only}" == true ]]; then
    printf 'Preflight succeeded; no archives were created or uploaded.\n'
    exit 0
fi

archive_platform() {
    local platform="$1"
    local archive_path="$2"
    local signing_arguments=()

    case "${platform}" in
        iOS)
            signing_arguments=(
                CODE_SIGN_STYLE=Automatic
                CODE_SIGN_IDENTITY="Apple Development"
            )
            ;;
        macOS)
            # SwiftPM's codeless resource bundles are otherwise signed with
            # Apple Development during the archive. Mac App Store export
            # preserves those nested signatures while remotely signing the
            # containing app, which causes ITMS-90284. Leave the archive
            # unsigned so export signs the app and seals these bundles as
            # resources.
            signing_arguments=(CODE_SIGNING_ALLOWED=NO)
            ;;
        *)
            die "unsupported archive platform: ${platform}"
            ;;
    esac

    run env \
        PATH="${XCODE_TOOL_PATH}" \
        "${XCODEBUILD_BIN}" \
        -project "${PROJECT}" \
        -scheme "${SCHEME}" \
        -configuration "${CONFIGURATION}" \
        -destination "generic/platform=${platform}" \
        -archivePath "${archive_path}" \
        "${authentication_arguments[@]}" \
        "${signing_arguments[@]}" \
        DEVELOPMENT_TEAM="${TEAM_ID}" \
        MARKETING_VERSION="${MARKETING_VERSION}" \
        CURRENT_PROJECT_VERSION="${BUILD_VERSION}" \
        archive
}

verify_macos_resource_bundles() {
    local archive_path="$1"
    local app_path
    local resource_bundle
    local info_plist
    local resource_bundle_count=0

    app_path="$(find "${archive_path}/Products/Applications" \
        -maxdepth 1 -type d -name '*.app' -print -quit)"
    [[ -n "${app_path}" ]] ||
        die "no macOS app bundle found in archive: ${archive_path}"

    while IFS= read -r -d '' resource_bundle; do
        resource_bundle_count=$((resource_bundle_count + 1))
        info_plist="${resource_bundle}/Contents/Info.plist"
        [[ -f "${info_plist}" ]] ||
            die "macOS resource bundle is missing Contents/Info.plist: ${resource_bundle}"
        if plutil -extract CFBundleExecutable raw -o - "${info_plist}" \
            >/dev/null 2>&1; then
            die "macOS Swift package resource bundle contains an executable and needs distribution signing: ${resource_bundle}"
        fi
        [[ ! -e "${resource_bundle}/Contents/_CodeSignature" ]] ||
            die "macOS Swift package resource bundle has a nested code signature; it must be unsigned for Mac App Store export: ${resource_bundle}"
    done < <(find "${app_path}/Contents/Resources" -maxdepth 1 \
        -type d -name '*.bundle' -print0)

    printf 'Verified %d codeless macOS resource bundle(s) have no nested signatures in %s\n' \
        "${resource_bundle_count}" "${archive_path}"
}

verify_archive_versions() {
    local archive_path="$1"
    local verified_count=0
    local info_plist
    local bundle_identifier
    local archived_version
    local archived_marketing_version

    while IFS= read -r -d '' info_plist; do
        bundle_identifier="$(
            plutil -extract CFBundleIdentifier raw -o - "${info_plist}" 2>/dev/null || true
        )"
        case "${bundle_identifier}" in
            eu.jinx.jollymqtt|eu.jinx.jollymqtt.*)
                archived_version="$(
                    plutil -extract CFBundleVersion raw -o - "${info_plist}" 2>/dev/null || true
                )"
                archived_marketing_version="$(
                    plutil -extract CFBundleShortVersionString raw -o - "${info_plist}" 2>/dev/null || true
                )"
                [[ "${archived_version}" == "${BUILD_VERSION}" ]] ||
                    die "${bundle_identifier} has build ${archived_version:-missing}; expected ${BUILD_VERSION}"
                [[ "${archived_marketing_version}" == "${MARKETING_VERSION}" ]] ||
                    die "${bundle_identifier} has version ${archived_marketing_version:-missing}; expected ${MARKETING_VERSION}"
                verified_count=$((verified_count + 1))
                ;;
        esac
    done < <(find "${archive_path}/Products/Applications" -name Info.plist -print0)

    ((verified_count > 0)) ||
        die "no JollysMQTT application bundles found in archive: ${archive_path}"
    printf 'Verified %d JollysMQTT bundle version(s) in %s\n' \
        "${verified_count}" "${archive_path}"
}

verify_source_unchanged() {
    [[ "$(git -C "${REPOSITORY_ROOT}" rev-parse HEAD)" == "${COMMIT_SHA}" ]] ||
        die "HEAD changed while the archives were being built; nothing was uploaded"
    [[ -z "$(git -C "${REPOSITORY_ROOT}" status --porcelain=v1 --untracked-files=normal)" ]] ||
        die "the worktree changed while the archives were being built; nothing was uploaded"
}

archive_platform iOS "${IOS_ARCHIVE}"
archive_platform macOS "${MACOS_ARCHIVE}"

if [[ "${dry_run}" == false ]]; then
    verify_archive_versions "${IOS_ARCHIVE}"
    verify_archive_versions "${MACOS_ARCHIVE}"
    verify_macos_resource_bundles "${MACOS_ARCHIVE}"
    verify_source_unchanged
fi

if [[ "${archive_only}" == true ]]; then
    if [[ "${dry_run}" == true ]]; then
        printf 'Dry run complete; no archives were created.\n'
    else
        printf 'Archives ready; upload skipped.\n'
    fi
    exit 0
fi

upload_archive() {
    local platform_name="$1"
    local archive_path="$2"
    local export_path="${output_directory}/Upload-${platform_name}"

    run env \
        PATH="${XCODE_TOOL_PATH}" \
        "${XCODEBUILD_BIN}" \
        -exportArchive \
        -archivePath "${archive_path}" \
        -exportPath "${export_path}" \
        -exportOptionsPlist "${EXPORT_OPTIONS}" \
        "${authentication_arguments[@]}"
}

upload_archive iOS "${IOS_ARCHIVE}"
upload_archive macOS "${MACOS_ARCHIVE}"

if [[ "${dry_run}" == true ]]; then
    printf 'Dry run complete; no archives were created or uploaded.\n'
else
    printf 'Submitted iOS and macOS build %s to App Store Connect/TestFlight.\n' \
        "${BUILD_VERSION}"
fi
