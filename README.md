# hermes-agent-webui (TOS packaging)

Packages the upstream [hermes-webui](https://github.com/nesquena/hermes-webui)
(a Python + vanilla-JS web interface for the Hermes Agent) as a **TerraMaster
TOS 7 application** (Deb package, App Center install), targeting publication
to the official TerraMaster App Store.

This repository is a **packaging/adaptation layer**: it does not fork or
rewrite upstream source. Upstream lives as a nested, ignored clone under
`upstream/hermes-webui/` and is pinned to a release tag.

Since packaging seq -010 the deb is **fully offline** (D-015, store
rule S8): the Python runtime, agent source and every dependency wheel
ship inside the package (~250MB per arch) and no script in the deb
performs any network operation.

TOS app identity (renamed 2026-09-16, seq -008): app id
`hermesagent`, display name **Hermes Agent**, publisher Moechz,
developer credit (lang `auth`) "Nous Research & nesquena" (the two
upstream authors; co-credit since seq -009). Earlier packaging
iterations used the id `hermeswebui`.

## Layout

```text
AGENTS.md / HANDOFF.md     session/handoff entry points (read first)
upstream/hermes-webui/     pinned upstream clone (tag exp-v0.52.302, untracked)
packaging/templates/       TOS metadata, systemd unit, lifecycle scripts, controls
packaging/payload/         component pins, locked wheels/requirements, bootstrap template
packaging/assets/          app icon (hermesagent.svg) + store PNGs
scripts/                   build / validate / manifest automation
docs/                      TASK_STATE / REQUIREMENTS / DESIGN_DECISIONS / CHANGELOG
                           + official TOS developer docs mirror (docs/official/)
dist/                      build artifacts (generated, never committed)
```

## Quick start

```bash
./scripts/validate-package.sh     # official-rule checks over templates (macOS ok)
./scripts/build-package.sh        # stage dual-arch trees; version from component-pins.json
                                  # (dpkg-deb itself runs on Linux only)
```

Debian control/package versions and the app's runtime version all track the
pinned upstream release tag (`exp-v0.52.302` → package version `0.52.302`,
decision D-012). The build refuses to run unless the upstream clone sits
exactly on the pinned tag.

## Status

`0.52.302` (matches upstream tag exp-v0.52.302). Payload staging, first-start
bootstrap, and an end-to-end device validation (install → bootstrap → server
on 0.0.0.0:8787) are complete on an x86_64 TOS 7 device. Remaining before
store submission: on-device App Center registration check for the External
Open (new tab) launch mode, Release asset upload (needs token), aarch64
build, uninstall/purge semantics. See `docs/TASK_STATE.md` for details.
