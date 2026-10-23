# Hosted unsigned builds and persistent Mac deployment

Pushes to `codex/**` and `main`, PRs targeting main, and manual dispatch build unsigned physical-iPhone artifacts on GitHub-hosted macOS. Development works with the Mac offline. Hosted Linux runs bridge contract tests. No self-hosted runner, inbound listener, simulator, local Mac compilation, or Apple credential in cloud is needed.

The Mac runs a reviewed, fixed copy of `scripts/deploy/bridge.py` **outside the checkout**, optionally as a user LaunchAgent. It never updates itself or executes scripts from checkout/artifacts. Updating the bridge requires another explicit review/copy. `watch` responds to fresh cloud readiness requests and automatically installs new trusted-main artifacts. It does not require a manual relaunch per release.

## Readiness and promotion protocol

1. Cloud `request` (readiness test only) or authorized `promote` posts `deployment/request-ready`, state pending, with a random nonce on the **exact current remote `codex/meta-glasses` SHA**. Requests expire in 120 seconds. Cloud polls for at most 90 seconds by default (configurable 1–120).
2. The watcher only answers requests by `cloud_actor` in its private Mac config. It checks local signing prerequisites and actual device JSON, then posts `deployment/mac-ready` success/failure with the same nonce. It posts only for a new request or readiness state transition, not for each poll. A device that resumes within the request lifetime can transition from failure to success. Old, unsolicited, malformed or wrong-author requests are ignored.
3. The cloud gate requires the latest response by `--mac-actor`, newer than this request, matching nonce, fresh (120 seconds), and successful. The request must be by the cloud's authenticated actor. Missing API access, sleeping/offline Mac, stale response, wrong SHA/actor/nonce, or timeout prevents promotion. A new dev tip invalidates the request. `promote` makes a new request automatically; an old success cannot authorize it.
4. After another gate check, promotion fast-forwards main to that exact SHA, checking old-main ancestry and using an exact remote-main lease against concurrent changes. No squash/merge commit changes the approved SHA. No main push is performed by the readiness-only `request` command.

`devicectl` exit 0 alone is **not** readiness: details can be cached. The bridge parses a temporary `--json-output` file and requires `result.hardwareProperties.reality == physical`, `connectionProperties.pairingState == paired`, `connectionProperties.tunnelState == connected`, `deviceProperties.bootState == booted`, and `developerModeStatus == enabled`. Where supplied, `result.properties.connection.state` must be connected. It also queries lockState JSON: supplied `passcodeRequired` must be false and `unlockedSinceBoot` true. Unknown required connection fields fail closed. Lock-query failure also fails closed; missing optional lock fields are not proof of unlock. This is an observation at check time, never a guarantee the phone remains connected/unlocked. Preflight runs again before signing and installation.

Anyone with the trusted account's status-write credential could spoof its status: this is not hardware attestation. Only trusted maintainers/credentials may write main or readiness statuses. No public-PR code receives Mac credentials. Direct manual main pushes bypass this client gate. Server branch protection/rulesets, review requirements and bypass restrictions must be configured separately by the owner if enforcement for every writer is needed; this task does not register/change them. Requiring a status alone on GitHub does not enforce nonce freshness; use the reviewed promotion command for that.

## Automatic deployment and private state

On its first successful poll, `watch` durably records and **skips existing main**, even if that commit has an artifact. It answers readiness requests without installing that baseline. Each later main SHA is eligible only for a successful `push` build of the expected workflow in numeric repository `1427983832`, with matching main SHA, run/attempt, manifest/hash, safe archive paths and bundle ID. PR, fork, development and workflow_dispatch artifacts cannot deploy.

The watcher waits through pending builds and retries transient API, device, download, signing and install failures on subsequent polls/resume. Artifact download has a separate configurable timeout **default 1800 seconds, minimum 1800** (`download_timeout_seconds`), so slow Mac downloads are not killed by the ordinary 120-second subprocess limit. A download blocks that watcher iteration; readiness requests during a long download can time out safely. No readiness expires into automatic permission to merge.

