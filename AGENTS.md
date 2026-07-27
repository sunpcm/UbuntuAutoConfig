# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## What this is

An Ansible-based Linux environment provisioner with three distinct modes, each with its own security boundary:

- **wsl-bootstrap** — run as root inside WSL2; configures the system, creates/configures a target user.
- **ubuntu-bootstrap** — run over SSH as root on a fresh Ubuntu server; configures the system, creates/configures a target user, optional Docker/Nginx/UFW/SSH hardening.
- **user-only** — run as an ordinary user; touches only that user's `$HOME`, never uses sudo (except an explicit opt-in dependency allowlist), and refuses root.

The README and most docs/prose are in Chinese; keep new user-facing text consistent with that.

## Common commands

```bash
# Full static verification gate (run this before committing any change to ansible/, bin/, scripts/, tests/, install.sh)
./tests/verify-ansible.sh

# Ansible syntax check for a single playbook
ansible-playbook --syntax-check -i 'localhost,' ansible/playbooks/wsl-bootstrap.yml

# Wizard unit tests / installer tests (also invoked by verify-ansible.sh)
python3 tests/test-wizard.py
./tests/test-installer.sh
./tests/test-release.sh

# Lint (matches CI in .github/workflows/env-check.yml)
ansible-lint ansible
yamllint .
ruff check bin/devops-toolkit tests/test-wizard.py
shellcheck install.sh scripts/build-release.sh tests/*.sh bin/*   # skips bin/devops-toolkit (Python)

# Build a release tarball locally (VERSION must match ^v[0-9]+\.[0-9]+\.[0-9]+)
./scripts/build-release.sh v0.1.5 dist

# End-to-end smoke test against a throwaway VM (needs multipass installed)
./tests/multipass-smoke.sh
```

CI (`env-check.yml`) runs the lint suite plus `verify-ansible.sh` against an Ansible-core matrix of **2.12.10 (Python 3.10)** and **2.18.6 (Python 3.12)**. The toolkit must stay compatible with ansible-core ≥ 2.12 — do not use modules/syntax newer than that floor.

## Architecture

Execution flows through four layers; understand which one you're touching:

1. **`install.sh`** — standalone release installer. Downloads the GitHub Release tarball, verifies **both** SHA256 and Sigstore/Cosign identity (pinned `COSIGN_VERSION`, pinned per-arch Cosign hashes), extracts safely, installs immutably under `releases/<version>/` with atomic `current`/launcher symlink swaps. `--user` (below `~/.local`, never escalates) vs `--system` (below `/opt`, requires root). A failed verification never falls back to installing.
2. **`bin/devops-toolkit`** — the Python interactive wizard (the primary UX). Collects choices, writes **only** short-lived mode-`0600` inventory + `extra-vars.json` into a `TemporaryDirectory`, then execs `ansible-playbook`. Passwords are hashed in-memory via `openssl passwd -6` and never persisted; only non-sensitive selections (components, versions, git identity) are remembered in `~/.config/devops-toolkit/wizard-state.json`.
3. **`bin/{wsl,ubuntu,user-only}-bootstrap`, `bin/user-only-remove`** — thin bash wrappers that set `ANSIBLE_CONFIG` and exec the matching playbook with `-e target_user=...`. Use these for CI/automation; the wizard is for humans.
4. **`ansible/playbooks/*.yml` + `ansible/roles/*`** — the actual work. Roles are shared across playbooks and parametrized by playbook-level `vars`.

### Roles and the `user_profile` contract

`user_profile` is invoked by all three playbooks and is parametrized:

- `profile_use_become` — `true` in bootstrap modes (root configures another user), `false` in user-only.
- `profile_target_user` / `profile_target_home` — who to configure and where.

This is why user-only can share the exact same profile logic as root bootstrap without ever escalating. When editing shell/git/tool provisioning, edit `user_profile` once — don't fork per-mode.

Role → playbook wiring: `system_base`, `account_create`, `root_profile`, `user_profile` are core; `firewall`, `ssh_security`, `docker`, `nginx`, `linuxbrew`, `wsl_integration` are gated by `when:` on `all.yml` toggles.

### Central configuration: `ansible/group_vars/all.yml`

Single source of truth for every version, package list, and default toggle. **All upstream sources are pinned to immutable revisions** — Oh My Zsh / Linuxbrew / plugins to 40-char commit SHAs, uv to a version + SHA256 per arch. Repeated runs must stay reproducible and must not silently track upstream branches. When bumping a version, update it here deliberately.

The wizard reads defaults out of this file (e.g. `project_default_version("node_version")`), so keep the `key: "value"` format greppable.

## Security invariants enforced by `tests/verify-ansible.sh`

This script is a **guardrail, not just a syntax check**. It fails the build if any of these regress — treat them as hard constraints when editing:

- No `apt_key:` / `apt_repository:` (deprecated) anywhere in `ansible/`.
- No `curl ... | sh/bash` in Ansible tasks.
- uv downloads must enforce `checksum: "sha256:..."`.
- UFW rules must converge through the managed `firewall_managed_profile_name` profile.
- No `version: master|main` (no branch-following installs); `ohmyzsh_version`/`linuxbrew_version` must be 40-hex commits.
- `ansible.cfg` must keep `host_key_checking = True` and must not set global `become = True`.
- No real-looking SSH public keys committed (use placeholders).
- Archived root Playbooks, `wsl-dev/` and `ubuntu-server/` compatibility assets must not reappear in active paths.

## Legacy / archived code — do not use as a source

- Former compatibility shims and root Playbooks now live under `archive/`; they are historical snapshots, not supported entrypoints.
- Everything under `archive/`, including `legacy-implementations/`, is historical reference only; it is not executable and must not be a config source.
- `AcmeConfig/` is a separate, self-contained ACME/TLS certificate helper with its own README.

## Conventions

- The only supported Ansible implementation lives under the top-level `ansible/`. New roles/tasks go there.
- Keep changes idempotent (see `tests/verify-idempotence.sh`); repeated runs must not thrash.
- SSH hardening defaults are deliberately conservative: `disable_root_login` and `disable_password_auth` default to `false`. Only enable them once key-based access is proven.
- Do not weaken any invariant above to make a change "work" — if `verify-ansible.sh` blocks you, the fix is the code, not the guard.
