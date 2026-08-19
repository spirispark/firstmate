# Firstmate self-hosted CI runner

Firstmate's CI runs on the captain's self-hosted Docker runner fleet, the same fleet that already serves the `spirispark/dev-workspace`, `spirispark/shape`, `spirispark/elyze`, `spirispark/lt`, `spirispark/tz`, and `spirispark/umch` repos.
This file is the firstmate-side mirror of the operator surface that lives at `projects/dev-workspace/templates/ci-default/README.md` and links back to it for the shared image, registration, restart, and recovery contract.
The captain-only registration script lives in dev-workspace because firstmate shares the host's fleet registry; firstmate only carries the contract that the workflows depend on.

## Per-repo contract

Every repo on this fleet owns:

- one long-lived Docker container, name `runner-<repo>` (`runner-firstmate` here).
- one label set the workflow must match: `[self-hosted, linux, ARM64]`. A workflow that drops the label set, or that re-introduces a hosted runner label, trips `tests/fm-workflow-self-hosted.test.sh`.
- one `runner_state` volume that persists the GitHub registration credential across container recreation.
- one `runner_work` volume that holds the per-job checkout directory.

The host-side `restart: unless-stopped` policy, the per-repo `.env` file, the bearer-token resolution order, and the `templates/ci-default/check-runners.sh` outage detection all live in dev-workspace and apply to firstmate unchanged.

## Image and label set firstmate uses

- Image: `ci-runner:2.336.0-tools-v3`. Built from `projects/dev-workspace/templates/ci-default/Dockerfile`. The image bakes shellcheck, actionlint, jq, python3+PyYAML, gitleaks, osv-scanner, codex, php, and rsync. Image roll instructions are in `projects/dev-workspace/templates/ci-default/README.md` under "Roll the image version".
- Label set: `self-hosted,linux,ARM64`. The firstmate `.github/workflows/*.yml` files are the only place this label set appears; the workflow files fail closed if any job regresses to a GitHub-hosted runner label.
- Per-repo env file: `~/Library/Application Support/github-runners/firstmate.env`. Written by `register-runner.sh` (captain-only) and consumed by `docker compose` on `up -d`. Mode 0600.

## macos-stock-bash is the lone Linux-incompatible job

Firstmate carries one job that cannot run on the ci-runner Linux container: `macos-stock-bash` in `.github/workflows/ci.yml` invokes `/bin/bash` (which on macOS is the legacy Bash 3.2.57 the fleet-snapshot and bearings consumers exercise). A Linux container cannot provide stock macOS Bash 3.2.57, so the job stays on `macos-latest`. The exception is recorded in that test file's `ALLOWED_HOSTED_KEYS` allow-list so a second offender trips the same test.

## Tools not baked into the ci-runner image

Firstmate's CI installs three tools at runtime because the shared image does not bake them in:

- `tasks-axi` (needed by the portable parallel and serial lanes): installed via `npm install -g tasks-axi`. Node.js is not baked in, so the install step also pulls `nodejs` and `npm` from apt before npm can run.
- `tmux` (needed by the AFK injection e2e tests in the portable serial lane): installed via `apt-get install -y tmux` in the lane's setup step. The serial lane combines the apt-get step with the nodejs install so the lane pays for one apt cache miss.
- Herdr and Treehouse (needed by the `tests-herdr` lane): installed by `bin/fm-install-herdr.sh` and `bin/fm-install-treehouse.sh`. Both already pin a per-architecture asset and SHA-256 (Herdr `herdr-linux-aarch64` SHA-256 `544e0002...`, Treehouse `treehouse-v<pin>-linux-arm64.tar.gz`).

When the shared image eventually bakes these in, the runtime steps become short-circuit no-ops; the apt-get branches test for `command -v` and only install when the binary is missing.

## Register the runner (captain-only)

The captain runs this once per host, after Docker Desktop is running and a GitHub bearer token is in place:

