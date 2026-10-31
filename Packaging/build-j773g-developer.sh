#!/bin/bash
# Build the Mac mini M4 (J773g) developer installer from a built image payload:
# the sealed developer catalog (signed with the developer catalog key), the
# developer app, and either the ad hoc developer .pkg or, with a Developer ID
# identity, the signed, notarized and stapled app and its download zip.
#
# Usage: Packaging/build-j773g-developer.sh PAYLOAD_DIRECTORY OUTPUT_DIRECTORY
#
# PAYLOAD_DIRECTORY holds the image builder's output: exactly one
# omarchy-*-os-package.zip (and its .partNN files when it was split for
# hosting) and installer_data.json.
#
# Settings (environment):
#   OMARCHY_J773G_CATALOG_KEY     private developer catalog key (raw Ed25519 seed,
#                                 never in the repository); default
#                                 ~/.config/omarchy-dev-keys/j773g-developer-catalog.ed25519
#   OMARCHY_J773G_BASE_URL        https URL the app downloads the payload (and
#                                 its parts) from; required unless OMARCHY_OFFLINE_BUILD=1
#   OMARCHY_OFFLINE_BUILD=1       embed the payload in the app instead (large app)
#   OMARCHY_APP_SIGNING_IDENTITY  codesign identity: a "Developer ID Application:
#                                 NAME (TEAMID)" name or its SHA-1; default "-" (ad hoc)
#   OMARCHY_TEAM_ID               the identity's team; read from the identity's
#                                 name when it ends in "(TEAMID)"
#   OMARCHY_NOTARY_PROFILE        notarytool keychain profile (xcrun notarytool
#                                 store-credentials); with a Developer ID identity
#                                 the app is notarized and stapled
#
# Ad hoc (the default) builds the app and an unsigned developer .pkg, for this
# Mac only (Gatekeeper override). Nothing here reads or stores a password: the
# certificate lives in the login keychain and the notary credentials in the
# keychain profile.
set -euo pipefail

fail() {
  echo "build-j773g-developer: $*" >&2
  exit 1
}

