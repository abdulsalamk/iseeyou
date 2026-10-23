#!/usr/bin/env python3
"""Trusted-main-only Mac pull/sign/install bridge. No checkout execution or compilation."""
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
import uuid
import fcntl
from contextlib import contextmanager

REPO = 'abdulsalamk/iseeyou'
REPO_ID = 1427983832
CONTEXT = 'deployment/mac-ready'
REQUEST_CONTEXT = 'deployment/request-ready'
REQUEST_TTL = 120
DEVELOPMENT_BRANCH = 'codex/meta-glasses'
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


def readiness(statuses, actor, now=None, request=None):
    """Newest matching context wins, including pending/failure; never reuse old success."""
    now = now or dt.datetime.now(dt.timezone.utc)
    matches = [s for s in statuses if s['context'] == CONTEXT]
    require(bool(matches), 'Mac readiness unknown: no status')
    latest = max(matches, key=lambda s: s['id'])
    age = (now - dt.datetime.fromisoformat(latest['created_at'].replace('Z', '+00:00'))).total_seconds()
    require(latest['creator']['login'] == actor, 'Unexpected readiness status author')
    require(latest['state'] == 'success', 'Mac readiness offline, pending or failed')
    require(0 <= age <= 120, 'Mac readiness expired or has future timestamp')
    if request is not None:
        require(latest['id'] > request['id'], 'Readiness predates request')
        require(latest.get('description') == 'ready:' + request['description'].split(':')[1],
                'Readiness does not answer this exact request')


def current_development(sha):
    ref = api(f'repos/{REPO}/git/ref/heads/{DEVELOPMENT_BRANCH}')
    require(ref['object']['sha'] == sha, 'Candidate is not current development branch tip')


def status_list(sha):
    return api(f'repos/{REPO}/commits/{sha}/statuses?per_page=100')


def fresh_request(statuses, actor, now=None):
    now = now or dt.datetime.now(dt.timezone.utc)
    requests = [s for s in statuses if s['context'] == REQUEST_CONTEXT]
    require(bool(requests), 'No cloud readiness request')
    request = max(requests, key=lambda s: s['id'])
    age = (now - dt.datetime.fromisoformat(request['created_at'].replace('Z', '+00:00'))).total_seconds()
    require(request['creator']['login'] == actor, 'Untrusted readiness requester')
    require(request['state'] == 'pending', 'Readiness request is not pending')
    require(0 <= age <= REQUEST_TTL, 'Readiness request stale or future-dated')
    require(bool(re.fullmatch(r'request-ready:[0-9a-f]{32}', request.get('description', ''))),
            'Malformed readiness request')
    return request


def gate(sha, actor):
    commit(sha)
    repo_check()
    current_development(sha)
    statuses = status_list(sha)
    request = fresh_request(statuses, api('user')['login'])
    readiness(statuses, actor, request=request)


def request_ready(sha, actor, timeout=90):
    commit(sha)
    require(0 < timeout <= REQUEST_TTL, 'Readiness wait must be 1..120 seconds')
    repo_check()
    current_development(sha)
    who = api('user')['login']
    issued = api(f'repos/{REPO}/statuses/{sha}', {
        'context': REQUEST_CONTEXT, 'state': 'pending',
        'description': 'request-ready:' + uuid.uuid4().hex})
    deadline = time.monotonic() + timeout
    while True:
        current_development(sha)
        statuses = status_list(sha)
        request = fresh_request(statuses, who)
        require(request['id'] == issued['id'], 'Readiness request superseded; retry explicitly')
        try:
            readiness(statuses, actor, request=request)
            return
        except ValueError:
            # A sleeping/offline Mac can resume during this bounded wait.
            require(time.monotonic() < deadline, 'Mac offline/unknown: readiness wait expired')
            time.sleep(min(5, max(0, deadline - time.monotonic())))


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
    # Exit 0 can return cached offline details. Inspect current connection fields.
    with tempfile.TemporaryDirectory(prefix='iseeyou-device-') as folder:
        details = Path(folder) / 'details.json'
        lock = Path(folder) / 'lock.json'
        run('xcrun', 'devicectl', 'device', 'info', 'details', '--device', config['device_udid'],
            '--json-output', str(details))
        run('xcrun', 'devicectl', 'device', 'info', 'lockState', '--device', config['device_udid'],
            '--json-output', str(lock))
        device_ready(json.loads(details.read_text()), json.loads(lock.read_text()))
    profile = plistlib.loads(run('security', 'cms', '-D', '-i', config['profile']))
    ent = profile_entitlements(profile, config['bundle_id'], config['device_udid'], config['team_id'])
    cert_hashes = [hashlib.sha1(c).hexdigest().upper() for c in profile['DeveloperCertificates']]
    require(identity.upper() in cert_hashes, 'Signing certificate not included in profile')
    return ent


