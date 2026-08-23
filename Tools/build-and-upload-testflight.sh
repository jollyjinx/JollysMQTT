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

usage() {
    cat <<'USAGE'
Build and upload the committed JollysMQTT iOS and macOS apps to TestFlight.

Usage:
  build-and-upload-testflight.sh [--archive-only] [--preflight] [--dry-run]
                                 [--output-dir PATH]

Options:
  --archive-only     Create and verify both archives without uploading them.
  --preflight        Validate the clean commit and upload configuration without
                     building or uploading.
  --dry-run          Print the commands without building or uploading.
  --output-dir PATH  Store archives and export logs at PATH. The path must not
                     already exist and must be outside the Git worktree.
  -h, --help         Show this help.

The script only accepts a clean Git worktree. Its JNX build version must end
in .1, .2, or .3; dirty .0 builds can never be uploaded. It archives the
Official Release configuration so production CloudKit and push entitlements
are used.

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

readonly VERSION_SETTINGS="$(${VERSION_SCRIPT} \
    --repo "${REPOSITORY_ROOT}" \
    --marketing-version existing \
    --require-clean \
    --format xcconfig)"
readonly BUILD_VERSION="$(awk \
    '$1 == "CURRENT_PROJECT_VERSION" && $2 == "=" { print $3 }' \
    <<<"${VERSION_SETTINGS}")"
[[ -n "${BUILD_VERSION}" ]] || die "version script did not produce a build version"
[[ "${BUILD_VERSION}" =~ \.[123]$ ]] ||
    die "committed build version must end in .1, .2, or .3: ${BUILD_VERSION}"

readonly BRANCH_NAME="$(git -C "${REPOSITORY_ROOT}" branch --show-current)"
readonly COMMIT_REVISION="$(git -C "${REPOSITORY_ROOT}" rev-parse --short HEAD)"
readonly COMMIT_SHA="$(git -C "${REPOSITORY_ROOT}" rev-parse HEAD)"

if [[ -z "${output_directory}" ]]; then
    readonly OUTPUT_DIRECTORY_BASE="${TMPDIR:-/tmp}"
    output_directory="${OUTPUT_DIRECTORY_BASE%/}/jollysmqtt-testflight-${BUILD_VERSION}-${COMMIT_REVISION}"
    retry_number=2
    while [[ -e "${output_directory}" ]]; do
        output_directory="${OUTPUT_DIRECTORY_BASE%/}/jollysmqtt-testflight-${BUILD_VERSION}-${COMMIT_REVISION}-retry-${retry_number}"
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
printf '  build:        %s\n' "${BUILD_VERSION}"
printf '  configuration: %s\n' "${CONFIGURATION}"
printf '  team:         %s\n' "${TEAM_ID}"
printf '  output:       %s\n' "${output_directory}"
printf '  upload:       %s\n' "$(
    [[ "${archive_only}" == true || "${preflight_only}" == true ]] &&
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

    run env \
        PATH="${XCODE_TOOL_PATH}" \
        "${XCODEBUILD_BIN}" \
        -project "${PROJECT}" \
        -scheme "${SCHEME}" \
        -configuration "${CONFIGURATION}" \
        -destination "generic/platform=${platform}" \
        -archivePath "${archive_path}" \
        "${authentication_arguments[@]}" \
        CODE_SIGN_STYLE=Automatic \
        CODE_SIGN_IDENTITY="Apple Development" \
        DEVELOPMENT_TEAM="${TEAM_ID}" \
        CURRENT_PROJECT_VERSION="${BUILD_VERSION}" \
        archive
}

verify_archive_versions() {
    local archive_path="$1"
    local verified_count=0
    local info_plist
    local bundle_identifier
    local archived_version

    while IFS= read -r -d '' info_plist; do
        bundle_identifier="$(
            plutil -extract CFBundleIdentifier raw -o - "${info_plist}" 2>/dev/null || true
        )"
        case "${bundle_identifier}" in
            eu.jinx.JollysMQTT|eu.jinx.JollysMQTT.*)
                archived_version="$(
                    plutil -extract CFBundleVersion raw -o - "${info_plist}" 2>/dev/null || true
                )"
                [[ "${archived_version}" == "${BUILD_VERSION}" ]] ||
                    die "${bundle_identifier} has build ${archived_version:-missing}; expected ${BUILD_VERSION}"
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
