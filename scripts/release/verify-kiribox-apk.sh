#!/usr/bin/env bash
# Check the install identity inside the compiled APK, independent of labels.
set -euo pipefail
apk="${1:?APK required}"
expected_version="${2:?version required}"
: "${AAPT2:?aapt2 path required}"
badging="$("$AAPT2" dump badging "$apk")"
package="$(sed -n "s/^package: name='\([^']*\)'.*/\1/p" <<< "$badging")"
version="$(sed -n "s/^package:.* versionName='\([^']*\)'.*/\1/p" <<< "$badging")"
if [[ "$package" != tech.kirikira.kiribox || "$version" != "$expected_version" ]]; then
  echo "::error::Unexpected APK install identity: package=$package version=$version"
  exit 1
fi
printf 'Verified APK package=%s version=%s file=%s\n' "$package" "$version" "$(basename "$apk")"
