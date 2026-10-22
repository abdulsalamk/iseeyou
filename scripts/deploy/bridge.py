#!/usr/bin/env python3
"""Manual, trusted-main-only Mac bridge. No daemon, checkout execution or compilation."""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import zipfile

REPO = 'abdulsalamk/iseeyou'
REPO_ID = 1427983832
CONTEXT = 'deployment/mac-ready'
WORKFLOW = '.github/workflows/ios-build.yml'
ARTIFACT = 'ISeeYou-unsigned-requires-signing'
SHA = re.compile(r'^[0-9a-f]{40}$')
MAC_GITHUB_TOKEN = None


def run(*args, **kwargs):
    if args[0] == 'gh':
        environment = dict(os.environ, GH_HOST='github.com')
        if MAC_GITHUB_TOKEN is not None:
            environment['GH_TOKEN'] = MAC_GITHUB_TOKEN
        kwargs['env'] = environment
    kwargs.setdefault('timeout', 120)
    return subprocess.run(args, check=True, capture_output=True, **kwargs).stdout


def api(path, payload=None):
    args = ['gh', 'api', '--hostname', 'github.com', '-H', 'Accept: application/vnd.github+json', path]
    if payload is not None:
        args += ['--method', 'POST', '--input', '-']
    return json.loads(run(*args, input=None if payload is None else json.dumps(payload).encode()))


def require(condition, message):
    if not condition:
        raise ValueError(message)


def commit(value):
    require(bool(SHA.fullmatch(value)), 'A full 40-character commit SHA is required')
    return value


def repo_check():
    require(api(f'repos/{REPO}')['id'] == REPO_ID, 'Repository identity changed')


def readiness(statuses, actor, now=None):
    """Newest matching context wins, including pending/failure; never reuse old success."""
    now = now or dt.datetime.now(dt.timezone.utc)
    matches = [s for s in statuses if s['context'] == CONTEXT]
    require(bool(matches), 'Mac readiness unknown: no status')
    latest = max(matches, key=lambda s: s['id'])
    age = (now - dt.datetime.fromisoformat(latest['created_at'].replace('Z', '+00:00'))).total_seconds()
    require(latest['creator']['login'] == actor, 'Unexpected readiness status author')
    require(latest['state'] == 'success', 'Mac readiness offline, pending or failed')
    require(0 <= age <= 300, 'Mac readiness expired or has future timestamp')


def gate(sha, actor):
    commit(sha)
    repo_check()
    statuses = api(f'repos/{REPO}/commits/{sha}/statuses?per_page=100')
    readiness(statuses, actor)


def profile_entitlements(profile, bundle, udid, team, now=None):
    now = now or dt.datetime.now(dt.timezone.utc)
    expiry = profile['ExpirationDate']
    if expiry.tzinfo is None:
        expiry = expiry.replace(tzinfo=dt.timezone.utc)
    require(expiry > now, 'Provisioning profile expired')
    require(udid in profile.get('ProvisionedDevices', []), 'iPhone UDID absent from profile')
    require(team in profile.get('TeamIdentifier', []), 'Unexpected signing team')
    ent = dict(profile['Entitlements'])
    require(ent.get('com.apple.developer.team-identifier') == team, 'Profile entitlement team mismatch')
    app_id = ent['application-identifier']
    prefix, _, pattern = app_id.partition('.')
    require(pattern == bundle or (pattern.endswith('*') and bundle.startswith(pattern[:-1])),
            'Bundle ID not permitted by profile')
    ent['application-identifier'] = prefix + '.' + bundle
    ent['keychain-access-groups'] = [g.replace('*', bundle) for g in ent.get('keychain-access-groups', [])]
    require(not any('*' in str(v) for v in ent.values()), 'Unsupported wildcard entitlements; use explicit App ID profile')
    return ent


def mac_preflight(config):
    require(sys.platform == 'darwin', 'Signing/readiness must run on the user Mac')
    require(config['bundle_id'] == 'com.iseeyou.research', 'Use existing installed bundle ID to preserve app data')
    identity = config['signing_identity']
    require(bool(re.fullmatch(r'[A-Fa-f0-9]{40}', identity)), 'Use certificate SHA-1 identity, not a shell expression/name')
    identities = run('security', 'find-identity', '-v', '-p', 'codesigning').decode()
    require(identity.upper() in identities.upper(), 'Signing identity unavailable in Mac keychain')
    # A successful live device query is required; host online alone is insufficient.
    run('xcrun', 'devicectl', 'device', 'info', 'details', '--device', config['device_udid'])
    profile = plistlib.loads(run('security', 'cms', '-D', '-i', config['profile']))
    ent = profile_entitlements(profile, config['bundle_id'], config['device_udid'], config['team_id'])
    cert_hashes = [hashlib.sha1(c).hexdigest().upper() for c in profile['DeveloperCertificates']]
    require(identity.upper() in cert_hashes, 'Signing certificate not included in profile')
    return ent


