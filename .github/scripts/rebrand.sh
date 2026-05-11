#!/usr/bin/env bash
# Cadrega rebrand: rewrites applicationId + user-visible "Lawnchair" -> "Cadrega".
# Internal Kotlin/Java FQNs (app.lawnchair.*) stay untouched on purpose:
# changing them would break class loading and guarantee rebase conflicts.
# Run from the repo root. Idempotent.

set -euo pipefail

OLD_APP_ID="app.lawnchair"
NEW_APP_ID="it.belloworld.cadrega"
OLD_APP_ID_RE="${OLD_APP_ID//./\\.}"

if [[ ! -f build.gradle ]]; then
  echo "rebrand.sh: build.gradle not found; run from repo root" >&2
  exit 1
fi

sed -i \
  -e "s|applicationId '${OLD_APP_ID}'|applicationId '${NEW_APP_ID}'|" \
  -e "s|applicationId '${OLD_APP_ID}\\.nightly'|applicationId '${NEW_APP_ID}.nightly'|" \
  -e "s|applicationId \"${OLD_APP_ID}\\.play\"|applicationId \"${NEW_APP_ID}.play\"|" \
  -e 's|resValue("string", "derived_app_name", "Lawnchair (Debug)")|resValue("string", "derived_app_name", "Cadrega (Debug)")|' \
  -e 's|resValue("string", "derived_app_name", "Lawnchair")|resValue("string", "derived_app_name", "Cadrega")|' \
  -e 's|outputFileName = "Lawnchair\.|outputFileName = "Cadrega.|' \
  build.gradle

sed -i 's|^rootProject\.name = "lawnchair"$|rootProject.name = "cadrega"|' settings.gradle

# Fail loud if anchored patterns silently no-op (upstream drift detection).
# These four lines must rewrite or the resulting build will keep the upstream name.
if grep -qF "applicationId '${OLD_APP_ID}'" build.gradle \
  || grep -qE 'resValue\("string", "derived_app_name", "Lawnchair' build.gradle \
  || grep -qF 'outputFileName = "Lawnchair.' build.gradle \
  || grep -qE '^rootProject\.name = "lawnchair"$' settings.gradle; then
  echo "rebrand.sh: residual Lawnchair pattern in gradle files; upstream drift?" >&2
  exit 1
fi

# Rewrite the two hardcoded intent-action FQNs (app.lawnchair.START_ACTION,
# app.lawnchair.APPLY_ICONS) wherever they appear: AndroidManifest.xml entries
# plus their matching Kotlin/Java string constants. The broader app.lawnchair.*
# package namespace is intentionally left alone.
# grep exit 0 = match, 1 = no match (fine), >1 = real error (abort).
# Capturing via process substitution would hide a real failure under set -e.
rc=0
grep_out=$(grep -rlE "${OLD_APP_ID_RE}\\.(START_ACTION|APPLY_ICONS)" \
  --include='*.kt' --include='*.java' --include='*.xml' \
  .) || rc=$?
if (( rc > 1 )); then
  echo "rebrand.sh: grep failed with rc=$rc" >&2
  exit "$rc"
fi
if [[ -n "$grep_out" ]]; then
  mapfile -t files <<<"$grep_out"
  sed -i -E "s#${OLD_APP_ID_RE}\\.(START_ACTION|APPLY_ICONS)#${NEW_APP_ID}.\\1#g" "${files[@]}"
fi

# strings.xml across locales: "Lawnchair" -> "Cadrega" inside element text only,
# preserving attribute values (name="...") and copyright comments.
python3 - <<'PY'
import os, re, glob, sys

paths = sorted(glob.glob('lawnchair/res/values*/strings.xml'))
# Defend against an upstream commit shipping a symlink that escapes the resource
# tree (e.g. lawnchair/res/values-x/strings.xml -> ~/.gradle/init.gradle).
# realpath the candidate and require containment under lawnchair/res/.
root = os.path.realpath('lawnchair/res') + os.sep
pat = re.compile(r'(<(string|plurals|item)\b[^>]*>)(.*?)(</\2>)', re.DOTALL)
total_repls = 0
touched_files = 0

for path in paths:
    real = os.path.realpath(path)
    if not real.startswith(root):
        print(f"rebrand.sh: refusing symlink escape: {path} -> {real}", file=sys.stderr)
        sys.exit(1)
    with open(real, encoding='utf-8') as f:
        original = f.read()
    count = [0]
    def repl(m):
        new_inner, n = re.subn(r'Lawnchair', 'Cadrega', m.group(3))
        count[0] += n
        return m.group(1) + new_inner + m.group(4)
    text = pat.sub(repl, original)
    if text != original:
        with open(real, 'w', encoding='utf-8') as f:
            f.write(text)
        touched_files += 1
        total_repls += count[0]