After success, private mode-600 state records `last_installed`; unchanged main is not repeatedly installed, including across restarts. A per-user file lock prevents parallel watchers using the same state. State writes are atomic. Do not delete/reset state to fix a transient error: that would re-baseline and skip the current pending release. A crash after successful install but before state persistence can cause one reinstall of the same SHA; installation is retryable, not transactionally exactly-once. With multiple new main commits while offline, it deploys current main rather than replaying superseded releases. Log messages exclude CLI stderr, signed URLs, UDIDs, identities, profiles and credentials.

Artifacts are data only on Mac. ZIP traversal, symlinks, special files and duplicate paths are rejected. The bridge signs nested frameworks/dylibs first, then the app with local profile/entitlements, verifies signatures, rechecks current main and live device readiness, and uses `devicectl device install app`. It never uninstalls, launches the app, recalibrates, exports models, compiles locally or runs a simulator. The installed iPhone app is trusted-main code and executes if opened. Installation preserves the existing bundle identifier `com.iseeyou.research` and does not erase its container; back up irreplaceable data separately.

## One-time Mac wiring (coordinator/user only)

No agent is installed or registered by the cloud task. Use existing Xcode/device tools, Python 3.11+, and `/opt/homebrew/bin/gh` with existing keyring authentication. A user LaunchAgent runs while that user is logged in, resumes after sleep and retries; it cannot run while Mac is powered off/logged out or bypass an unavailable/locked signing keychain. Keep the paired physical iPhone connected, trusted, Developer Mode enabled and unlocked when necessary.

From a **reviewed** checkout at the final pushed development revision, copy only the reviewed bridge outside the repository:

```sh
mkdir -p "$HOME/.local/share/iseeyou-deploy" "$HOME/.config/iseeyou-deploy" \
  "$HOME/.local/state/iseeyou-deploy" "$HOME/Library/LaunchAgents"
chmod 700 "$HOME/.local/share/iseeyou-deploy" "$HOME/.config/iseeyou-deploy" \
  "$HOME/.local/state/iseeyou-deploy"
cp scripts/deploy/bridge.py "$HOME/.local/share/iseeyou-deploy/bridge.py"
chmod 600 "$HOME/.local/share/iseeyou-deploy/bridge.py"
```

Preserve the already-prepared private `~/.config/iseeyou-deploy/config.json`; add the non-secret options below. Do not upload its personal values. Alternatively keep config under ignored `scripts/deploy/.local/`. Example structure only:

```json
{
  "device_udid": "LOCAL_PHYSICAL_IPHONE_UDID",
  "signing_identity": "LOCAL_40_HEX_CERTIFICATE_SHA1",
  "team_id": "LOCAL_TEAM_ID",
  "profile": "/absolute/local/path/development.mobileprovision",
  "bundle_id": "com.iseeyou.research",
  "github_auth": "gh",
  "cloud_actor": "abdulsalamk",
  "download_timeout_seconds": 3600
}
```

```sh
chmod 600 "$HOME/.config/iseeyou-deploy/config.json"
```

No credential export is needed with `github_auth: gh`. The existing Mac GitHub identity needs metadata/Contents read, Actions read, and Commit statuses write. Cloud needs these plus Git main push permission. Git push alone does not establish API/status-write capability. Optional `github_auth: git-credential` reads the existing Mac HTTPS credential helper **in memory only**, passing it to `gh` subprocess environment; it does not print/store it or change helpers. Never run helper commands with output visible or enable shell/API debug logging. No new credential or account registration is performed.

The existing local certificate/private key and nonexpired profile must match the app, team and physical phone UDID; the certificate must be listed in the profile. Discover these locally with `security find-identity -v -p codesigning` and Xcode's existing provisioning UI; do not send output to cloud/chat. Common profile directories are `~/Library/Developer/Xcode/UserData/Provisioning Profiles` and `~/Library/MobileDevice/Provisioning Profiles`. The bridge does not renew profiles, register devices/App IDs, log into Apple or unlock keychains. If provisioning is missing/expired, fix it locally through supported Apple tooling without a compilation fallback. App extensions require separate profiles and are rejected; iOS framework symlinks are also rejected rather than silently trusted.