def device_ready(details, lock):
    result = details['result']
    require(result['hardwareProperties']['reality'] == 'physical', 'Physical iPhone required')
    require(result['connectionProperties']['pairingState'] == 'paired', 'iPhone is not paired')
    require(result['connectionProperties']['tunnelState'] == 'connected', 'iPhone tunnel disconnected/cached')
    require(result['deviceProperties']['bootState'] == 'booted', 'iPhone not booted')
    require(result['deviceProperties']['developerModeStatus'] == 'enabled', 'Developer Mode disabled')
    connection = result.get('properties', {}).get('connection')
    if connection is not None:
        require(connection.get('state') == 'connected', 'iPhone connection not live')
    lock_result = lock['result']
    if 'passcodeRequired' in lock_result:
        require(lock_result['passcodeRequired'] is False, 'iPhone requires passcode')
    if 'unlockedSinceBoot' in lock_result:
        require(lock_result['unlockedSinceBoot'] is True, 'iPhone not unlocked since boot')


def private_directory(path):
    path = Path(path)
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    require(not path.is_symlink() and path.stat().st_uid == os.getuid(), 'Private directory must belong to this user')
    require(stat.S_IMODE(path.stat().st_mode) & 0o077 == 0, 'Private directory must have mode 700')


def save_state(path, state):
    path = Path(path)
    private_directory(path.parent)
    require(not path.is_symlink(), 'State symlink refused')
    fd, temporary = tempfile.mkstemp(prefix='.state-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(state, f, sort_keys=True)
            f.flush()
            os.fsync(f.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def load_state(path):
    path = Path(path)
    if not path.exists():
        return {}
    require(not path.is_symlink() and path.stat().st_uid == os.getuid(), 'State must belong to this user')
    require(stat.S_IMODE(path.stat().st_mode) & 0o077 == 0, 'State must be private (mode 600)')
    return json.loads(path.read_text())


def answer_request(sha, config, state, state_path):
    statuses = status_list(sha)
    try:
        request = fresh_request(statuses, config['cloud_actor'])
    except ValueError:
        return  # Never answer unsolicited, stale, malformed or untrusted requests.
    token = request['description'].split(':')[1]
    try:
        mac_preflight(config)
        outcome = 'success'
    except (ValueError, KeyError, OSError, subprocess.SubprocessError):
        outcome = 'failure'
    # Post only on a new request or a change of readiness, not every poll.
    marker = [sha, request['id'], outcome]
    if state.get('readiness') != marker:
        current_development(sha)  # Candidate may have advanced during device checks.
        # Recheck request freshness and identity after potentially slow local commands.
        current = fresh_request(status_list(sha), config['cloud_actor'])
        require(current['id'] == request['id'], 'Request superseded while checking Mac')
        api(f'repos/{REPO}/statuses/{sha}', {'context': CONTEXT, 'state': outcome,
            'description': 'ready:' + token})
        state['readiness'] = marker
        save_state(state_path, state)


def watch_once(config, state, state_path):
    main_sha = commit(api(f'repos/{REPO}/commits/main')['sha'])
    if 'initial_main' not in state:
        # Initial startup is a baseline, never an instruction to install old main.
        state['initial_main'] = main_sha
        save_state(state_path, state)
    dev_sha = commit(api(f'repos/{REPO}/git/ref/heads/{DEVELOPMENT_BRANCH}')['object']['sha'])
    answer_request(dev_sha, config, state, state_path)
    if main_sha not in (state['initial_main'], state.get('last_installed')):
        # A failed/not-yet-built install leaves state untouched and is retried later.
        deploy(config, timeout=0, expected_sha=main_sha)
        state['last_installed'] = main_sha
        save_state(state_path, state)


def watch(config, state_path, interval=15):
    require(sys.platform == 'darwin', 'Watch mode runs only on the user Mac')
    require(bool(config.get('cloud_actor')), 'Set trusted cloud_actor GitHub login in private config')
    require(interval >= 5, 'Watch interval must be at least 5 seconds')
    state_path = Path(state_path).expanduser()
    private_directory(state_path.parent)
    # Prevent competing LaunchAgent/manual watchers from signing/installing twice.
    lock_path = state_path.with_suffix('.lock')
    require(not lock_path.is_symlink(), 'Watch lock symlink refused')
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        state = load_state(state_path)
        while True:
            try:
                repo_check()
                watch_once(config, state, state_path)
            except (ValueError, KeyError, OSError, subprocess.SubprocessError, zipfile.BadZipFile) as exc:
                # No CLI stderr, URLs, tokens, local identity or UDID in agent logs.
                reason = str(exc) if isinstance(exc, DeploymentError) else 'prerequisite/build/API not ready'
                print('Watch: ' + reason + '; retrying next poll.', flush=True)
            time.sleep(interval)


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
    with open(archive, 'rb') as f:
        digest = hashlib.file_digest(f, 'sha256').hexdigest()
    require(manifest == {'repository_id': REPO_ID, 'sha': sha, 'run_id': str(run_id),
                        'run_attempt': str(attempt), 'sha256': digest},
            'Artifact manifest/hash mismatch')


class DeploymentError(ValueError):
    """Only fixed, identifier-free reasons are eligible for watcher logs."""


@contextmanager
def deployment_stage(name):
    try:
        yield
    except DeploymentError:
        raise
    except (ValueError, KeyError, OSError, subprocess.SubprocessError, zipfile.BadZipFile) as exc:
        reason = 'operation failed; prerequisites or artifact unavailable'
        if isinstance(exc, ValueError):
            if str(exc) in ('iPhone requires passcode', 'iPhone not unlocked since boot'):
                reason = 'phone locked; unlock the physical iPhone'
            elif str(exc) in ('iPhone tunnel disconnected/cached', 'iPhone connection not live', 'iPhone not booted'):
                reason = 'phone offline or disconnected'
        raise DeploymentError(name + ': ' + reason) from None


def cache_file(path, seal=False):
    metadata = path.lstat()
    require(stat.S_ISREG(metadata.st_mode) and metadata.st_uid == os.getuid()
            and metadata.st_nlink == 1, 'Unsafe artifact cache file')
    if seal:
        path.chmod(0o600)
        metadata = path.lstat()
    require(stat.S_IMODE(metadata.st_mode) == 0o600, 'Artifact cache files must have mode 600')
    require(metadata.st_size <= (65536 if path.name == 'manifest.json' else 2_000_000_000),
            'Artifact cache file too large')


def cache_key(info, sha):
    commit(sha)
    require(type(info['id']) is int and info['id'] > 0 and type(info['run_attempt']) is int
            and info['run_attempt'] > 0, 'Invalid build run identity')
    return f"{REPO_ID}-{info['id']}-{info['run_attempt']}-{sha}"


def verify_cache_files(entry, seal=False):
    private_directory(entry)
    require({p.name for p in entry.iterdir()} == {'ISeeYou.app.zip', 'manifest.json'},
            'Unexpected artifact cache contents')
    for name in ('ISeeYou.app.zip', 'manifest.json'):
        cache_file(entry / name, seal=seal)


def verify_cache(entry, info, sha):
    verify_cache_files(entry)
    manifest = json.loads((entry / 'manifest.json').read_text())
    validate_manifest(manifest, sha, info['id'], info['run_attempt'], entry / 'ISeeYou.app.zip')


def cache_root(config):
    return Path(config.get('artifact_cache_dir', '~/.local/state/iseeyou-deploy/artifacts')).expanduser()


@contextmanager
def cache_lock(root):
    private_directory(root)
    lock_path = root / '.cache.lock'
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'w') as lock:
        require(os.fstat(lock.fileno()).st_uid == os.getuid()
                and stat.S_ISREG(os.fstat(lock.fileno()).st_mode)
                and stat.S_IMODE(os.fstat(lock.fileno()).st_mode) == 0o600,
                'Unsafe artifact cache lock')
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def cached_artifact(config, info, sha, destination):
    # Provenance is checked on every attempt, even when no network download is needed.
    trusted_run(info, sha)
    root = cache_root(config)
    key = cache_key(info, sha)
    entry = root / key
    with cache_lock(root):
        valid = False
        if entry.exists() or entry.is_symlink():
            # Unsafe ownership, permissions, links or unexpected files fail closed.
            # Only structurally safe entries with bad hash/manifest can be replaced.
            verify_cache_files(entry)
            try:
                verify_cache(entry, info, sha)
                valid = True
            except (ValueError, KeyError):
                print('Artifact cache validation failed; downloading a verified replacement.', flush=True)
        if not valid:
            download_timeout = config.get('download_timeout_seconds', 1800)
            require(isinstance(download_timeout, int) and download_timeout >= 1800,
                    'download_timeout_seconds must be at least 1800')
            staging = Path(tempfile.mkdtemp(prefix='.download-', dir=root))
            try:
                run('gh', 'run', 'download', str(info['id']), '--repo', REPO, '--name', ARTIFACT,
                    '--dir', str(staging), timeout=download_timeout)
                verify_cache_files(staging, seal=True)
                verify_cache(staging, info, sha)
                for name in ('ISeeYou.app.zip', 'manifest.json'):
                    with open(staging / name, 'rb') as f:
                        os.fsync(f.fileno())
                if entry.exists():
                    verify_cache_files(entry)
                    shutil.rmtree(entry)  # Only this checked private, two-file invalid entry.
                os.replace(staging, entry)  # Same-filesystem atomic publication of verified data.
                directory = os.open(root, os.O_RDONLY)
                try:
                    os.fsync(directory)
                finally:
                    os.close(directory)
            finally:
                if staging.exists():
                    shutil.rmtree(staging)
        # Copy unsigned data only into a fresh attempt directory. Never modify cached ZIP.
        verify_cache(entry, info, sha)
        for name in ('ISeeYou.app.zip', 'manifest.json'):
            shutil.copyfile(entry / name, destination / name)
            (destination / name).chmod(0o600)
    return destination / 'ISeeYou.app.zip'


def clean_cache_after_success(config, info, sha):
    """Retain current verified release, remove older verified entries only after install."""
    root = cache_root(config)
    keep = cache_key(info, sha)
    with cache_lock(root):
        for entry in root.iterdir():
            match = re.fullmatch(str(REPO_ID) + r'-(\d+)-(\d+)-([0-9a-f]{40})', entry.name)
            if not match or entry.name == keep:
                continue
            older = {'id': int(match[1]), 'run_attempt': int(match[2])}
            try:
                verify_cache(entry, older, match[3])
            except (ValueError, KeyError, OSError):
                continue  # Never recursively remove unknown, linked, or unsafe content.
            shutil.rmtree(entry)


def deploy(config, timeout, expected_sha=None):
    repo_check()
    with deployment_stage('before download readiness'):
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
        with deployment_stage('artifact cache/download'):
            archive = cached_artifact(config, info, sha, root)
        safe_extract(archive, root)
        app = root / 'ISeeYou.app'
        app_info = plistlib.loads((app / 'Info.plist').read_bytes())
        require(app_info['CFBundleIdentifier'] == config['bundle_id'], 'Unexpected app bundle ID')
        require(app_info.get('CFBundleSupportedPlatforms') == ['iPhoneOS'], 'Physical iPhone build required')
        require(not list(app.rglob('*.appex')), 'App extensions need separate profiles; refusing')
        require(api(f'repos/{REPO}/commits/main')['sha'] == sha, 'main moved; rerun deployment')
        with deployment_stage('after download readiness'):
            ent = mac_preflight(config)
        shutil.copyfile(config['profile'], app / 'embedded.mobileprovision')
        ent_path = root / 'entitlements.plist'
        ent_path.write_bytes(plistlib.dumps(ent))
        with deployment_stage('local signing'):
            nested = list(app.rglob('*.framework')) + list(app.rglob('*.dylib'))
            for binary in sorted(nested, key=lambda p: len(p.parts), reverse=True):
                run('codesign', '--force', '--sign', config['signing_identity'], '--timestamp=none', str(binary))
            run('codesign', '--force', '--sign', config['signing_identity'], '--timestamp=none',
                '--entitlements', str(ent_path), str(app))
            run('codesign', '--verify', '--deep', '--strict', str(app))
        require(api(f'repos/{REPO}/commits/main')['sha'] == sha, 'main moved before install; rerun')
        with deployment_stage('before install readiness'):
            mac_preflight(config)
        with deployment_stage('physical install'):
            run('xcrun', 'devicectl', 'device', 'install', 'app', '--device', config['device_udid'], str(app))
        try:
            clean_cache_after_success(config, info, sha)
        except (ValueError, KeyError, OSError):
            print('Artifact cache cleanup deferred; installation succeeded.', flush=True)
        print(f'Installed trusted main {sha} on configured physical iPhone; no app launch or calibration performed.')


def promote(sha, actor, timeout=90):
    """Optional future promotion: only fast-forward, with exact remote-main lease."""
    commit(sha)
    require(not run('git', 'status', '--porcelain').strip(), 'Working tree must be clean')
    # Explicit GitHub URL prevents a checkout remote from redirecting the push.
    remote = f'https://github.com/{REPO}.git'
    run('git', 'fetch', remote, 'refs/heads/main')
    old = run('git', 'rev-parse', 'FETCH_HEAD').decode().strip()
    run('git', 'merge-base', '--is-ancestor', old, sha)
    request_ready(sha, actor, timeout)
    gate(sha, actor)
    run('git', 'push', f'--force-with-lease=refs/heads/main:{old}', remote, f'{sha}:refs/heads/main')
    print(f'Fast-forwarded main to {sha}; Mac watch will sign/install the successful hosted main artifact.')


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
    for name in ('gate', 'request', 'promote'):
        p = sub.add_parser(name)
        p.add_argument('sha')
        p.add_argument('--mac-actor', required=True)
        if name != 'gate':
            p.add_argument('--wait-seconds', type=int, default=90)
        if name == 'promote':
            p.add_argument('--confirm-main', action='store_true', required=True)
    p = sub.add_parser('deploy')
    p.add_argument('--config', required=True)
    p.add_argument('--wait-seconds', type=int, default=1800)
    p = sub.add_parser('watch')
    p.add_argument('--config', required=True)
    p.add_argument('--state', required=True)
    p.add_argument('--interval', type=int, default=15)
    args = parser.parse_args()
    if args.command == 'gate':
        gate(args.sha, args.mac_actor)
        print('Requested exact-commit Mac readiness valid now; no merge performed.')
    elif args.command == 'request':
        request_ready(args.sha, args.mac_actor, args.wait_seconds)
        print('Mac answered this readiness request; no merge performed.')
    elif args.command == 'promote':
        promote(args.sha, args.mac_actor, args.wait_seconds)
    elif args.command == 'deploy':
        deploy(load_config(args.config), args.wait_seconds)
    elif args.command == 'watch':
        watch(load_config(args.config), args.state, args.interval)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, KeyError, OSError, subprocess.SubprocessError, zipfile.BadZipFile) as exc:
        # Avoid echoing subprocess output or config/token contents.
        message = str(exc) if isinstance(exc, ValueError) else 'Local command or API failed; inspect prerequisites without logging credentials.'
        print(f'Bridge stopped: {type(exc).__name__}: {message}', file=sys.stderr)
        sys.exit(1)
