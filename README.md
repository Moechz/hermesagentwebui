# hermes-agent-webui (TOS packaging)

Packages the upstream [hermes-webui](https://github.com/nesquena/hermes-webui)
(a Python + vanilla-JS web interface for the
[Hermes Agent](https://github.com/NousResearch/hermes-agent)) as a
**TerraMaster TOS 7 application** (Deb package, App Center install),
targeting publication to the official TerraMaster App Store.

This repository is a **packaging/adaptation layer**: it does not fork or
rewrite upstream source. Upstream lives as a nested, ignored clone under
`upstream/hermes-webui/` and is pinned to a release tag.

The produced deb is **fully offline**: the portable Python runtime, the
agent source and every dependency wheel ship inside the package
(~250MB per arch); no script in the deb performs any network operation,
so it installs and provisions on devices without internet access.

TOS app identity: app id `hermesagent`, display name **Hermes Agent**,
publisher Moechz, developer credit (lang `auth`)
"Nous Research & nesquena" (the upstream authors of the agent and the
webui respectively).

## Binary provenance & auditability

The offline bundle ships prebuilt artifacts. Every one of them is
pinned by name + size + SHA-256 in this repository and fetched from its
official origin at build time; nothing is built from unverified
sources, and nothing is fetched at install time:

| Artifact | Source | Pin |
|---|---|---|
| CPython runtime (python-build-standalone) | [astral-sh/python-build-standalone](https://github.com/astral-sh/python-build-standalone) releases | `packaging/payload/component-pins.json` |
| Hermes Agent source | [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent) release tarball (plain source) | same |
| WebUI source | [nesquena/hermes-webui](https://github.com/nesquena/hermes-webui) release tag (plain source) | same |
| Python wheels (webui + agent deps) | PyPI (`files.pythonhosted.org`), installed on-device with `pip --no-index --require-hashes` | `packaging/payload/wheels.lock`, `agent-core-requirements.txt`, `lazy-extras.lock` |
| Build tools (setuptools/wheel) | PyPI | `packaging/payload/build-tools.lock` |

All install-time integrity checks are enforced again on the device by
the first-start bootstrap, which refuses any payload whose size or
SHA-256 differs from the pinned manifest.

## Privacy

All conversations, agent memory, and settings stay on the device
(`HERMES_HOME`). No telemetry, no analytics, no data upload. The app
talks to the network only when the user configures their own model
provider (API key entered during onboarding and stored locally).

## Layout

```text
upstream/hermes-webui/     pinned upstream clone (tag exp-v0.52.302, untracked)
packaging/templates/       TOS metadata, systemd unit, lifecycle scripts, controls
packaging/payload/         component pins, locked wheels/requirements, bootstrap template
packaging/assets/          app icon (hermesagent.svg) + store PNGs
scripts/                   build / validate / manifest automation
dist/                      build artifacts (generated, never committed)
```

## Quick start

```bash
./scripts/validate-package.sh     # official-rule checks over templates (macOS ok)
./scripts/build-package.sh        # stage dual-arch trees; version from component-pins.json
                                  # (dpkg-deb itself runs on Linux only)
```

Debian control/package versions and the app's runtime version all track the
pinned upstream release tag (`exp-v0.52.302` → package version `0.52.302`).
The build refuses to run unless the upstream clone sits exactly on the
pinned tag.

## Status

`0.52.302` (matches upstream tag exp-v0.52.302). Fully offline payload
staging and first-start bootstrap are implemented; install, provisioning
and serving were validated end to end on an x86_64 TOS 7 device.
Remaining before store submission: the aarch64 build (CI) and the store
submission materials.
