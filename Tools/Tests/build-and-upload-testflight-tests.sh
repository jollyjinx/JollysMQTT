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

first_preflight="$(
    TMPDIR="${OUTPUT_ROOT}/" XCODEBUILD_BIN=/usr/bin/true \
        "${RELEASE_SCRIPT}" --preflight
)"
first_output="$(awk -F ': +' '$1 == "  output" { print $2 }' <<<"${first_preflight}")"
[[ -d "${first_output}" ]] || fail "first preflight output directory was not created"

second_preflight="$(
    TMPDIR="${OUTPUT_ROOT}/" XCODEBUILD_BIN=/usr/bin/true \
        "${RELEASE_SCRIPT}" --preflight
)"
second_output="$(awk -F ': +' '$1 == "  output" { print $2 }' <<<"${second_preflight}")"
[[ "${second_output}" == "${first_output}-retry-2" ]] ||
    fail "retry output was not suffixed with -retry-2: ${second_output}"
[[ -d "${second_output}" ]] || fail "retry preflight output directory was not created"

dry_run_output="$(
    XCODEBUILD_BIN=/usr/bin/true "${RELEASE_SCRIPT}" --dry-run \
        --output-dir "${OUTPUT_ROOT}/dry-run"
)"
signing_argument_count="$(
    grep -F -c 'CODE_SIGN_IDENTITY=Apple\ Development' <<<"${dry_run_output}"
)"
[[ "${signing_argument_count}" == 2 ]] ||
    fail "expected Apple Development signing on both archive commands"
assert_contains "${dry_run_output}" "CODE_SIGN_STYLE=Automatic"

if XCODEBUILD_BIN=/usr/bin/true "${RELEASE_SCRIPT}" --preflight \
    --output-dir "${first_output}" >"${OUTPUT_ROOT}/collision.log" 2>&1
then
    fail "explicit existing output directory was accepted"
fi
collision_output="$(<"${OUTPUT_ROOT}/collision.log")"
assert_contains "${collision_output}" "output path already exists"

printf 'All TestFlight release-script tests passed.\n'
