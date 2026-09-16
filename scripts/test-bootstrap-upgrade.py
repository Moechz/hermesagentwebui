#!/usr/bin/env python3
"""Test plan_sections() — the D-014 upgrade/convergence decider.

Imports the bootstrap template verbatim, points STATE/APP_HOME at temp
dirs with marker files, and asserts the diff between provisioned state
and the deb's pins for: fresh installs, fully-current fast path, each
single pin change (runtime / agent / wheels / core lock / extras lock),
destroyed artifacts, and the legacy -006 state migration.

Stdlib only. Use: python3 scripts/test-bootstrap-upgrade.py
"""
import importlib
import json
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
TEMPLATE = os.path.join(HERE, "..", "packaging", "templates",
                        "hermesagent-bootstrap.py.in")

R1 = "r1" * 32   # runtime sha, current
R2 = "r2" * 32   # runtime sha, changed
A1 = "a1" * 32   # agent sha, current
A2 = "a2" * 32   # agent sha, changed

ALL = ["runtime", "app_venv", "agent_src", "agent_deps",
       "lazy_extras", "agent_editable"]


def load_bootstrap(tmp):
    mod_path = os.path.join(tmp, "boot.py")
    shutil.copy(TEMPLATE, mod_path)
    sys.path.insert(0, tmp)
    boot = importlib.import_module("boot")
    state = os.path.join(tmp, "state")
    apphome = os.path.join(tmp, "apphome")
    boot.STATE = state
    boot.APP_HOME = apphome
    for d in ("runtime/python/bin", "venvs/app/bin",
              "hermes/hermes-agent", "bootstrap"):
        os.makedirs(os.path.join(state, d), exist_ok=True)
    open(os.path.join(state, "runtime/python/bin/python3"), "w").close()
    open(os.path.join(state, "venvs/app/bin/pip"), "w").close()
    for d in ("wheels", "agent"):
        os.makedirs(os.path.join(apphome, d), exist_ok=True)
    write_lock(boot, wheels="w1", core="c1", extras="e1")
    return boot


def write_lock(boot, wheels, core, extras):
    open(os.path.join(boot.APP_HOME, "wheels/requirements.txt"), "w").write(wheels)
    open(os.path.join(boot.APP_HOME, "agent/agent-core-requirements.txt"),
         "w").write(core)
    open(os.path.join(boot.APP_HOME, "agent/lazy-extras.lock"), "w").write(extras)


def manifest(rt_sha=R1, ag_sha=A1):
    return {
        "runtime": {"sha256": rt_sha, "dest": "runtime/python"},
        "agent": {"sha256": ag_sha, "dest": "hermes/hermes-agent"},
    }


def fresh_state(boot):
    path = os.path.join(boot.STATE, "bootstrap/state.json")
    # Each scenario starts from a clean slate (State() loads any
    # existing file; marks use merge semantics).
    if os.path.exists(path):
        os.remove(path)
    return boot.State(path)


def mark_current(st, fp):
    st.mark("runtime", sha256=R1)
    st.mark("app_venv", runtime_sha=R1, wheels_sha=fp["wheels_req"])
    st.mark("agent_src", sha256=A1)
    st.mark("agent_deps", req_sha=fp["agent_core_req"])
    st.mark("lazy_extras", req_sha=fp["lazy_extras"])
    st.mark("agent_editable")


def scenario(boot, name, expected, mutate=None, m=None):
    st = fresh_state(boot)
    mark_current(st, boot.deb_fingerprints())  # marks from the OLD deb
    if mutate:
        mutate(st, None)
    # Fresh fingerprints, exactly like a bootstrap run after a deb swap
    fp = boot.deb_fingerprints()
    if m is None:
        m = manifest()
    got = boot.plan_sections(m, st, fp)
    ok = got == expected
    print(f"{'PASS' if ok else 'FAIL'}: {name}\n      got {got}\n      want {expected}")
    if not ok:
        sys.exit(1)


