#!/bin/bash
# Validate hermesagent packaging templates against the official rules
# mirrored in docs/official/ (review-standards automated checks, cicd-guide
# validation script, package-specification 4.x). Runs on macOS and Linux.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$ROOT/packaging/templates"
A="$ROOT/packaging/assets"

python3 - "$T" "$A" <<'PY'
import json, os, re, sys

T, A = sys.argv[1], sys.argv[2]
errors, notes = [], []

def err(msg): errors.append(msg)

# --- config.ini ---------------------------------------------------------
cfg_path = os.path.join(T, 'config.ini')
raw = open(cfg_path, 'rb').read()
if raw.startswith(b'\xef\xbb\xbf'):
    err('config.ini has BOM')
if b'\r\n' in raw:
    err('config.ini has CRLF line endings')
cfg = json.loads(raw.decode('utf-8'))

required = ['id', 'icon', 'publisher', 'exec', 'version', 'low_version',
            'category', 'depend', 'platform', 'application_type', 'user',
            'all_user_display', 'allow_open_in_mobile']
for f in required:
    assert f in cfg, f'Missing required field: {f}'
if cfg['application_type'] == 'deb-TarGz':
    for f in ('system_id', 'package'):
        assert f in cfg, f'deb-TarGz must have {f}'
if 'type' in cfg and 'open_path' in cfg:
    err('type and open_path cannot coexist')
if len(cfg['category']) > 3:
    err('category exceeds maximum of 3')
if '${ip}' not in cfg['path']:
    err('path must use the ${ip} placeholder')
if cfg['id'] != cfg['system_id'] or cfg['id'] != cfg['package']:
    err('id/system_id/package must match')
if cfg['version'] != '__VERSION__':
    err('config.ini version must be the __VERSION__ placeholder here')
# WebUI External Open (D-011): open_path replaces type; URL path opens in a
# new browser tab (official docker-development example shape); embedded
# window size fields are zeroed.
if cfg.get('open_path') is not True:
    err('config.ini must set open_path=true (WebUI External Open, D-011)')
if not cfg['path'].startswith('http://${ip}'):
    err('external open path must be http://${ip}:<port>')
if 'type' in cfg:
    err('D-011: type must be removed when open_path is set')
if cfg.get('width') or cfg.get('height'):
    err('external open must not declare an embedded window size')

# --- hermesagent.lang ---------------------------------------------------
lang_path = os.path.join(T, 'hermesagent.lang')
lraw = open(lang_path, 'rb').read()
if lraw.startswith(b'\xef\xbb\xbf'):
    err('lang file has BOM')
if b'\r\n' in lraw:
    err('lang file has CRLF line endings')
lang = lraw.decode('utf-8')

expected_23 = ['ar-sa', 'cs-cz', 'de-de', 'en-us', 'es-es', 'fr-fr', 'he-il',
               'hu-hu', 'id-id', 'it-it', 'ja-jp', 'ko-kr', 'nb-no', 'nl-nl',
               'pl-pl', 'pt-pt', 'ru-ru', 'sv-se', 'th-th', 'tr-tr', 'vi-vn',
               'zh-cn', 'zh-hk']
official_14 = ['zh-cn', 'zh-hk', 'en-us', 'fr-fr', 'de-de', 'it-it', 'es-es',
               'hu-hu', 'ja-jp', 'ko-kr', 'pl-pl', 'ru-ru', 'tr-tr', 'pt-pt']
sections = re.findall(r'^\[([a-z]{2}-[a-z]{2})\]$', lang, re.M)
if sorted(sections) != sorted(expected_23):
    missing = set(expected_23) - set(sections)
    extra = set(sections) - set(expected_23)
    err(f'lang sections mismatch: missing={missing or "-"} extra={extra or "-"}')
for need in official_14:
    if need not in sections:
        err(f'official minimum language missing: {need}')

# Official Appendix F key set; review standards require keys complete and
# name/descript non-empty (our policy: all five non-empty in every node).
required_keys = ['name', 'auth', 'descript', 'release_note', 'important']
for chunk in lang.split('[')[1:]:
    sec = chunk.split(']', 1)[0]
    body = chunk.split(']', 1)[1]
    kv = dict(re.findall(r'^([a-z_]+) = "(.*)"$', body, re.M))
    for key in required_keys:
        if key not in kv:
            err(f'lang [{sec}] missing key: {key}')
        elif not kv[key].strip():
            err(f'lang [{sec}] empty value: {key}')
lang_auths = set(re.findall(r'^auth = "(.*)"$', lang, re.M))
for a in lang_auths:
    if a != 'Nous Research':
        err(f'lang auth unexpected: {a!r} (expected Nous Research & nesquena)')
if len(lang_auths) != 1:
    err('lang auth not uniform across sections')

blocks = re.split(r'^\[[a-z]{2}-[a-z]{2}\]$', lang, flags=re.M)[1:]
keys_needed = ['name', 'auth', 'descript', 'release_note', 'important']
auths = set()
for name, block in zip(sections, blocks):
    for k in keys_needed:
        m = re.search(rf'^{k} = "(.*)"$', block, re.M)
        if not m or not m.group(1).strip():
            err(f'[{name}] key {k} missing or empty')
        if k == 'auth' and m:
            auths.add(m.group(1).strip())
