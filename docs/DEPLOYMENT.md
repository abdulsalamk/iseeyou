# Hosted unsigned builds and a user-invoked Mac bridge

Development pushes to `codex/**`, main pushes, PRs targeting main, and manual dispatch build unsigned **physical iPhone** artifacts on GitHub-hosted macOS. Development does not require a Mac connection. Linux runs bridge contract tests. No self-hosted runner, inbound listener, LaunchAgent, simulator, local compilation, or Apple credential in GitHub/cloud is used.

The Mac runs a manually reviewed copy of `scripts/deploy/bridge.py` outside the checkout. It never pulls/runs repository scripts or executes artifact content on the Mac. A foreground `follow` command checks local prerequisites, posts exact-commit readiness, waits for that commit to become main, downloads its successful hosted main-push artifact, signs and installs it. It exits after installation. Do not automate execution of development/PR versions of this bridge; review updates and copy explicitly. The installed app itself is trusted main code and will execute on the phone if opened.

## Current evidence and limits

Linux contract tests use mocks, not a Mac/keychain/iPhone. No live deployment has been performed by this task. After the allowlist update, authenticated GitHub API read access succeeded as `abdulsalamk` and repository metadata reports push/admin permissions. This does not prove commit-status write authorization; no readiness status was fabricated from Linux. The user reports 47 previous device UnitChecks passed; these are not deployment checks. Recognition remains unresolved (closed door/cabinet confusion). App/model sources, stored distance correction, and no-beep behavior are unchanged. Installation replaces the same bundle ID without uninstalling or erasing data; back up irreplaceable device data separately. The bridge neither launches the app nor calibrates it.

The user manually dispatched baseline `5ca9722` via GitHub UI, run `39842724144`. That existing manual build is development validation only; the bridge intentionally refuses workflow_dispatch artifacts for installation. Only a successful `push` build of exact current main, correct numeric repository ID, expected workflow path, matching run/attempt, manifest/hash, archive structure and bundle ID can deploy. This does not substitute for branch protection or review of code merged to main. A malicious trusted-main workflow could itself produce malicious code. Only trusted maintainers should write main, readiness statuses or the bridge.

## One-time Mac connection (manual, no agent installation)

Use the existing Mac with Xcode command-line tools including `devicectl`, Python 3.11+, Git, and GitHub CLI `gh`. A full Xcode installation supplies device/signing tools; no `xcodebuild` runs locally. Keep the existing paired physical iPhone connected, Developer Mode enabled, trusted and unlocked. An online Mac is insufficient: readiness makes a live `devicectl device info details` query and checks a matching, nonexpired development profile/certificate. This cannot guarantee the phone stays connected/unlocked or the keychain permits later signing. All failures stop deployment.

1. Fetch the reviewed development commit into your existing Mac checkout using ordinary Git. Do not reset or discard local changes. Review `scripts/deploy/bridge.py`, both workflows, and tests. Copy the reviewed bridge into a user-controlled directory outside any repo, for example:

   ```sh
   mkdir -p "$HOME/.local/share/iseeyou-deploy" "$HOME/.config/iseeyou-deploy"
   chmod 700 "$HOME/.local/share/iseeyou-deploy" "$HOME/.config/iseeyou-deploy"
   # Run from the reviewed checkout; inspect this file before copying.
   cp scripts/deploy/bridge.py "$HOME/.local/share/iseeyou-deploy/bridge.py"
   chmod 600 "$HOME/.local/share/iseeyou-deploy/bridge.py"
   ```

2. Discover local prerequisites yourself; do not send their output to cloud/chat:

   ```sh
   xcrun devicectl list devices
   security find-identity -v -p codesigning
   ```

   Find the existing development `.mobileprovision` profile (Xcode may store it in `~/Library/Developer/Xcode/UserData/Provisioning Profiles` or `~/Library/MobileDevice/Provisioning Profiles`). The bridge does **not** create/renew profiles, register devices/App IDs, log into Apple, modify keychains, or request certificates. If no valid matching profile/private key exists, use the Mac's existing Apple/Xcode provisioning UI separately; do not fall back to compilation. Profile must include the physical phone UDID and selected certificate, support `com.iseeyou.research`, and match your team. Prefer an explicit App ID profile. App extensions are rejected because they require separate provisioning. iOS framework symlinks are rejected; if a future artifact requires them, review and implement safe handling rather than relaxing checks blindly.