def main():
    tmp = tempfile.mkdtemp(prefix="hwui-upgrade-test-")
    boot = load_bootstrap(tmp)
    fp = boot.deb_fingerprints()

    # 1. nothing provisioned -> everything
    st = fresh_state(boot)
    got = boot.plan_sections(manifest(), st, fp)
    assert got == ALL, got
    print("PASS: fresh install plans all sections")

    # 2. fully current -> fast path (check() true)
    scenario(boot, "fully current -> nothing to do", [])
    st = fresh_state(boot)
    mark_current(st, fp)
    assert boot.check(manifest(), st) is True
    print("PASS: check() true when current")

    # 3. agent pin changed -> agent + editable only (deps lock unchanged)
    scenario(boot, "agent pin changed -> [agent_src, agent_editable]",
             ["agent_src", "agent_editable"], m=manifest(ag_sha=A2))
    st = fresh_state(boot)
    mark_current(st, fp)
    assert boot.check(manifest(ag_sha=A2), st) is False
    print("PASS: check() false when agent pin changed")

    # 4. runtime pin changed -> runtime + venv + deps + extras + editable
    scenario(boot, "runtime pin changed cascades through venv",
             ["runtime", "app_venv", "agent_deps", "lazy_extras",
              "agent_editable"], m=manifest(rt_sha=R2))

    # 5. webui wheels changed -> venv + deps + extras + editable
    def bump_wheels(st_, fp_):
        write_lock(boot, wheels="w2", core="c1", extras="e1")
    scenario(boot, "wheels lock changed -> venv cascade",
             ["app_venv", "agent_deps", "lazy_extras", "agent_editable"],
             mutate=bump_wheels)
    write_lock(boot, wheels="w1", core="c1", extras="e1")
    fp = boot.deb_fingerprints()

    # 6. agent core lock changed -> deps only (editable is unaffected:
    #    it points into the source tree, not at dependency packages)
    def bump_core(st_, fp_):
        write_lock(boot, wheels="w1", core="c2", extras="e1")
    scenario(boot, "core deps lock changed -> [agent_deps]",
             ["agent_deps"], mutate=bump_core)
    write_lock(boot, wheels="w1", core="c1", extras="e1")
    fp = boot.deb_fingerprints()

    # 7. extras lock changed -> extras only
    def bump_extras(st_, fp_):
        write_lock(boot, wheels="w1", core="c1", extras="e2")
    scenario(boot, "extras lock changed -> [lazy_extras]",
             ["lazy_extras"], mutate=bump_extras)
    write_lock(boot, wheels="w1", core="c1", extras="e1")
    fp = boot.deb_fingerprints()

    # 8. runtime binary vanished (matching sha) -> full cascade anyway
    def kill_python(st_, fp_):
        os.remove(os.path.join(boot.STATE, "runtime/python/bin/python3"))
    scenario(boot, "runtime artifact missing cascades",
             ["runtime", "app_venv", "agent_deps", "lazy_extras",
              "agent_editable"], mutate=kill_python)
    open(os.path.join(boot.STATE, "runtime/python/bin/python3"), "w").close()

    # 9. venv pip vanished -> venv cascade
    def kill_pip(st_, fp_):
        os.remove(os.path.join(boot.STATE, "venvs/app/bin/pip"))
    scenario(boot, "venv artifact missing cascades",
             ["app_venv", "agent_deps", "lazy_extras", "agent_editable"],
             mutate=kill_pip)
    open(os.path.join(boot.STATE, "venvs/app/bin/pip"), "w").close()

    # 10. legacy -006 state (marks without fingerprints) -> one-time
    #     migration re-provisions the venv-derived sections only;
    #     runtime and agent tarballs are NOT re-downloaded
    st = fresh_state(boot)
    st.mark("runtime", sha256=R1)
    st.mark("app_venv")
    st.mark("agent_src", sha256=A1)
    st.mark("agent_deps")
    st.mark("lazy_extras")
    st.mark("agent_editable")
    got = boot.plan_sections(manifest(), st, fp)
    want = ["app_venv", "agent_deps", "lazy_extras", "agent_editable"]
    assert got == want, got
    print("PASS: legacy -006 state migrates without re-downloading components")

    shutil.rmtree(tmp, ignore_errors=True)
    print("OK: all upgrade-planning scenarios passed")


if __name__ == "__main__":
    main()
