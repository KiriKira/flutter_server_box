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

# Screen control ships the dex built from the matching pinned source.
scrcpy_dir="$(mktemp -d)"
trap 'rm -rf -- "$scrcpy_dir"' EXIT
unzip -p "$apk" assets/kiribox-scrcpy-server.jar > "$scrcpy_dir/server.apk"
unzip -t "$scrcpy_dir/server.apk" classes.dex > /dev/null
unzip -p "$apk" assets/scrcpy-LICENSE.txt > "$scrcpy_dir/LICENSE"
test -s "$scrcpy_dir/LICENSE"
server_badging="$("$AAPT2" dump badging "$scrcpy_dir/server.apk")"
if [[ "$server_badging" != *"name='com.genymobile.scrcpy'"* || "$server_badging" != *"versionName='5.0.1'"* ]]; then
  echo '::error::Bundled scrcpy server identity or protocol version is incorrect'
  exit 1
fi
echo 'Verified bundled scrcpy server version=5.0.1 with classes.dex and license'