3. Create `~/.config/iseeyou-deploy/config.json` locally, mode `600`. These personal values stay on Mac, outside the checkout. Alternatively use ignored `scripts/deploy/.local/config.json`; never commit it.

   ```json
   {
     "device_udid": "YOUR_PHYSICAL_IPHONE_UDID",
     "signing_identity": "40_HEX_CERTIFICATE_SHA1_FROM_SECURITY_FIND_IDENTITY",
     "team_id": "YOUR_TEAM_ID",
     "profile": "/absolute/local/path/development.mobileprovision",
     "bundle_id": "com.iseeyou.research",
     "github_auth": "git-credential"
   }
   ```

   ```sh
   chmod 600 "$HOME/.config/iseeyou-deploy/config.json"
   ```

   `github_auth: git-credential` uses the Mac's existing HTTPS GitHub credential helper via `git credential fill` and passes its password/token **in memory only** to `gh` subprocesses. No token is printed, written to disk, put in command arguments or sent to cloud. Never run `git credential fill` manually with output visible, shell tracing, or debug logging. The helper itself is existing Mac configuration; this bridge does not install or modify it. If the helper has no credential, stop; do not invent one. Alternatively choose `github_auth: gh` to reuse existing `gh` authentication. A Git credential can lack API permissions even when clone/push works.

   Required GitHub abilities: repository metadata/content read, Actions runs/artifacts read, and commit statuses write for readiness. For a fine-grained local token, limit to this repository, Contents read, Actions read, Commit statuses write; classic tokens may be broader. Do not create/register access as part of cloud setup. Cloud promotion separately requires API read and Git main push authorization. The status author returned by GitHub must be the expected Mac account (`--mac-actor`); it may be the same account as cloud, so status attribution is not cryptographic hardware attestation. Anyone with that credential could spoof readiness. Use only trusted maintainers/credentials; no public-PR code or runner gets them.

## Exact next connection step

After reviewing/copying the bridge and filling local config, start this foreground command **on the Mac**, replacing the full SHA with the pushed deployment-development commit printed by the cloud task:

```sh
python3 "$HOME/.local/share/iseeyou-deploy/bridge.py" follow \
  --config "$HOME/.config/iseeyou-deploy/config.json" FULL_DEVELOPMENT_SHA
```

Leave it running. It posts pending then success/failure readiness and waits for the exact SHA to be main (default 30 minutes). Readiness expires in **five minutes** and is never renewed automatically; rerun if a promotion has not occurred in that window. Tell the cloud task only that readiness succeeded and your GitHub status-author login, not any personal device/signing details. This command authorizes a later install after main promotion; do not start it until you intend that. To test readiness alone without waiting/installing, use `ready` instead of `follow` with the same arguments.

## Promotion gate (not run by this task)

With explicit user confirmation that the Mac bridge is ready, from the cloud checkout:

```sh
python3 scripts/deploy/bridge.py gate FULL_DEVELOPMENT_SHA --mac-actor EXPECTED_GITHUB_LOGIN
# Only when separately authorized to change main:
python3 scripts/deploy/bridge.py promote FULL_DEVELOPMENT_SHA \
  --mac-actor EXPECTED_GITHUB_LOGIN --confirm-main
```

`gate`/`promote` use API status on the exact full candidate SHA, require newest readiness success by the specified actor, and refuse if missing/failed/pending/future-dated/older than 300 seconds or if API access is unavailable. Promotion requires a clean checkout, an ancestor main, and an exact remote-main lease; it permits only a fast-forward of main to the approved candidate, with no synthetic merge SHA. It does not bypass GitHub protection. The lease guards a concurrent main update; ancestry is checked before push, so no divergent main history is overwritten. A fresh check observes readiness at one instant; no network design can guarantee the Mac stays online afterward.

Direct manual main pushes/merges can bypass this client-side gate. A server-side rule is **not configured by this task**. Before relying on enforcement for all writers, a trusted owner must configure main protection/rulesets to require `deployment/mac-ready` and appropriate review/checks, and restrict bypass/main writes. Protect against status spoofing according to your available GitHub plan/actor controls. Cloud development pushes remain possible with the Mac offline. Conventional GitHub merge commits/squash commits change SHA and are not supported by this exact-SHA promotion path.

The Mac then waits for hosted build success (up to another 30 minutes), verifies provenance and SHA-256, rejects archive traversal/symlinks, signs nested frameworks/dylibs before the app with the local profile/identity, verifies signatures, rechecks main and installs with `xcrun devicectl device install app`. It never uninstalls, launches, calibrates, compiles locally or uses a simulator. Capture the hosted run URL, deployed SHA and successful install result for actual end-to-end evidence. Verify on-device speech/calibration separately without recalibrating. If install fails, fix the local prerequisite and rerun `deploy --config ...` to deploy **current trusted main**; no unsigned development/manual/PR artifacts are accepted.

## Offline checks and references

```sh
python3 -m unittest discover -s tests -v
python3 scripts/deploy/bridge.py --help
git diff --check
```

GitHub REST documentation below was read after the user allowed `api.github.com` and `docs.github.com`. API metadata, workflow-run fields and local-token permission requirements were checked. Action commit pins were verified against GitHub tag refs. Other CLI/Apple references are provided for Mac-side verification; those sites were not added to cloud network access:

- https://docs.github.com/en/rest/commits/statuses
- https://docs.github.com/en/rest/actions/workflow-runs
- https://cli.github.com/manual/gh_run_download
- https://git-scm.com/docs/git-credential
- https://developer.apple.com/documentation/xcode/installing-and-managing-simulator-and-device-apps
- Local Mac authoritative command help: `xcrun devicectl help`, `xcrun devicectl device install app --help`, `codesign --help`, `security help cms`.
