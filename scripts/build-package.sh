#!/bin/bash
# Build hermesagent TOS packages.
#   - Stages package trees under dist/ from packaging/templates + assets +
#     payload pins (upstream app copy, vendored wheels, bundled component
#     payload, generated manifest, agent locked requirements, first-start
#     bootstrap).
#   - Fully offline deb (D-015, store rule S8): the portable CPython
#     runtime and agent source tarballs are copied from dist/assets into
#     the deb payload after hash verification, and the vendored wheels
#     cover webui deps + agent deps + lazy extras + build tools. Nothing
#     is fetched on the device.
#   - Substitutes __VERSION__ / __DEB_ARCH__ / __TOS_PLATFORM__.
#   - Enforces LF line endings (official spec 4.6).
#   - Builds .deb via dpkg-deb on Linux only; macOS stages only (AGENTS.md 7).
# Env: ALLOW_PENDING=1 emits a manifest with unverified (null) hashes —
# the on-device bootstrap always refuses such manifests.
set -euo pipefail

# macOS bsdtar embeds file xattrs as AppleDouble ._ members; the TOS App
# Center parser rejects deb/tar members it does not know ("package parse
# failed"), and extracted ._ files re-enter debs built from transferred
# trees. Guard every tar this script makes (validated Rsync Backup recipe:
# build-local-manual-deb.sh uses COPYFILE_DISABLE=1).
export COPYFILE_DISABLE=1

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMPLATES="$ROOT/packaging/templates"
ASSETS="$ROOT/packaging/assets"
PAYLOAD="$ROOT/packaging/payload"
UPSTREAM="$ROOT/upstream/hermes-webui"
DIST="$ROOT/dist"
APP_ID=hermesagent
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
  local app="$dst/usr/local/hermesagent/app"
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
  # under dist/wheel-cache/<plat>; retried up to 3 times per wheel) and
  # copy every cached wheel (incl. the agent wheels fetched by
  # stage_agent_wheels) into the tree.
  local dst="$1" plat="$2"
  local wheels="$dst/usr/local/hermesagent/wheels"
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
  # Build tools for the offline editable install (D-015); consumed by the
  # bootstrap via pip --no-build-isolation and fingerprinted with the
  # webui wheels (both live in the venv).
  cp "$PAYLOAD/build-tools.lock" "$wheels/build-tools.txt"
}

stage_agent_wheels() {
  # <platform> : cross-download the agent dependency wheels for the TARGET
  # platform into the shared wheel cache (hash-checked against the locks by
  # pip --require-hashes; the running host python never imports them).
  # Runs on macOS/Linux for either target arch (S8/D-015: wheels ship in
  # the deb; the device never touches an index).
  local plat="$1"
  local cache="$ROOT/.cache/wheels/$plat"
  mkdir -p "$cache"
  local plat_flags
  case "$plat" in
    x86_64)
      plat_flags="--platform manylinux2014_x86_64 --platform manylinux_2_17_x86_64 --platform manylinux_2_28_x86_64 --platform any" ;;
    aarch64)
      plat_flags="--platform manylinux2014_aarch64 --platform manylinux_2_17_aarch64 --platform manylinux_2_28_aarch64 --platform any" ;;
    *) echo "stage_agent_wheels: unknown platform $plat" >&2; exit 1 ;;
  esac
  echo "stage_agent_wheels: downloading agent wheels for $plat ..."
  python3 -m pip download \
    --require-hashes --only-binary=:all: --no-deps \
    --implementation cp --python-version 312 \
    --abi cp312 --abi abi3 --abi none \
    $plat_flags \
    --dest "$cache" \
    -r "$PAYLOAD/agent-core-requirements.txt" \
    -r "$PAYLOAD/lazy-extras.lock" \
    -r "$PAYLOAD/build-tools.lock"
}

