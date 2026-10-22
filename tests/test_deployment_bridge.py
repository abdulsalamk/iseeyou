"""Offline contract tests; no GitHub calls, Apple signing or device deployment."""
import datetime as dt
import importlib.util
import json
from pathlib import Path
import plistlib
import stat
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location('bridge', Path(__file__).parents[1] / 'scripts/deploy/bridge.py')
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)
NOW = dt.datetime(2026, 10, 22, tzinfo=dt.timezone.utc)
SHA = 'a' * 40


def status(state='success', age=0, actor='mac-user', ident=1):
    return dict(context=b.CONTEXT, id=ident, state=state, creator={'login': actor},
                created_at=(NOW-dt.timedelta(seconds=age)).isoformat())


def info(**changes):
    data = dict(repository={'id': b.REPO_ID}, head_repository={'id': b.REPO_ID},
                head_sha=SHA, head_branch='main', event='push', path=b.WORKFLOW,
                status='completed', conclusion='success', id=123, run_attempt=1)
    data.update(changes)
    return data


class BridgeTests(unittest.TestCase):
    def test_fresh_readiness(self):
        b.readiness([status()], 'mac-user', NOW)

    def test_readiness_fails_closed(self):
        for data in ([], [status(age=301)], [status(age=-1)], [status(state='failure')],
                     [status(state='pending')], [status(actor='other')],
                     [status(), status(state='failure', ident=2)]):
            with self.subTest(data=data), self.assertRaises(ValueError):
                b.readiness(data, 'mac-user', NOW)

    def test_only_trusted_main_push(self):
        b.trusted_run(info(), SHA)
        for change in (dict(event='pull_request'), dict(event='workflow_dispatch'),
                       dict(head_branch='codex/meta-glasses'), dict(head_sha='b'*40),
                       dict(head_repository={'id': 9}), dict(repository={'id': 9}),
                       dict(path='.github/workflows/evil.yml'), dict(conclusion='failure'),
                       dict(status='in_progress')):
            with self.subTest(change=change), self.assertRaises(ValueError):
                b.trusted_run(info(**change), SHA)

    def test_profile_restrictions(self):
        profile = dict(ExpirationDate=NOW+dt.timedelta(days=1), ProvisionedDevices=['phone'],
                       TeamIdentifier=['TEAM'], Entitlements={'application-identifier': 'TEAM.com.iseeyou.research',
                       'com.apple.developer.team-identifier': 'TEAM', 'keychain-access-groups': ['TEAM.*']})
        ent = b.profile_entitlements(profile, 'com.iseeyou.research', 'phone', 'TEAM', NOW)
        self.assertEqual(ent['keychain-access-groups'], ['TEAM.com.iseeyou.research'])
        for changes in (dict(ProvisionedDevices=[]), dict(TeamIdentifier=['OTHER']),
                        dict(ExpirationDate=NOW-dt.timedelta(seconds=1))):
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                b.profile_entitlements(dict(profile, **changes), 'com.iseeyou.research', 'phone', 'TEAM', NOW)
        with self.assertRaises(ValueError):
            b.profile_entitlements(profile, 'different.bundle', 'phone', 'TEAM', NOW)

    def test_archive_permissions_and_traversal(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            archive = root/'app.zip'
            entry = zipfile.ZipInfo('ISeeYou.app/ISeeYou')
            entry.external_attr = (stat.S_IFREG | 0o755) << 16
            with zipfile.ZipFile(archive, 'w') as z:
                z.writestr(entry, b'binary')
            b.safe_extract(archive, root/'out')
            self.assertEqual((root/'out/ISeeYou.app/ISeeYou').stat().st_mode & 0o777, 0o755)
            for name, mode in (('../escape', 0), ('/tmp/escape', 0), ('Other.app/file', 0),
                               ('ISeeYou.app/../../escape', 0), ('ISeeYou.app/link', stat.S_IFLNK | 0o777)):
                with zipfile.ZipFile(archive, 'w') as z:
                    entry = zipfile.ZipInfo(name)
                    entry.external_attr = mode << 16
                    z.writestr(entry, b'target')
                with self.subTest(name=name), self.assertRaises(ValueError):
                    b.safe_extract(archive, root/'out')

    def test_manifest_binds_attempt_sha_and_bytes(self):
        with tempfile.TemporaryDirectory() as d:
            archive = Path(d)/'app.zip'
            archive.write_bytes(b'archive')
            m = dict(repository_id=b.REPO_ID, sha=SHA, run_id='123', run_attempt='1',
                     sha256=b.hashlib.sha256(b'archive').hexdigest())
            b.validate_manifest(m, SHA, 123, 1, archive)
            for change in (dict(sha='b'*40), dict(run_attempt='2'), dict(repository_id=1), dict(sha256='0'*64)):
                with self.subTest(change=change), self.assertRaises(ValueError):
                    b.validate_manifest(dict(m, **change), SHA, 123, 1, archive)

    def test_mac_preflight_refuses_linux(self):
        with patch.object(b.sys, 'platform', 'linux'), self.assertRaises(ValueError):
            b.mac_preflight({})

    def test_promote_never_pushes_when_gate_fails(self):
        commands = []
        def command(*args):
            commands.append(args)
            return b'' if args[1] != 'rev-parse' else ('b'*40).encode()
        with patch.object(b, 'run', side_effect=command), patch.object(b, 'gate', side_effect=ValueError('offline')):
            with self.assertRaises(ValueError):
                b.promote(SHA, 'mac-user')
        self.assertFalse(any('push' in args for args in commands))

    def test_promote_uses_exact_commit_and_lease(self):
        commands = []
        def command(*args):
            commands.append(args)
            return b'' if args[1] != 'rev-parse' else ('b'*40).encode()
        with patch.object(b, 'run', side_effect=command), patch.object(b, 'gate') as gate:
            b.promote(SHA, 'mac-user')
        gate.assert_called_once_with(SHA, 'mac-user')
        self.assertIn(('git', 'push', '--force-with-lease=refs/heads/main:'+'b'*40,
                       'https://github.com/'+b.REPO+'.git', SHA+':refs/heads/main'), commands)

    def test_mock_deploy_signs_nested_before_app_then_installs(self):
        with tempfile.TemporaryDirectory() as d:
            profile = Path(d)/'profile'
            profile.write_bytes(b'local profile')
            commands = []
            def command(*args, **kwargs):
                commands.append(args)
                if args[:3] == ('gh', 'run', 'download'):
                    root = Path(args[-1]); archive = root/'ISeeYou.app.zip'
                    with zipfile.ZipFile(archive, 'w') as z:
                        z.writestr('ISeeYou.app/Info.plist', plistlib.dumps(dict(CFBundleIdentifier='com.iseeyou.research', CFBundleSupportedPlatforms=['iPhoneOS'])))
                        z.writestr('ISeeYou.app/Frameworks/SDK.framework/SDK', b'library')
                    m = dict(repository_id=b.REPO_ID, sha=SHA, run_id='123', run_attempt='1', sha256=b.hashlib.sha256(archive.read_bytes()).hexdigest())
                    (root/'manifest.json').write_text(json.dumps(m))
                return b''
            def api(path):
                if path.endswith('/commits/main'): return {'sha': SHA}
                if '/actions/workflows/' in path: return {'workflow_runs': [info()]}
                if '/actions/runs/' in path: return info()
                return {'id': b.REPO_ID}
            config = dict(profile=str(profile), bundle_id='com.iseeyou.research', signing_identity='C'*40, device_udid='phone')
            with patch.object(b, 'api', side_effect=api), patch.object(b, 'run', side_effect=command), patch.object(b, 'mac_preflight', return_value={}):
                b.deploy(config, 0, expected_sha=SHA)
            signed = [c for c in commands if c[0]=='codesign' and '--force' in c]
            self.assertTrue(signed[0][-1].endswith('SDK.framework'))
            self.assertTrue(signed[1][-1].endswith('ISeeYou.app'))
            self.assertEqual(commands[-1][:6], ('xcrun', 'devicectl', 'device', 'install', 'app', '--device'))
            self.assertFalse(any(c[0]=='xcodebuild' for c in commands))

    def test_main_move_prevents_artifact_download(self):
        with patch.object(b, 'repo_check'), patch.object(b, 'mac_preflight'), patch.object(b, 'api', return_value={'sha': 'b'*40}), patch.object(b, 'run') as run:
            with self.assertRaises(ValueError):
                b.deploy({}, 0, expected_sha=SHA)
            run.assert_not_called()

    def test_readiness_failure_posts_failure(self):
        with patch.object(b, 'repo_check'), patch.object(b, 'current_development'), patch.object(b, 'post_status') as post, patch.object(b, 'mac_preflight', side_effect=ValueError('locked')):
            with self.assertRaises(ValueError): b.announce(SHA, {})
        self.assertEqual(post.call_args_list, [unittest.mock.call(SHA, 'pending'), unittest.mock.call(SHA, 'failure')])


    def test_api_failure_blocks_promotion(self):
        with patch.object(b, 'api', side_effect=OSError('API inaccessible')), patch.object(b, 'run') as run:
            with self.assertRaises(OSError): b.gate(SHA, 'mac-user')
            run.assert_not_called()

    def test_git_credentials_are_mac_only_and_in_memory(self):
        with patch.object(b.sys, 'platform', 'linux'), patch.object(b, 'run') as run:
            with self.assertRaises(ValueError): b.configure_github({'github_auth': 'git-credential'})
            run.assert_not_called()
        with patch.object(b.sys, 'platform', 'darwin'), patch.object(b, 'MAC_GITHUB_TOKEN', None), patch.object(b, 'run', return_value=b'username=local\npassword=mock-secret\n') as run:
            b.configure_github({'github_auth': 'git-credential'})
            self.assertEqual(b.MAC_GITHUB_TOKEN, 'mock-secret')
            self.assertEqual(run.call_args.args, ('git', 'credential', 'fill'))
            self.assertNotIn('mock-secret', str(run.call_args))

    def test_token_only_goes_to_gh_environment(self):
        with patch.object(b, 'MAC_GITHUB_TOKEN', 'mock-secret'), patch.object(b.subprocess, 'run') as child:
            b.run('gh', 'api', 'user')
            self.assertEqual(child.call_args.kwargs['env']['GH_TOKEN'], 'mock-secret')
            self.assertNotIn('mock-secret', str(child.call_args.args))
            b.run('codesign', '--verify', 'app')
            self.assertNotIn('env', child.call_args.kwargs)

    def test_profile_rejects_wrong_entitlement_team(self):
        profile = dict(ExpirationDate=NOW+dt.timedelta(days=1), ProvisionedDevices=['phone'],
                       TeamIdentifier=['TEAM'], Entitlements={'application-identifier': 'TEAM.com.iseeyou.research',
                       'com.apple.developer.team-identifier': 'OTHER'})
        with self.assertRaises(ValueError):
            b.profile_entitlements(profile, 'com.iseeyou.research', 'phone', 'TEAM', NOW)

    def test_config_permissions_refuse_public_file(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)/'config.json'; p.write_text('{}'); p.chmod(0o644)
            with self.assertRaises(ValueError): b.load_config(p)

    def test_superseded_development_commit_refused(self):
        with patch.object(b, 'api', return_value={'object': {'sha': 'b'*40}}):
            with self.assertRaises(ValueError): b.current_development(SHA)
        with patch.object(b, 'api', return_value={'object': {'sha': SHA}}):
            b.current_development(SHA)


if __name__ == '__main__':
    unittest.main()
