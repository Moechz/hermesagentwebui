#!/bin/bash
# Build hermeswebui TOS packages.
#   - Stages package trees under dist/ from packaging/templates + assets +
#     payload pins (upstream app copy, vendored wheels, generated manifest,
#     agent locked requirements, first-start bootstrap).
#   - Substitutes __VERSION__ / __DEB_ARCH__ / __TOS_PLATFORM__.
#   - Enforces LF line endings (official spec 4.6).
#   - Builds .deb via dpkg-deb on Linux only; macOS stages only (AGENTS.md 7).
# Env: ALLOW_PENDING=1 emits a manifest with unverified (null) hashes —
# the on-device bootstrap always refuses such manifests.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATES="$ROOT/packaging/templates"
ASSETS="$ROOT/packaging/assets"
PAYLOAD="$ROOT/packaging/payload"
UPSTREAM="$ROOT/upstream/hermes-webui"
DIST="$ROOT/dist"
APP_ID=hermeswebui
VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  # Default: upstream webui version + packaging sequence, e.g. 0.52.302-001
  # (D-012: track the pinned upstream tag; -NNN is our rebuild counter).
  VERSION=$(python3 -c "import json;p=json.load(open('$PAYLOAD/component-pins.json'));print(p['webui']['version']+'-'+p['packaging_seq'])")
fi

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
  # subst <file> <platform|-> <debarch|-> <apptype|-> ; in-place replacement.
  local f="$1" plat="$2" darch="$3" atype="${4:-}"
  python3 - "$f" "$VERSION" "$plat" "$darch" "$atype" <<'PY'
import sys
f, ver, plat, darch, atype = sys.argv[1:6]
with open(f, encoding='utf-8') as fh:
    s = fh.read()
s = s.replace('__VERSION__', ver)
if plat != '-':
    s = s.replace('__TOS_PLATFORM__', plat)
if darch != '-':
    s = s.replace('__DEB_ARCH__', darch)
if atype and atype != '-':
    # Official application-types: "deb" = single-package mode (what the
    # App Center local installer parses), "deb-TarGz" = dual-package
    # archive mode (store submission). A single deb declaring deb-TarGz
    # fails App Center parsing (user-verified on a second device).
    s = s.replace('__APP_TYPE__', atype)
with open(f, 'w', encoding='utf-8') as fh:
    fh.write(s)
PY
}

stage_app() {
  # <dst> : copy the upstream runtime surface (server + api + static).
  local dst="$1"
  local app="$dst/usr/local/hermeswebui/app"
  # Guard: the clone must sit exactly at the pinned tag (D-012).
  local pinned_tag webui_ver
  pinned_tag=$(python3 -c "import json;print(json.load(open('$PAYLOAD/component-pins.json'))['webui']['tag'])")
  webui_ver=$(python3 -c "import json;print(json.load(open('$PAYLOAD/component-pins.json'))['webui']['version'])")
  local describe
  describe=$(git -C "$UPSTREAM" describe --tags 2>/dev/null || true)
  if [ "$describe" != "$pinned_tag" ]; then
    echo "build: upstream clone is at '${describe:-untagged}' but pins expect '$pinned_tag'" >&2
    echo "      fix: git -C upstream/hermes-webui fetch --depth 1 origin tag $pinned_tag && git -C upstream/hermes-webui checkout $pinned_tag" >&2
    exit 1
  fi
  mkdir -p "$app"
  for item in server.py api static requirements.txt LICENSE README.md; do
    if [ -e "$UPSTREAM/$item" ]; then
      cp -R "$UPSTREAM/$item" "$app/"
    else
      echo "build: missing upstream item: $UPSTREAM/$item" >&2
      exit 1
    fi
  done
  # The staged copy has no .git; write the release-workflow artifact so the
  # server's version detection (api/updates.py order 2) reports the tag
  # instead of 'unknown'.
  printf "__version__ = 'v%s'\n" "$webui_ver" > "$app/api/_version.py"
  find "$app" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
}