stage_payload() {
  # <dst> <platform> : copy the pinned component tarballs (portable CPython,
  # agent source) from operator-staged dist/assets into the deb payload,
  # verifying size + sha256 against component-pins.json (D-015: the payload
  # IS the install source now; a bad asset must fail the build, not the
  # device).
  local dst="$1" plat="$2"
  local pay="$dst/usr/local/hermesagent/payload"
  mkdir -p "$pay"
  python3 - "$PAYLOAD/component-pins.json" "$DIST/assets" "$pay" "$plat" <<'PY'
import hashlib, json, os, shutil, sys
pins, srcdir, out, plat = sys.argv[1:5]
p = json.load(open(pins))
comps = {"runtime": p["runtime"]["targets"][plat], "agent": p["agent"]}
for section, c in comps.items():
    for k in ("file", "sha256", "size"):
        if not c.get(k):
            raise SystemExit(f"stage_payload: pins {section}.{k} missing")
    src = os.path.join(srcdir, c["file"])
    if not os.path.isfile(src):
        raise SystemExit(f"stage_payload: {src} missing — stage the pinned "
                         "assets under dist/assets/ (see component-pins.json)")
    if os.path.getsize(src) != int(c["size"]):
        raise SystemExit(f"stage_payload: {src} size mismatch")
    h = hashlib.sha256()
    with open(src, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    if h.hexdigest() != c["sha256"]:
        raise SystemExit(f"stage_payload: {src} sha256 mismatch")
    shutil.copy2(src, os.path.join(out, c["file"]))
    print(f"  payload ok: {c['file']}")
PY
}

stage_manifest() {
  # <dst> <platform>
  local dst="$1" plat="$2"
  local man="$dst/usr/local/hermesagent/manifests"
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
  mkdir -p "$dst/usr/local/hermesagent/agent"
  cp "$PAYLOAD/agent-core-requirements.txt" \
     "$dst/usr/local/hermesagent/agent/agent-core-requirements.txt"
  cp "$PAYLOAD/lazy-extras.lock" \
     "$dst/usr/local/hermesagent/agent/lazy-extras.lock"
}

stage_common_metadata() {
  # <dst> : destination package root; metadata shared by data/manual debs.
  # TOS App Center parses TOS metadata from /usr/local/<appid>/ inside the
  # deb's data tar — NOT from the deb root. Proven by both validated
  # references: metube (/usr/local/metubedownload/config.ini) and Rsync
  # Backup (/usr/local/rsyncbackup/config.ini). Root placement made the
  # App Center manual installer fail with "parse failed" (user-verified).
  local dst="$1"
  mkdir -p "$dst/usr/local/hermesagent/images/icons"
  cp "$TEMPLATES/config.ini" "$dst/usr/local/hermesagent/config.ini"
  cp "$TEMPLATES/hermesagent.lang" "$dst/usr/local/hermesagent/hermesagent.lang"
  cp "$ASSETS/hermesagent.svg" \
     "$dst/usr/local/hermesagent/images/icons/hermesagent.svg"
}

stage_service_tree() {
  # <dst> <platform> <debarch> [control-template]
  local dst="$1" plat="$2" darch="$3"
  local ctl="${4:-$TEMPLATES/service-control.in}"
  mkdir -p \
    "$dst/DEBIAN" \
    "$dst/usr/local/hermesagent/bin" \
    "$dst/usr/local/hermesagent/init.d"
  cp "$ctl" "$dst/DEBIAN/control"
  cp "$TEMPLATES/postinst"  "$dst/DEBIAN/postinst"
  cp "$TEMPLATES/prerm"     "$dst/DEBIAN/prerm"
  cp "$TEMPLATES/postrm"    "$dst/DEBIAN/postrm"
  cp "$TEMPLATES/hermesagent.in" "$dst/usr/local/hermesagent/bin/hermesagent"
  cp "$TEMPLATES/hermesagent-bootstrap.py.in" \
     "$dst/usr/local/hermesagent/bin/hermesagent-bootstrap"
  cp "$TEMPLATES/hermesagent-provision.py" \
     "$dst/usr/local/hermesagent/bin/hermesagent-provision"
  cp "$TEMPLATES/hermesagent.service" \
     "$dst/usr/local/hermesagent/init.d/hermesagent.service"
  stage_app "$dst"
  stage_agent_wheels "$plat"
  stage_wheels "$dst" "$plat"
  stage_payload "$dst" "$plat"
  stage_manifest "$dst" "$plat"
  stage_agent_payload "$dst"
  subst "$dst/DEBIAN/control" - "$darch"
  chmod 0755 "$dst/DEBIAN/postinst" "$dst/DEBIAN/prerm" "$dst/DEBIAN/postrm" \
             "$dst/usr/local/hermesagent/bin/hermesagent" \
             "$dst/usr/local/hermesagent/bin/hermesagent-bootstrap" \
             "$dst/usr/local/hermesagent/bin/hermesagent-provision"
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
  SVC="$DIST/stage/${plat}/hermesagent-service"
  DATA="$DIST/stage/${plat}/hermesagent-data"
  stage_service_tree "$SVC" "$plat" "$darch"
  mkdir -p "$DATA/DEBIAN"
  stage_common_metadata "$DATA"
  cp "$TEMPLATES/data-control.in" "$DATA/DEBIAN/control"
  cp "$TEMPLATES/data-postinst" "$DATA/DEBIAN/postinst"
  chmod 0755 "$DATA/DEBIAN/postinst"
  subst "$DATA/DEBIAN/control" - -        # data deb: Architecture all
  subst "$DATA/usr/local/hermesagent/config.ini" "$plat" - deb-TarGz
  # NOTE: the data deb config.ini must match the submitted platform even
  # though the deb itself is Architecture: all (official naming/checks).
  to_lf $(find "$SVC" "$DATA" -type f \
           \( -name '*.sh' -o -name '*.py' -o -name '*.ini' \
              -o -name '*.lang' -o -name '*.service' -o -name '*.conf' \
              -o -name 'postinst' -o -name 'prerm' -o -name 'postrm' \
              -o -name 'hermesagent' -o -name 'hermesagent-bootstrap' \
              -o -name 'hermesagent-provision' \))
  # Hard guard: no macOS junk may ever enter a built package.
  junk_guard() {
    local found
    found=$(find "$DIST/stage/$plat" \( -name '._*' -o -name '.DS_Store' \) \
            -print -quit 2>/dev/null || true)
    [ -z "$found" ] || { echo "FAIL: AppleDouble/junk file in stage tree: $found" >&2; exit 1; }
  }
  junk_guard
  build_deb "$SVC" "$DIST/hermesagent-service_${VERSION}_${darch}.deb"
  build_deb "$DATA" "$DIST/hermesagent-data_${VERSION}_all_${plat}.deb"

  # Store/App-Center dual-package archive (validated Rsync Backup recipe):
  # <appid>_<platform>.tar.gz containing <appid>.deb (data, renamed plain)
  # + <appid>-service_<version>_<debarch>.deb (source). Store submission
  # archive shape (official Release asset naming, package-specification
  # 4.3); the App Center manual-install page also accepts single debs —
  # see the manual deb below (device-validated by the Rsync Backup
  # project's single-package manual installs).
  # (Linux only — needs the built debs; macOS stages trees only.)
  if [ -f "$DIST/hermesagent-data_${VERSION}_all_${plat}.deb" ] \
     && [ -f "$DIST/hermesagent-service_${VERSION}_${darch}.deb" ]; then
  BUNDLE="$DIST/bundle-$plat"
  rm -rf "$BUNDLE"
  mkdir -p "$BUNDLE"
  cp "$DIST/hermesagent-data_${VERSION}_all_${plat}.deb" "$BUNDLE/hermesagent.deb"
  cp "$DIST/hermesagent-service_${VERSION}_${darch}.deb" "$BUNDLE/"
  TARGZ="$DIST/hermesagent_${plat}.tar.gz"
  rm -f "$TARGZ" "$TARGZ.sha256"
  LC_ALL=C tar -czf "$TARGZ" -C "$BUNDLE" \
    hermesagent.deb "hermesagent-service_${VERSION}_${darch}.deb"
  (cd "$DIST" && shasum -a 256 "hermesagent_${plat}.tar.gz" \
    > "hermesagent_${plat}.tar.gz.sha256" 2>/dev/null || \
    sha256sum "hermesagent_${plat}.tar.gz" > "hermesagent_${plat}.tar.gz.sha256")
  fi

  # Single-package manual-install deb (same content, one package).
  MAN="$DIST/stage/${plat}/hermesagent-manual"
  # Single-package manual deb: identical payload, Package: hermesagent
  # (reference convention: service deb keeps the -service suffix).
  stage_service_tree "$MAN" "$plat" "$darch" "$TEMPLATES/manual-control.in"
  stage_common_metadata "$MAN"
  subst "$MAN/usr/local/hermesagent/config.ini" "$plat" - deb
  to_lf $(find "$MAN" -type f \
           \( -name '*.sh' -o -name '*.py' -o -name '*.ini' \
              -o -name '*.lang' -o -name '*.service' -o -name '*.conf' \
              -o -name 'postinst' -o -name 'prerm' -o -name 'postrm' \
              -o -name 'hermesagent' -o -name 'hermesagent-bootstrap' \
              -o -name 'hermesagent-provision' \))
  # Hard guard again: the manual tree was staged after the check above.
  junk_guard
  build_deb "$MAN" "$DIST/hermesagent_${VERSION}_${plat}.deb"
  # Manual-install deb naming follows the official pattern
  # <app_id>_<platform>.deb (package-specification: platform token is the
  # TOS platform name, never the deb arch). The local artifact keeps the
  # version infix like the validated Rsync Backup manual packages
  # (rsyncbackup_<version>_<platform>.deb); for Release uploads the
  # publishing-process spec requires the bare <app_id>_<platform>.deb
  # (version comes from Release metadata). "amd64" in the filename made
  # the App Center manual-install page reject the package (device
  # finding 2026-09-15).

  # Dual-mode submission archive: <app_id>_<platform>.tar.gz wrapping the
  # two debs (official Release asset naming, package-specification 4.3).
  if [ "$(uname)" = "Linux" ]; then
    tar -czf "$DIST/${APP_ID}_${plat}.tar.gz" \
        -C "$DIST" \
        "hermesagent-service_${VERSION}_${darch}.deb" \
        "hermesagent-data_${VERSION}_all_${plat}.deb"
  fi
done

echo "Done. Version=$VERSION staging under $DIST/stage"
[ "$(uname)" = "Linux" ] || echo "Reminder: final artifacts must come from a Linux build (AGENTS.md 9)."