if auths != {cfg['publisher']}:
    notes.append(f'lang auth {auths} != config.ini publisher '
                 f'"{cfg["publisher"]}" (expected: auth credits upstream '
                 f'authors, publisher is the packager)')

# --- icon ----------------------------------------------------------------
icon = os.path.join(A, 'hermesagent.svg')
if cfg['icon'] != '/images/icons/hermesagent.svg':
    err('config.ini icon path mismatch')
svg = open(icon, encoding='utf-8').read()
if '<svg' not in svg or 'viewBox' not in svg:
    err('icon is not a valid SVG with viewBox')

# --- lifecycle / unit / controls ----------------------------------------
net_re = re.compile(r'^[^#]*\b(apt(-get)? install|pip3? install|curl|wget)\b', re.M)
for script in ['postinst', 'prerm', 'postrm', 'data-postinst']:
    s = open(os.path.join(T, script), encoding='utf-8').read()
    if '\r\n' in s:
        err(f'{script}: CRLF endings')
    if net_re.search(s):
        err(f'{script}: network operation detected (official red line F-15-1)')
unit = open(os.path.join(T, 'hermesagent.service'), encoding='utf-8').read()
for must in ['User=hermesagent', 'Group=hermesagent',
             'StartLimitIntervalSec=',
             'ProtectSystem=strict']:
    if must not in unit:
        err(f'systemd unit missing: {must}')
if 'StartLimitIntervalSec=0' not in unit and 'StartLimitBurst=' not in unit:
    # Either unlimited retries (interval=0) or an explicit burst cap.
    err('systemd unit missing: StartLimitBurst= (or StartLimitIntervalSec=0)')
if 'MemoryDenyWriteExecute=true' in unit:
    err('unit sets MemoryDenyWriteExecute; Python/ML runtime needs W+X')
for ctl in ['data-control.in', 'service-control.in', 'manual-control.in']:
    c = open(os.path.join(T, ctl), encoding='utf-8').read()
    if '__VERSION__' not in c:
        err(f'{ctl}: missing __VERSION__ placeholder')

# --- payload pins / wheels / agent reqs ---------------------------------
P = os.path.join(os.path.dirname(T), 'payload')
SHA_RE_STR = r'^[0-9a-f]{64}$'
pins = json.load(open(os.path.join(P, 'component-pins.json'), encoding='utf-8'))
for arch in ('x86_64', 'aarch64'):
    t = pins['runtime']['targets'][arch]
    sha = t.get('sha256')
    if sha is None:
        print(f'PENDING: runtime {arch} sha256 not yet verified')
    elif not re.match(SHA_RE_STR, sha):
        err(f'runtime {arch} sha256 malformed')
if pins['agent'].get('sha256') is None:
    print('PENDING: agent sha256 not yet verified')
wlock = json.load(open(os.path.join(P, 'wheels.lock'), encoding='utf-8'))
for name, p in wlock['packages'].items():
    for arch in ('x86_64', 'aarch64'):
        w = p['wheels'].get(arch)
        if not w:
            err(f'wheels.lock: {name} missing wheel for {arch}')
            continue
        # pure-python universal wheels (py3-none-any) are arch-independent
        # and legal for both trees; platform wheels must be manylinux.
        if ('manylinux' not in w['file'] and 'py3-none-any' not in w['file']) \
                or not re.match(SHA_RE_STR, w['sha256']):
            err(f'wheels.lock: {name} {arch} wheel malformed')
reqs = open(os.path.join(P, 'agent-core-requirements.txt'), encoding='utf-8').read()
if '--hash=sha256:' not in reqs:
    err('agent-core-requirements.txt lacks sha256 hashes')
if re.search(r'^hermes-agent==', reqs, re.M):
    err('agent-core-requirements.txt must not pin the agent itself')

# --- bootstrap + launcher wiring ----------------------------------------
boot = os.path.join(T, 'hermesagent-bootstrap.py.in')
import py_compile, tempfile
try:
    py_compile.compile(boot, cfile=os.path.join(tempfile.gettempdir(), 'hwui-boot.pyc'),
                       doraise=True)
except py_compile.PyCompileError as e:
    err(f'bootstrap does not compile: {e}')
if '\r\n' in open(boot, 'rb').read().decode('utf-8', 'replace'):
    err('bootstrap has CRLF endings')
launcher = open(os.path.join(T, 'hermesagent.in'), encoding='utf-8').read()
for must in ['hermesagent-bootstrap --check', 'venvs/app/bin/python3',
             'HERMES_WEBUI_AGENT_DIR']:
    if must.split(' --')[0] not in launcher:
        err(f'launcher missing: {must}')
mft = open(os.path.join(T, 'components.json.in'), encoding='utf-8').read()
for ph in ['__VERSION__', '__RT_SHA__', '__AG_SHA__']:
    if ph not in mft:
        err(f'components.json.in missing placeholder {ph}')

for n in notes:
    print(f'NOTE: {n}')
if errors:
    for e in errors:
        print(f'FAIL: {e}')
    sys.exit(1)
print(f'OK: config.ini fields, {len(sections)} lang sections, icon, '
      'lifecycle scripts, systemd unit, controls all valid.')
PY