stage_wheels() {
  # <dst> <platform> : download + verify the vendored webui wheels (cached
  # under dist/wheel-cache/<plat>; retried up to 3 times per wheel).
  local dst="$1" plat="$2"
  local wheels="$dst/usr/local/hermeswebui/wheels"
  local cache="$ROOT/.cache/wheels/$plat"
  mkdir -p "$wheels" "$cache"
  python3 - "$PAYLOAD/wheels.lock" "$plat" "$wheels" "$cache" <<'PY'
import hashlib, json, os, sys, time, urllib.request
lock, plat, out, cache = sys.argv[1:5]
pkgs = json.load(open(lock))["packages"]
reqs = []
for name, p in pkgs.items():
    w = p["wheels"][plat]
    cached = os.path.join(cache, w["file"])
    if not os.path.exists(cached):
        for attempt in range(1, 4):
            try:
                h = hashlib.sha256(); got = 0
                with urllib.request.urlopen(w["url"], timeout=180) as r, open(cached + ".part", "wb") as f:
                    while True:
                        c = r.read(1 << 20)
                        if not c: break
                        got += len(c); h.update(c); f.write(c)
                if got != w["size"] or h.hexdigest() != w["sha256"]:
                    # Transient CDN truncation/corruption is common; retry
                    # with a fresh download (a real tamper fails all 3).
                    raise RuntimeError(
                        f"integrity mismatch got={got}/{h.hexdigest()[:12]}")
                os.replace(cached + ".part", cached)
                break
            except Exception as e:
                if os.path.exists(cached + ".part"):
                    os.remove(cached + ".part")
                if attempt == 3:
                    raise SystemExit(f"wheel failed after 3 tries: {w['file']}: {e}")
                print(f"  retry {attempt} for {w['file']}: {e}")
                time.sleep(5)
    print(f"  wheel ok: {w['file']}")
    reqs.append(f"{name}=={p['version']}")
for f in os.listdir(cache):
    if f.endswith(".whl"):
        import shutil; shutil.copy2(os.path.join(cache, f), os.path.join(out, f))
with open(os.path.join(out, "requirements.txt"), "w") as f:
    f.write("\n".join(reqs) + "\n")
PY
}

stage_manifest() {
  # <dst> <platform>
  local dst="$1" plat="$2"
  local man="$dst/usr/local/hermeswebui/manifests"
  mkdir -p "$man"
  local extra=()
  if [ "${ALLOW_PENDING:-0}" = "1" ]; then extra+=("--allow-pending"); fi
  python3 "$ROOT/scripts/generate-manifest.py" \
    --pins "$PAYLOAD/component-pins.json" \
    --version "$VERSION" --arch "$plat" \
    --out "$man/components.json" "${extra[@]:+${extra[@]}}"
}

stage_agent_payload() {
  # <dst>
  local dst="$1"
  mkdir -p "$dst/usr/local/hermeswebui/agent"
  cp "$PAYLOAD/agent-core-requirements.txt" \
     "$dst/usr/local/hermeswebui/agent/agent-core-requirements.txt"
  cp "$PAYLOAD/lazy-extras.lock" \
     "$dst/usr/local/hermeswebui/agent/lazy-extras.lock"
}

stage_common_metadata() {
  # <dst> : destination package root; metadata shared by data/manual debs.
  # TOS App Center parses TOS metadata from /usr/local/<appid>/ inside the
  # deb's data tar — NOT from the deb root. Proven by both validated
  # references: metube (/usr/local/metubedownload/config.ini) and Rsync
  # Backup (/usr/local/rsyncbackup/config.ini). Root placement made the
  # App Center manual installer fail with "parse failed" (user-verified).
  local dst="$1"
  mkdir -p "$dst/usr/local/hermeswebui/images/icons"
  cp "$TEMPLATES/config.ini" "$dst/usr/local/hermeswebui/config.ini"
  cp "$TEMPLATES/hermeswebui.lang" "$dst/usr/local/hermeswebui/hermeswebui.lang"
  cp "$ASSETS/hermeswebui.svg" \
     "$dst/usr/local/hermeswebui/images/icons/hermeswebui.svg"
}

stage_service_tree() {
  # <dst> <platform> <debarch> [control-template]
  local dst="$1" plat="$2" darch="$3"
  local ctl="${4:-$TEMPLATES/service-control.in}"
  mkdir -p \
    "$dst/DEBIAN" \
    "$dst/usr/local/hermeswebui/bin" \
    "$dst/usr/local/hermeswebui/init.d"
  cp "$ctl" "$dst/DEBIAN/control"
  cp "$TEMPLATES/postinst"  "$dst/DEBIAN/postinst"
  cp "$TEMPLATES/prerm"     "$dst/DEBIAN/prerm"
  cp "$TEMPLATES/postrm"    "$dst/DEBIAN/postrm"
  cp "$TEMPLATES/hermeswebui.in" "$dst/usr/local/hermeswebui/bin/hermeswebui"
  cp "$TEMPLATES/hermeswebui-bootstrap.py.in" \
     "$dst/usr/local/hermeswebui/bin/hermeswebui-bootstrap"
  cp "$TEMPLATES/hermeswebui.service" \
     "$dst/usr/local/hermeswebui/init.d/hermeswebui.service"
  stage_app "$dst"
  stage_wheels "$dst" "$plat"
  stage_manifest "$dst" "$plat"
  stage_agent_payload "$dst"
  subst "$dst/DEBIAN/control" - "$darch"
  chmod 0755 "$dst/DEBIAN/postinst" "$dst/DEBIAN/prerm" "$dst/DEBIAN/postrm" \
             "$dst/usr/local/hermeswebui/bin/hermeswebui" \
             "$dst/usr/local/hermeswebui/bin/hermeswebui-bootstrap"
}