```sh
cd <dev-workspace-checkout>   # the captain's local dev-workspace clone
./templates/ci-default/register-runner.sh firstmate
```

The script writes `~/Library/Application Support/github-runners/firstmate.env` (mode 0600), brings the `runner-firstmate` container up via `docker compose`, and prints the registration-token expiry. Full operator steps, including PAT setup, Docker Desktop's "Start Docker Desktop when you sign in" requirement, and bearer-token resolution order (PAT file then `gh` CLI), live in `projects/dev-workspace/templates/ci-default/README.md` under "One-time setup on this Mac".

The firstmate-side mirror does not duplicate those steps because the contract is identical across repos and the captain-only recovery is owned in one place.

## Recovery

When `templates/ci-default/check-runners.sh` exits non-zero on the captain's host, `runner-firstmate` is in one of three states documented by the script's exit code:

- Exit 1 with one or more `DOWN <name>` lines on stderr: the container is not running. `docker restart runner-firstmate` preserves the registration; the captain owns the timing because it kills in-flight CI on this host.
- Exit 1 with `NO RUNNERS FOUND on this host - the fleet is empty.` on stderr: the container was wiped (a `deregister-runner.sh`, a `docker compose down -v`, or a Docker Desktop "Reset to factory defaults"). Re-run `register-runner.sh firstmate` to mint a fresh registration token.
- Exit 2 with a `check-runners: docker daemon is not reachable.` (or `docker became unreachable during the check.`) on stderr: the Docker VM is down. The 2026-08-12 incidents, which hit every fleet runner in the same minute, are the canonical example; restart Docker Desktop, then `docker restart runner-firstmate` after the daemon answers.

Full recovery rules, the empirical record of the two 2026-08-12 incidents, and the hard rules on what never to run without captain authority, live in `projects/dev-workspace/templates/ci-default/README.md` under "Why `check-runners.sh` exists" and "Hard rules on recovery".

## CI workflow contract tests

`tests/fm-workflow-self-hosted.test.sh` parses every `.github/workflows/*.yml` and `*.yaml` file - under each YAML backend the fleet has (`yq` on the captain's workstation, python3+PyYAML in the ci-runner image) - and asserts:

- every Linux job dispatches to the captain's self-hosted ARM64 runner, carrying all three labels of the set `[self-hosted, linux, ARM64]`; a job that keeps only part of the set is an offender.
- the only allowed GitHub-hosted runner label on this repo is `macos-latest` on `macos-stock-bash`, with `windows-herdr-spike.yml` on `windows-latest` as a manual-dispatch Windows-only spike.
- the allow-list inventory matches the actual hosted-runner usage, so a silently widened allow-list trips the test on review.

A new hosted-runner job, a deleted allow-list entry, or a label-set drift fails CI red.

## Image roll

Image rolls live in dev-workspace's template. The firstmate-side contract is "bump the tag in the `firstmate.env` file, re-up the container, and trust the contract tests to catch a regression". Concrete operator steps are in `projects/dev-workspace/templates/ci-default/README.md` under "Roll the image version" and "Live runners and image rolls".

## Reference

- `projects/dev-workspace/templates/ci-default/README.md`: the single owner of the operator setup, recovery, and image-roll surface that firstmate shares with every other repo on this fleet.
- `projects/dev-workspace/templates/ci-default/Dockerfile`: the single owner of the baked toolchain.
- `bin/fm-install-shellcheck.sh`, `bin/fm-install-herdr.sh`, `bin/fm-install-treehouse.sh`: firstmate-owned install scripts that pin a per-architecture asset and SHA-256.
- `tests/fm-workflow-self-hosted.test.sh`: firstmate-owned contract test that fails closed on a hosted-runner regression.
- `tests/fm-install-shellcheck.test.sh`: firstmate-owned contract test that runs the installer against stubbed download/verify tools and asserts the per-architecture asset, SHA-256 pin, and refusal paths.