def post_status(sha, state):
    api(f'repos/{REPO}/statuses/{sha}', {'state': state, 'context': CONTEXT,
        'description': {'pending': 'Checking Mac, iPhone and local signing prerequisites',
                        'success': 'Mac/device/signing checked; readiness expires in 5 minutes',
                        'failure': 'Mac bridge prerequisite check failed'}[state]})


def announce(sha, config):
    commit(sha)
    repo_check()
    post_status(sha, 'pending')
    try:
        mac_preflight(config)
    except Exception:
        post_status(sha, 'failure')
        raise
    post_status(sha, 'success')


def trusted_run(info, sha):
    require(info['repository']['id'] == REPO_ID, 'Wrong artifact repository')
    require(info.get('head_repository', {}).get('id') == REPO_ID, 'Fork build refused')
    require(info['head_sha'] == sha and info['head_branch'] == 'main', 'Artifact is not current main')
    require(info['event'] == 'push', 'Only main push builds may deploy')
    require(info['path'] in (WORKFLOW, WORKFLOW + '@refs/heads/main', WORKFLOW + '@main'),
            'Unexpected build workflow')
    require(info['status'] == 'completed' and info['conclusion'] == 'success', 'Build not successful')


def safe_extract(archive, destination):
    """Reject traversal, links, duplicate entries and zip bombs before writing."""
    with zipfile.ZipFile(archive) as z:
        seen = set()
        total = 0
        for item in z.infolist():
            path = PurePosixPath(item.filename)
            require(not path.is_absolute() and '..' not in path.parts and '\\' not in item.filename,
                    'Unsafe archive path')
            require(path.parts and path.parts[0] == 'ISeeYou.app', 'Unexpected archive root')
            require(str(path) not in seen, 'Duplicate archive path')
            seen.add(str(path))
            mode = item.external_attr >> 16
            require(not stat.S_ISLNK(mode), 'Archive symlinks are forbidden')
            require(not mode or stat.S_IFMT(mode) in (0, stat.S_IFDIR, stat.S_IFREG), 'Special archive entry')
            total += item.file_size
            require(total <= 2_000_000_000, 'Archive exceeds 2 GB limit')
        z.extractall(destination)
        for item in z.infolist():
            path = destination / item.filename
            if not item.is_dir():
                path.chmod((item.external_attr >> 16 & 0o755) or 0o644)


def validate_manifest(manifest, sha, run_id, attempt, archive):
    require(manifest == {'repository_id': REPO_ID, 'sha': sha, 'run_id': str(run_id),
                        'run_attempt': str(attempt), 'sha256': hashlib.sha256(archive.read_bytes()).hexdigest()},
            'Artifact manifest/hash mismatch')


def deploy(config, timeout, expected_sha=None):
    repo_check()
    mac_preflight(config)
    sha = commit(api(f'repos/{REPO}/commits/main')['sha'])
    require(expected_sha is None or sha == expected_sha, 'main changed from approved commit')
    deadline = time.monotonic() + timeout
    while True:
        runs = api(f'repos/{REPO}/actions/workflows/ios-build.yml/runs?branch=main&event=push&head_sha={sha}&per_page=20')['workflow_runs']
        runs = [r for r in runs if r['head_sha'] == sha]
        if runs:
            info = api(f'repos/{REPO}/actions/runs/{max(runs, key=lambda r: r["id"])["id"]}')
            if info['status'] == 'completed':
                trusted_run(info, sha)
                break
        require(time.monotonic() < deadline, 'Timed out waiting for hosted main build')
        time.sleep(15)
    # gh downloads data only; never execute scripts from the artifact or checkout.
    with tempfile.TemporaryDirectory(prefix='iseeyou-deploy-') as folder:
        root = Path(folder)
        run('gh', 'run', 'download', str(info['id']), '--repo', REPO, '--name', ARTIFACT, '--dir', str(root))
        archive = root / 'ISeeYou.app.zip'
        manifest = json.loads((root / 'manifest.json').read_text())
        validate_manifest(manifest, sha, info['id'], info['run_attempt'], archive)
        safe_extract(archive, root)
        app = root / 'ISeeYou.app'
        app_info = plistlib.loads((app / 'Info.plist').read_bytes())
        require(app_info['CFBundleIdentifier'] == config['bundle_id'], 'Unexpected app bundle ID')
        require(app_info.get('CFBundleSupportedPlatforms') == ['iPhoneOS'], 'Physical iPhone build required')
        require(not list(app.rglob('*.appex')), 'App extensions need separate profiles; refusing')
        require(api(f'repos/{REPO}/commits/main')['sha'] == sha, 'main moved; rerun deployment')
        ent = mac_preflight(config)
        shutil.copyfile(config['profile'], app / 'embedded.mobileprovision')
        ent_path = root / 'entitlements.plist'
        ent_path.write_bytes(plistlib.dumps(ent))
        nested = list(app.rglob('*.framework')) + list(app.rglob('*.dylib'))
        for binary in sorted(nested, key=lambda p: len(p.parts), reverse=True):
            run('codesign', '--force', '--sign', config['signing_identity'], '--timestamp=none', str(binary))
        run('codesign', '--force', '--sign', config['signing_identity'], '--timestamp=none',
            '--entitlements', str(ent_path), str(app))
        run('codesign', '--verify', '--deep', '--strict', str(app))
        require(api(f'repos/{REPO}/commits/main')['sha'] == sha, 'main moved before install; rerun')
        run('xcrun', 'devicectl', 'device', 'install', 'app', '--device', config['device_udid'], str(app))
        print(f'Installed trusted main {sha} on configured physical iPhone; no app launch or calibration performed.')