print(f"strings.xml: {touched_files}/{len(paths)} files, {total_repls} replacements", file=sys.stderr)
PY

# Launcher icon swap: replace upstream Lawnchair icon with the Cadrega assets
# vendored at .github/assets/icons/ on the tooling branch (copied into the
# build tree by the workflow alongside this script).
#
# The provided XMLs are vector adaptive-icons that reference @drawable/* (not
# @mipmap/*), so the foreground/background vectors go in res/drawable/. With
# minSdk=26, the v26 adaptive XML always resolves first, so the legacy
# per-density mipmap PNGs become unreachable and are removed.
ICONS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../assets/icons" && pwd)"

required_icons=(
  ic_launcher_home.xml
  ic_launcher_home_foreground.xml
  ic_launcher_home_background.xml
  ic_launcher_home_monochrome.xml
  ic_launcher_home-playstore.png
)
for f in "${required_icons[@]}"; do
  if [[ ! -f "${ICONS_DIR}/${f}" ]]; then
    echo "rebrand.sh: missing icon asset: ${ICONS_DIR}/${f}" >&2
    exit 1
  fi
done

# Upstream layout sanity (drift guard): if any of these dirs are gone, the
# icon refs in the manifest will silently resolve to the upstream resource.
for d in res/mipmap-anydpi-v26 res/drawable lawnchair/res/drawable; do
  if [[ ! -d "$d" ]]; then
    echo "rebrand.sh: expected icon target dir missing: $d (upstream drift?)" >&2
    exit 1
  fi
done

cp "${ICONS_DIR}/ic_launcher_home.xml"            res/mipmap-anydpi-v26/ic_launcher_home.xml
cp "${ICONS_DIR}/ic_launcher_home.xml"            res/mipmap-anydpi-v26/ic_launcher_home_round.xml
cp "${ICONS_DIR}/ic_launcher_home.xml"            res/drawable/ic_launcher_home.xml
cp "${ICONS_DIR}/ic_launcher_home_foreground.xml" res/drawable/ic_launcher_home_foreground.xml
cp "${ICONS_DIR}/ic_launcher_home_background.xml" res/drawable/ic_launcher_home_background.xml
cp "${ICONS_DIR}/ic_launcher_home_monochrome.xml" lawnchair/res/drawable/ic_launcher_home_monochrome.xml
cp "${ICONS_DIR}/ic_launcher_home-playstore.png"  ic_launcher_home-playstore.png
cp "${ICONS_DIR}/ic_launcher_home-playstore.png"  lawnchair/res/drawable/ic_launcher_home_comp.png

# Drop the per-density bitmaps — unreachable with adaptive-vector + minSdk=26.
rm -f res/mipmap-mdpi/ic_launcher_home.png \
      res/mipmap-hdpi/ic_launcher_home.png \
      res/mipmap-xhdpi/ic_launcher_home.png \
      res/mipmap-xxhdpi/ic_launcher_home.png \
      res/mipmap-xxxhdpi/ic_launcher_home.png \
      res/mipmap-mdpi/ic_launcher_home_round.png \
      res/mipmap-hdpi/ic_launcher_home_round.png \
      res/mipmap-xhdpi/ic_launcher_home_round.png \
      res/mipmap-xxhdpi/ic_launcher_home_round.png \
      res/mipmap-xxxhdpi/ic_launcher_home_round.png \
      res/mipmap-mdpi/ic_launcher_home_foreground.png \
      res/mipmap-hdpi/ic_launcher_home_foreground.png \
      res/mipmap-xhdpi/ic_launcher_home_foreground.png \
      res/mipmap-xxhdpi/ic_launcher_home_foreground.png \
      res/mipmap-xxxhdpi/ic_launcher_home_foreground.png \
      res/mipmap-mdpi/ic_launcher_home_background.png \
      res/mipmap-hdpi/ic_launcher_home_background.png \
      res/mipmap-xhdpi/ic_launcher_home_background.png \
      res/mipmap-xxhdpi/ic_launcher_home_background.png \
      res/mipmap-xxxhdpi/ic_launcher_home_background.png

echo "rebrand.sh: swapped launcher icons from ${ICONS_DIR}"

# Build branches (cadrega-dev, cadrega-v*) are force-pushed by the fork's
# automation. Upstream workflows shipped in the tree (lint, CI, release-on-tag)
# would re-trigger on every push and either burn minutes or fight our release
# pipeline. The fork's own workflows live on the `tooling` branch and run there.
if [[ -d .github/workflows ]]; then
  rm -rf .github/workflows
fi

echo "rebrand.sh done: applicationId=${NEW_APP_ID}"
