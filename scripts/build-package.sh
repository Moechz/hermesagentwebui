#!/bin/bash
# Build hermeswebui TOS packages.
#   - Stages package trees under dist/ from packaging/templates + assets.
#   - Substitutes __VERSION__ / __DEB_ARCH__ / __TOS_PLATFORM__.
#   - Enforces LF line endings (official spec 4.6).
#   - Builds .deb via dpkg-deb on Linux only; macOS stages only (AGENTS.md 7).
# App payload staging (upstream copy, vendored wheels, components manifest)
# is a TODO for the next milestone; the trees produced today are skeletons.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATES="$ROOT/packaging/templates"
ASSETS="$ROOT/packaging/assets"
DIST="$ROOT/dist"
APP_ID=hermeswebui
VERSION="${1:-0.0.1}"

PLATFORMS="x86_64 aarch64"   # TOS platform names (config.ini platform)
debarch_for() {
  case "$1" in
    x86_64) echo amd64 ;;
    aarch64) echo arm64 ;;
    *) echo "unknown platform: $1" >&2; exit 1 ;;
  esac
}

to_lf() {
  # Official 4.6: all .sh/.py/.ini/.lang/.service/.conf must be LF.
  python3 - "$@" <<'PY'
import sys
for p in sys.argv[1:]:
    with open(p, 'rb') as f:
        data = f.read()
    lf = data.replace(b'\r\n', b'\n')
    if lf != data:
        with open(p, 'wb') as f:
            f.write(lf)
        print(f'  CRLF->LF: {p}')
PY
}

subst() {
  # subst <file> <platform|-> <debarch|-> ; replaces placeholders in place.
  local f="$1" plat="$2" darch="$3"
  python3 - "$f" "$VERSION" "$plat" "$darch" <<'PY'
import sys
f, ver, plat, darch = sys.argv[1:5]
with open(f, encoding='utf-8') as fh:
    s = fh.read()
s = s.replace('__VERSION__', ver)
if plat != '-':
    s = s.replace('__TOS_PLATFORM__', plat)
if darch != '-':
    s = s.replace('__DEB_ARCH__', darch)
with open(f, 'w', encoding='utf-8') as fh:
    fh.write(s)
PY
}

stage_common_metadata() {
  # <dst> : destination package root; metadata shared by data/manual debs.
  local dst="$1"
  mkdir -p "$dst/images/icons"
  cp "$TEMPLATES/config.ini" "$dst/config.ini"
  cp "$TEMPLATES/hermeswebui.lang" "$dst/hermeswebui.lang"
  cp "$ASSETS/hermeswebui.svg" "$dst/images/icons/hermeswebui.svg"
}

stage_service_tree() {
  # <dst> : destination package root; service payload + unit + lifecycle.
  local dst="$1" plat="$2" darch="$3"
  mkdir -p \
    "$dst/DEBIAN" \
    "$dst/usr/local/hermeswebui/bin" \
    "$dst/usr/local/hermeswebui/init.d" \
    "$dst/usr/local/hermeswebui/manifests"
  cp "$TEMPLATES/service-control.in" "$dst/DEBIAN/control"
  cp "$TEMPLATES/postinst"  "$dst/DEBIAN/postinst"
  cp "$TEMPLATES/prerm"     "$dst/DEBIAN/prerm"
  cp "$TEMPLATES/postrm"    "$dst/DEBIAN/postrm"
  cp "$TEMPLATES/hermeswebui.in" "$dst/usr/local/hermeswebui/bin/hermeswebui"
  cp "$TEMPLATES/hermeswebui.service" \
     "$dst/usr/local/hermeswebui/init.d/hermeswebui.service"
  # TODO(payload): stage upstream app/, vendored wheels/, and
  # manifests/components.json (pinned URLs + SHA-256) per D-010.
  subst "$dst/DEBIAN/control" - "$darch"
  chmod 0755 "$dst/DEBIAN/postinst" "$dst/DEBIAN/prerm" "$dst/DEBIAN/postrm" \
             "$dst/usr/local/hermeswebui/bin/hermeswebui"
}

build_deb() {
  # <tree> <output.deb>
  if [ "$(uname)" = "Linux" ]; then
    dpkg-deb --root-owner-group -b "$1" "$2"
  else
    echo "  (macOS: staging only, dpkg-deb skipped) $2"
  fi
}

rm -rf "$DIST"
mkdir -p "$DIST"

for plat in $PLATFORMS; do
  darch="$(debarch_for "$plat")"

  # Dual-package mode: source (service) deb + data deb -> tar.gz archive.
  SVC="$DIST/stage/${plat}/hermeswebui-service"
  DATA="$DIST/stage/${plat}/hermeswebui-data"
  stage_service_tree "$SVC" "$plat" "$darch"
  mkdir -p "$DATA/DEBIAN"
  stage_common_metadata "$DATA"
  cp "$TEMPLATES/data-control.in" "$DATA/DEBIAN/control"
  cp "$TEMPLATES/data-postinst" "$DATA/DEBIAN/postinst"
  chmod 0755 "$DATA/DEBIAN/postinst"
  subst "$DATA/DEBIAN/control" - -        # data deb: Architecture all
  subst "$DATA/config.ini" "$plat" -      # __TOS_PLATFORM__
  # NOTE: the data deb config.ini must match the submitted platform even
  # though the deb itself is Architecture: all (official naming/checks).
  to_lf $(find "$SVC" "$DATA" -type f \
           \( -name '*.sh' -o -name '*.py' -o -name '*.ini' \
              -o -name '*.lang' -o -name '*.service' -o -name '*.conf' \
              -o -name 'postinst' -o -name 'prerm' -o -name 'postrm' \
              -o -name 'hermeswebui' \))
  build_deb "$SVC" "$DIST/hermeswebui-service_${VERSION}_${darch}.deb"
  build_deb "$DATA" "$DIST/hermeswebui-data_${VERSION}_all_${plat}.deb"

  # Single-package manual-install deb (same content, one package).
  MAN="$DIST/stage/${plat}/hermeswebui-manual"
  stage_service_tree "$MAN" "$plat" "$darch"
  stage_common_metadata "$MAN"
  subst "$MAN/config.ini" "$plat" -
  to_lf $(find "$MAN" -type f \
           \( -name '*.sh' -o -name '*.py' -o -name '*.ini' \
              -o -name '*.lang' -o -name '*.service' -o -name '*.conf' \
              -o -name 'postinst' -o -name 'prerm' -o -name 'postrm' \
              -o -name 'hermeswebui' \))
  build_deb "$MAN" "$DIST/hermeswebui_${VERSION}_${darch}_manual.deb"

  # Dual-mode submission archive: <app_id>_<platform>.tar.gz wrapping the
  # two debs (official Release asset naming, package-specification 4.3).
  if [ "$(uname)" = "Linux" ]; then
    tar -czf "$DIST/${APP_ID}_${plat}.tar.gz" \
        -C "$DIST" \
        "hermeswebui-service_${VERSION}_${darch}.deb" \
        "hermeswebui-data_${VERSION}_all_${plat}.deb"
  fi
done

echo "Done. Version=$VERSION staging under $DIST/stage"
[ "$(uname)" = "Linux" ] || echo "Reminder: final artifacts must come from a Linux build (AGENTS.md 9)."