(( $# == 2 )) || fail "usage: build-j773g-developer.sh PAYLOAD_DIRECTORY OUTPUT_DIRECTORY"
repository="$(cd "$(dirname "$0")/.." && pwd -P)"
payload_directory="$(cd "$1" && pwd -P)"
output="$2"
[[ $output == /* ]] || output="$PWD/$output"
[[ ! -e $output ]] || fail "output already exists: $output"

catalog_key="${OMARCHY_J773G_CATALOG_KEY:-$HOME/.config/omarchy-dev-keys/j773g-developer-catalog.ed25519}"
offline="${OMARCHY_OFFLINE_BUILD:-0}"
base_url="${OMARCHY_J773G_BASE_URL:-}"
identity="${OMARCHY_APP_SIGNING_IDENTITY:--}"
notary_profile="${OMARCHY_NOTARY_PROFILE:-}"
trust_root="$repository/Release/developer-j773g/trust-root.ed25519.pub"

[[ -f $catalog_key && ! -L $catalog_key ]] || fail "missing developer catalog key: $catalog_key"
[[ $(stat -f %Lp "$catalog_key") == 600 ]] || fail "the catalog key must be mode 0600: $catalog_key"
if [[ $offline == 1 ]]; then
  base_url="${base_url:-https://example.invalid/omarchy-j773g}"
else
  [[ $base_url == https://* && $base_url != */ ]] \
    || fail "OMARCHY_J773G_BASE_URL must be an https URL without a trailing slash (or set OMARCHY_OFFLINE_BUILD=1)"
fi
if [[ $identity != - ]]; then
  if [[ -z ${OMARCHY_TEAM_ID:-} && $identity =~ \(([A-Z0-9]{10})\)$ ]]; then
    export OMARCHY_TEAM_ID="${BASH_REMATCH[1]}"
  fi
  [[ ${OMARCHY_TEAM_ID:-} =~ ^[A-Z0-9]{10}$ ]] || fail "OMARCHY_TEAM_ID is required for a named identity"
  security find-identity -v -p codesigning | grep -iF -- "$identity" | grep -q "Developer ID Application" \
    || fail "no valid Developer ID Application identity matching $identity in the keychain"
  [[ -z $notary_profile ]] || xcrun notarytool history --keychain-profile "$notary_profile" >/dev/null \
    || fail "notarytool cannot use the keychain profile $notary_profile"
fi

shopt -s nullglob
payloads=("$payload_directory"/omarchy-*-os-package.zip)
engines=("$repository"/Engine/artifacts/installer-v*.tar.gz)
shopt -u nullglob
(( ${#payloads[@]} == 1 )) || fail "PAYLOAD_DIRECTORY must hold exactly one omarchy-*-os-package.zip"
[[ -f $payload_directory/installer_data.json ]] || fail "PAYLOAD_DIRECTORY has no installer_data.json"
if (( ${#engines[@]} != 1 )); then
  python3 "$repository/Engine/prepare-engine.py" --output "$repository/Engine/artifacts"
  engines=("$repository"/Engine/artifacts/installer-v*.tar.gz)
fi
payload="${payloads[0]}"
payload_name="$(basename "$payload")"

mkdir -p "$output"
assets="$output/assets"
release="$output/release"
mkdir "$assets" "$release"
cp "${engines[0]}" "$assets/"
cp "$payload" "$assets/"
for part in "$payload".part[0-9][0-9]; do
  [[ -e $part ]] && cp "$part" "$assets/"
done
cp "$payload_directory/installer_data.json" "$assets/installer_data.json"
cp "$payload_directory/installer_data.json" "$assets/installer_data-j773g.json"

python3 - "$repository/scripts/release-inputs-j773g-developer.template.json" "$assets/inputs.json" \
  "$payload_name" "$(git -C "$repository" rev-parse HEAD)" <<'PY'
import json, sys
template, out, payload, revision = sys.argv[1:5]
inputs = json.load(open(template))
inputs["payload_name"] = payload
inputs["downstream_revision"] = revision
for group in inputs["developer_models"]:
    group["payload_name"] = payload
json.dump(inputs, open(out, "w"), indent=2)
PY
python3 "$repository/scripts/make-unsigned-catalog.py" --developer \
  --base-url "$base_url" --assets-dir "$assets" --inputs "$assets/inputs.json" --output "$assets/catalog.json"
swift "$repository/scripts/catalog-signing.swift" sign "$catalog_key" "$assets/catalog.json" "$assets/catalog.json.sig"
swift "$repository/scripts/catalog-signing.swift" verify "$trust_root" "$assets/catalog.json" "$assets/catalog.json.sig"

cp "$trust_root" "$assets/catalog.json" "$assets/catalog.json.sig" "$release/"
if [[ $identity == - ]]; then
  cp "$repository/Release/developer-j773g/release.json" "$release/release.json"
else
  # The helper requirement names the signing team, so the descriptor is the
  # Developer ID one for this team, over the same developer trust root.
  "$repository/scripts/make-release-descriptor" --public-key "$trust_root" --output "$release/release.json"
fi
if [[ $offline == 1 ]]; then
  mkdir "$release/offline-artifacts"
  cp "$assets"/installer-v*.tar.gz "$assets/$payload_name" "$assets"/installer_data*.json "$release/offline-artifacts/"
fi

OMARCHY_DEVELOPER_BUILD=1 OMARCHY_OFFLINE_BUILD="$offline" OMARCHY_APP_SIGNING_IDENTITY="$identity" \
  "$repository/Packaging/build-app.sh" "$release" "$output/dist"
app="$output/dist/Omarchy Installer.app"
[[ -d $app ]] || fail "build-app.sh produced no app"

if [[ $identity == - ]]; then
  "$repository/Packaging/build-developer-pkg.sh" "$app" "$output/Omarchy-J773g-developer.pkg"
elif [[ -n $notary_profile ]]; then
  OMARCHY_NOTARY_PROFILE="$notary_profile" "$repository/Packaging/notarize-app.sh" "$app"
  "$repository/Packaging/make-download-zip.sh" "$app" "$output/Omarchy-J773g-developer.zip"
else
  echo "build-j773g-developer: signed with $identity but not notarized (no OMARCHY_NOTARY_PROFILE)" >&2
fi
(cd "$assets" && shasum -a 256 catalog.json catalog.json.sig "$payload_name" installer_data.json installer-v*.tar.gz) \
  | tee "$output/SHA256SUMS"
echo "Built the J773g developer installer in $output"