build_deb() {
  # <tree> <output.deb>
  if [ "$(uname)" = "Linux" ]; then
    # TOS App Center's package parser does not understand zstd members
    # (dpkg does). Match the validated metube layout: control.tar.gz +
    # data.tar.xz (--no-uniform-compression keeps the control member as
    # classic gzip while data uses xz).
    dpkg-deb --root-owner-group --no-uniform-compression -Zxz -b "$1" "$2"
  else
    echo "  (macOS: staging only, dpkg-deb skipped) $2"
  fi
}

# Wipe generated output only; keep operator-staged material such as
# dist/assets (release-upload copies of pinned components).
rm -rf "$DIST/stage"
find "$DIST" -maxdepth 1 -name '*.deb' -delete
find "$DIST" -maxdepth 1 -name '*.tar.gz' -delete
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
  subst "$DATA/usr/local/hermeswebui/config.ini" "$plat" - deb-TarGz
  # NOTE: the data deb config.ini must match the submitted platform even
  # though the deb itself is Architecture: all (official naming/checks).
  to_lf $(find "$SVC" "$DATA" -type f \
           \( -name '*.sh' -o -name '*.py' -o -name '*.ini' \
              -o -name '*.lang' -o -name '*.service' -o -name '*.conf' \
              -o -name 'postinst' -o -name 'prerm' -o -name 'postrm' \
              -o -name 'hermeswebui' -o -name 'hermeswebui-bootstrap' \))
  build_deb "$SVC" "$DIST/hermeswebui-service_${VERSION}_${darch}.deb"
  build_deb "$DATA" "$DIST/hermeswebui-data_${VERSION}_all_${plat}.deb"

  # Store/App-Center dual-package archive (validated Rsync Backup recipe):
  # <appid>_<platform>.tar.gz containing <appid>.deb (data, renamed plain)
  # + <appid>-service_<version>_<debarch>.deb (source). This is what the
  # App Center manual-install page parses; a bare deb fails parsing.
  # (Linux only — needs the built debs; macOS stages trees only.)
  if [ -f "$DIST/hermeswebui-data_${VERSION}_all_${plat}.deb" ] \
     && [ -f "$DIST/hermeswebui-service_${VERSION}_${darch}.deb" ]; then
  BUNDLE="$DIST/bundle-$plat"
  rm -rf "$BUNDLE"
  mkdir -p "$BUNDLE"
  cp "$DIST/hermeswebui-data_${VERSION}_all_${plat}.deb" "$BUNDLE/hermeswebui.deb"
  cp "$DIST/hermeswebui-service_${VERSION}_${darch}.deb" "$BUNDLE/"
  TARGZ="$DIST/hermeswebui_${plat}.tar.gz"
  rm -f "$TARGZ" "$TARGZ.sha256"
  LC_ALL=C tar -czf "$TARGZ" -C "$BUNDLE" \
    hermeswebui.deb "hermeswebui-service_${VERSION}_${darch}.deb"
  (cd "$DIST" && shasum -a 256 "hermeswebui_${plat}.tar.gz" \
    > "hermeswebui_${plat}.tar.gz.sha256" 2>/dev/null || \
    sha256sum "hermeswebui_${plat}.tar.gz" > "hermeswebui_${plat}.tar.gz.sha256")
  fi

  # Single-package manual-install deb (same content, one package).
  MAN="$DIST/stage/${plat}/hermeswebui-manual"
  # Single-package manual deb: identical payload, Package: hermeswebui
  # (reference convention: service deb keeps the -service suffix).
  stage_service_tree "$MAN" "$plat" "$darch" "$TEMPLATES/manual-control.in"
  stage_common_metadata "$MAN"
  subst "$MAN/usr/local/hermeswebui/config.ini" "$plat" - deb
  to_lf $(find "$MAN" -type f \
           \( -name '*.sh' -o -name '*.py' -o -name '*.ini' \
              -o -name '*.lang' -o -name '*.service' -o -name '*.conf' \
              -o -name 'postinst' -o -name 'prerm' -o -name 'postrm' \
              -o -name 'hermeswebui' -o -name 'hermeswebui-bootstrap' \))
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
