#!/bin/zsh

set -euo pipefail

script_dir=${0:A:h}
repository_root=${script_dir:h}
package_root="$repository_root/JollysMQTTPackage"
catalog="$package_root/Sources/JollysMQTT/Resources/Localizable.xcstrings"
configuration=${1:-Debug}
architecture=$(uname -m)
stringsdata_directory="$package_root/.build/out/Intermediates.noindex/JollysMQTTPackage.build/$configuration/JollysMQTT-t.build/Objects-normal/$architecture"

if [[ ! -d "$stringsdata_directory" ]]; then
  print -u2 "Missing compiler localization output for $configuration. Run 'swift build' in JollysMQTTPackage first."
  exit 1
fi

audit_directory=$(mktemp -d /tmp/jollysmqtt-localization-audit.XXXXXX)
trap 'rm -rf "$audit_directory"' EXIT

find "$stringsdata_directory" -type f -name '*.stringsdata' ! -name 'GeneratedStringSymbols_*' -print0 \
  | xargs -0 jq -r '.tables.Localizable[]?.key' \
  | sort -u > "$audit_directory/extracted-keys"
jq -r '.strings | keys[]' "$catalog" \
  | sort -u > "$audit_directory/catalog-keys"

comm -23 "$audit_directory/extracted-keys" "$audit_directory/catalog-keys" \
  > "$audit_directory/missing-keys"
if [[ -s "$audit_directory/missing-keys" ]]; then
  print -u2 'Compiler-extracted package strings missing from Localizable.xcstrings:'
  sed 's/^/  /' "$audit_directory/missing-keys" >&2
  exit 1
fi

comm -13 "$audit_directory/extracted-keys" "$audit_directory/catalog-keys" \
  > "$audit_directory/unexpected-keys"
if [[ -s "$audit_directory/unexpected-keys" ]]; then
  print -u2 'Localizable.xcstrings entries not present in compiler extraction:'
  sed 's/^/  /' "$audit_directory/unexpected-keys" >&2
  exit 1
fi

jq -r '.strings | to_entries[] | select(.value.extractionState == "stale") | .key' "$catalog" \
  > "$audit_directory/stale-keys"
if [[ -s "$audit_directory/stale-keys" ]]; then
  print -u2 'Stale entries remain in Localizable.xcstrings:'
  sed 's/^/  /' "$audit_directory/stale-keys" >&2
  exit 1
fi

jq -e '
  .sourceLanguage == "en"
  and .version == "1.0"
  and ([.strings[].localizations? // {} | keys[]] | all(. == "en"))
  and ([
    .strings[].localizations? // {}
    | .[].stringUnit
    | select(
        (.state != "new" and .state != "translated")
        or (.value | type != "string")
      )
  ] | length == 0)
' "$catalog" > /dev/null

xcrun xcstringstool compile "$catalog" \
  --output-directory "$audit_directory/compiled" \
  --dry-run > /dev/null

print "Localization audit passed: $(wc -l < "$audit_directory/extracted-keys" | tr -d ' ') extracted keys, $(wc -l < "$audit_directory/catalog-keys" | tr -d ' ') catalog keys, source language en."