def promote(sha, actor):
    """Optional future promotion: only fast-forward, with exact remote-main lease."""
    commit(sha)
    require(not run('git', 'status', '--porcelain').strip(), 'Working tree must be clean')
    # Explicit GitHub URL prevents a checkout remote from redirecting the push.
    remote = f'https://github.com/{REPO}.git'
    run('git', 'fetch', remote, 'refs/heads/main')
    old = run('git', 'rev-parse', 'FETCH_HEAD').decode().strip()
    run('git', 'merge-base', '--is-ancestor', old, sha)
    gate(sha, actor)
    run('git', 'push', f'--force-with-lease=refs/heads/main:{old}', remote, f'{sha}:refs/heads/main')
    print(f'Fast-forwarded main to {sha}; start/continue Mac follow command to sign/install hosted artifact.')


def configure_github(config):
    # Opt-in, Mac only. Credential helper output remains in process memory.
    global MAC_GITHUB_TOKEN
    mode = config.get('github_auth', 'gh')
    require(mode in ('gh', 'git-credential'), 'github_auth must be gh or git-credential')
    if mode == 'git-credential':
        require(sys.platform == 'darwin', 'Credential-helper access is Mac-only')
        result = run('git', 'credential', 'fill',
                     input=b'protocol=https\nhost=github.com\npath=abdulsalamk/iseeyou.git\n\n',
                     env=dict(os.environ, GIT_TERMINAL_PROMPT='0'))
        fields = dict(line.split('=', 1) for line in result.decode().splitlines() if '=' in line)
        require(bool(fields.get('password')), 'No existing GitHub HTTPS credential available')
        MAC_GITHUB_TOKEN = fields['password']


def load_config(path):
    p = Path(path).expanduser()
    require(stat.S_IMODE(p.stat().st_mode) & 0o077 == 0, 'Mac config must be private: chmod 600')
    config = json.loads(p.read_text())
    require(all(config.get(k) for k in ('device_udid', 'profile', 'team_id', 'signing_identity', 'bundle_id')),
            'Incomplete Mac config')
    config['profile'] = str(Path(config['profile']).expanduser())
    configure_github(config)
    return config


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    for name in ('ready', 'follow'):
        p = sub.add_parser(name)
        p.add_argument('--config', required=True)
        p.add_argument('sha')
        if name == 'follow':
            p.add_argument('--wait-seconds', type=int, default=1800)
    for name in ('gate', 'promote'):
        p = sub.add_parser(name)
        p.add_argument('sha')
        p.add_argument('--mac-actor', required=True)
        if name == 'promote':
            p.add_argument('--confirm-main', action='store_true', required=True)
    p = sub.add_parser('deploy')
    p.add_argument('--config', required=True)
    p.add_argument('--wait-seconds', type=int, default=1800)
    args = parser.parse_args()
    if args.command == 'gate':
        gate(args.sha, args.mac_actor)
        print('Exact-commit Mac readiness valid for this instant; no merge performed.')
    elif args.command == 'promote':
        promote(args.sha, args.mac_actor)
    elif args.command == 'ready':
        announce(args.sha, load_config(args.config))
    elif args.command == 'deploy':
        deploy(load_config(args.config), args.wait_seconds)
    elif args.command == 'follow':
        # User-invoked foreground process. Only wait for the approved SHA to be main.
        config = load_config(args.config)
        sha = commit(args.sha)
        announce(sha, config)
        deadline = time.monotonic() + args.wait_seconds
        while api(f'repos/{REPO}/commits/main')['sha'] != sha:
            require(time.monotonic() < deadline, 'Timed out waiting for exact approved main SHA')
            time.sleep(10)
        deploy(config, args.wait_seconds, expected_sha=sha)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.SubprocessError, zipfile.BadZipFile) as exc:
        # Avoid echoing subprocess output or config/token contents.
        message = str(exc) if isinstance(exc, ValueError) else 'Local command or API failed; inspect prerequisites without logging credentials.'
        print(f'Bridge stopped: {type(exc).__name__}: {message}', file=sys.stderr)
        sys.exit(1)
