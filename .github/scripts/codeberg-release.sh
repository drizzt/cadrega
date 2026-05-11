#!/usr/bin/env bash
# Create or replace a Forgejo release on Codeberg and upload assets.
#
# Replaces `actions/forgejo-release@v2.11.1`, which can't be used as a GH
# Actions `uses:` target (it lives on code.forgejo.org, not github.com).
#
# Required env:
#   CODEBERG_URL         e.g. https://codeberg.org
#   CODEBERG_REPO        e.g. BelloWorld/cadrega
#   CODEBERG_TOKEN       Forgejo PAT with `write:repository` scope
#   TAG                  release tag (must exist on Codeberg, or
#                        TARGET_COMMITISH must point at a branch whose
#                        HEAD on Codeberg is the desired build commit)
#   RELEASE_DIR          directory whose files become release assets
#   TITLE                release title (defaults to TAG)
#   BODY                 release notes (markdown)
# Optional env:
#   TARGET_COMMITISH     branch name; used only when TAG does not yet
#                        exist (Forgejo then creates the tag at that
#                        branch's HEAD). Defaults to `tooling`.
#   PRERELEASE           true/false (default false)
#   OVERRIDE             true/false; if true, delete existing release
#                        and tag of the same name first (default false)
#
# `set -u` is intentional — we want loud failure on missing env. -e on
# the rest of the script; explicit `|| true` only around tolerated 404s.
# pipefail catches jq parse failures inside `$(body_of "$resp" | jq ...)`,
# which would otherwise produce a silently-empty release_id.

set -euo pipefail

: "${CODEBERG_URL:?}"; : "${CODEBERG_REPO:?}"; : "${CODEBERG_TOKEN:?}"
: "${TAG:?}"; : "${RELEASE_DIR:?}"; : "${BODY:?}"
TITLE="${TITLE:-$TAG}"
TARGET_COMMITISH="${TARGET_COMMITISH:-tooling}"
PRERELEASE="${PRERELEASE:-false}"
OVERRIDE="${OVERRIDE:-false}"

api="$CODEBERG_URL/api/v1/repos/$CODEBERG_REPO"
auth=(-H "Authorization: token $CODEBERG_TOKEN")

# `-w '\n%{http_code}'` separates body from status so we can inspect
# both without parsing curl stderr.
http_get()    { curl -sS "${auth[@]}" -w '\n%{http_code}' "$@"; }
http_delete() { curl -sS -X DELETE "${auth[@]}" -w '\n%{http_code}' "$@"; }
http_post_json() {
  curl -sS -X POST "${auth[@]}" -H 'Content-Type: application/json' \
    -w '\n%{http_code}' "$@"
}
status_of() { tail -n1 <<<"$1"; }
body_of()   { sed '$d'      <<<"$1"; }

# 1. Override: delete release + tag if requested.
if [[ "$OVERRIDE" == "true" ]]; then
  resp=$(http_get "$api/releases/tags/$TAG")
  code=$(status_of "$resp")
  if [[ "$code" == "200" ]]; then
    release_id=$(body_of "$resp" | jq -r '.id')
    echo "Deleting existing release id=$release_id (tag=$TAG)"
    delresp=$(http_delete "$api/releases/$release_id")
    delcode=$(status_of "$delresp")
    if [[ "$delcode" != "204" ]]; then
      echo "::error::Failed to delete release $release_id: HTTP $delcode"
      echo "$delresp"
      exit 1
    fi
  elif [[ "$code" == "404" ]]; then
    echo "No existing release for tag $TAG; nothing to delete."
  else
    echo "::error::Unexpected status looking up release: HTTP $code"
    echo "$resp"
    exit 1
  fi

  # Tag deletion is best-effort: a 404 here just means the tag wasn't
  # there in the first place (release deletion alone leaves any
  # underlying tag in place on Forgejo).
  tagresp=$(http_delete "$api/tags/$TAG")
  tagcode=$(status_of "$tagresp")
  case "$tagcode" in
    204|404) echo "Tag delete result: $tagcode" ;;
    *) echo "::warning::Tag delete returned HTTP $tagcode (continuing)"; echo "$tagresp" ;;
  esac
fi

# 2. Create the release. We always recreate (after the optional override
# above) — Forgejo's release API has no idempotent upsert.
payload=$(jq -n \
  --arg tag         "$TAG" \
  --arg target      "$TARGET_COMMITISH" \
  --arg name        "$TITLE" \
  --arg body        "$BODY" \
  --argjson prerelease "$PRERELEASE" \
  '{tag_name: $tag, target_commitish: $target, name: $name, body: $body, prerelease: $prerelease, draft: false}')

resp=$(http_post_json -d "$payload" "$api/releases")
code=$(status_of "$resp")
if [[ "$code" != "201" ]]; then
  echo "::error::Release create failed: HTTP $code"
  echo "$resp"
  exit 1
fi
release_id=$(body_of "$resp" | jq -r '.id')
release_url=$(body_of "$resp" | jq -r '.html_url')
echo "Created release id=$release_id at $release_url"

# 3. Upload assets. Forgejo accepts multipart with the `attachment` field
# and a `name=` query parameter that controls the displayed filename.
shopt -s nullglob
asset_count=0
for f in "$RELEASE_DIR"/*; do
  [[ -f "$f" ]] || continue
  name=$(basename "$f")
  echo "Uploading $name ..."
  upresp=$(curl -sS -X POST "${auth[@]}" -w '\n%{http_code}' \
    -F "attachment=@$f" \
    "$api/releases/$release_id/assets?name=$(jq -rn --arg s "$name" '$s|@uri')")
  upcode=$(status_of "$upresp")
  if [[ "$upcode" != "201" ]]; then
    echo "::error::Asset upload failed for $name: HTTP $upcode"
    echo "$upresp"
    exit 1
  fi
  asset_count=$((asset_count + 1))
done

if (( asset_count == 0 )); then
  echo "::warning::No files uploaded from $RELEASE_DIR"
fi
echo "Done: $asset_count asset(s) uploaded to $release_url"