First test the watcher in the foreground; its initial poll establishes the skipped-main baseline:

```sh
PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" python3 \
  "$HOME/.local/share/iseeyou-deploy/bridge.py" watch \
  --config "$HOME/.config/iseeyou-deploy/config.json" \
  --state "$HOME/.local/state/iseeyou-deploy/state.json"
```

The coordinator can then run the cloud readiness-only command below. Stop the foreground watcher before starting the LaunchAgent; both use the same state and lock.

Review `scripts/deploy/com.iseeyou.deploy.plist.in` and `render_agent.py`. The template includes `/opt/homebrew/bin` in PATH, mode-077 umask, user-controlled log/state paths, `RunAtLoad`, `KeepAlive`, and a 30-second restart throttle. Rendering creates a plist but does **not** register/start it; refuses to overwrite an existing plist. Use the same Python 3.11+ interpreter that passed the foreground test:

```sh
python3 scripts/deploy/render_agent.py \
  --output "$HOME/Library/LaunchAgents/com.iseeyou.deploy.plist"
plutil -lint "$HOME/Library/LaunchAgents/com.iseeyou.deploy.plist"
# User/coordinator only, after reviewing the rendered file:
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.iseeyou.deploy.plist"
launchctl print "gui/$(id -u)/com.iseeyou.deploy"
```

To stop/unregister it later (preserves private state):

```sh
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.iseeyou.deploy.plist"
```

Do not configure auto-updating checkout scripts, a self-hosted runner, public network access or exported Apple/GitHub secrets. Keep logs private; use user log rotation if running indefinitely.

## Cloud connection test and later authorized promotion

After the coordinator starts the reviewed watcher, test without merging:

```sh
python3 scripts/deploy/bridge.py request FULL_CURRENT_DEVELOPMENT_SHA \
  --mac-actor abdulsalamk --wait-seconds 90
```

Only after explicit authorization to promote:

```sh
python3 scripts/deploy/bridge.py promote FULL_CURRENT_DEVELOPMENT_SHA \
  --mac-actor abdulsalamk --wait-seconds 90 --confirm-main
```

This makes a **new** nonce-bound readiness request, waits bounded time and gates again before touching main. The watcher then installs the successful hosted main-push artifact automatically, including after sleep/resume. Capture the main SHA, hosted run URL and successful real install result for end-to-end evidence. `deploy --config ...` remains an explicit manual recovery command for current trusted main, not a fallback build path.

## Evidence, tests and references

Linux tests mock Apple tools, GitHub and device operations. They include cached/offline exit-0 details, device properties, request freshness/author/nonce, superseded SHA, bounded offline wait/no push, initial-main skip, retries/private state/deduplication, archive safety and signing/install order. No live Mac signing/install or LaunchAgent registration has been performed by the cloud task. Previous 47 device UnitChecks and baseline manual hosted build `39842724144` are prior evidence, not a test of this new bridge. Development Git push/API reads work; Mac status-write readiness remains to be verified live.

App/model code, calibration and no-beep behavior remain unchanged; closed-door/cabinet recognition is unresolved. Environment repository bindings are never changed by this pipeline.

```sh
python3 -m unittest discover -s tests -v
python3 scripts/deploy/bridge.py --help
git diff --check
```

GitHub REST documentation was read via the two user-allowed domains; no additional domains were added. Artifact downloads from cloud may be denied at GitHub's blob-storage host; Mac download connectivity is independently required. References: [statuses](https://docs.github.com/en/rest/commits/statuses), [workflow runs](https://docs.github.com/en/rest/actions/workflow-runs), [artifact download](https://cli.github.com/manual/gh_run_download). Authoritative local Mac help: `xcrun devicectl help`, `codesign --help`, `security help cms`.
