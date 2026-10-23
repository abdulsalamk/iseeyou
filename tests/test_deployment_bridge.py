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
        with patch.object(b, 'run', side_effect=command), patch.object(b, 'request_ready', side_effect=ValueError('offline')):
            with self.assertRaises(ValueError):
                b.promote(SHA, 'mac-user')
        self.assertFalse(any('push' in args for args in commands))

    def test_promote_uses_exact_commit_and_lease(self):
        commands = []
        def command(*args):
            commands.append(args)
            return b'' if args[1] != 'rev-parse' else ('b'*40).encode()
        with patch.object(b, 'run', side_effect=command), patch.object(b, 'request_ready'), patch.object(b, 'gate') as gate:
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
                    self.assertEqual(kwargs['timeout'], 2400)
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
            config = dict(artifact_cache_dir=str(Path(d)/'cache'), download_timeout_seconds=2400, profile=str(profile), bundle_id='com.iseeyou.research', signing_identity='C'*40, device_udid='phone')
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

    def test_device_json_rejects_cached_offline_and_nonphysical(self):
        details = {'result': {'hardwareProperties': {'reality': 'physical'},
                   'connectionProperties': {'pairingState': 'paired', 'tunnelState': 'connected'},
                   'deviceProperties': {'bootState': 'booted', 'developerModeStatus': 'enabled'},
                   'properties': {'connection': {'state': 'connected'}}}}
        lock = {'result': {'passcodeRequired': False, 'unlockedSinceBoot': True}}
        b.device_ready(details, lock)
        import copy
        for section, field, value in [('hardwareProperties','reality','simulated'),
            ('connectionProperties','tunnelState','disconnected'),
            ('connectionProperties','pairingState','unpaired'),
            ('deviceProperties','bootState','unknown'),
            ('deviceProperties','developerModeStatus','disabled')]:
            bad = copy.deepcopy(details); bad['result'][section][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError): b.device_ready(bad, lock)
        bad = copy.deepcopy(details); bad['result']['properties']['connection']['state'] = 'disconnected'
        with self.assertRaises(ValueError): b.device_ready(bad, lock)
        with self.assertRaises(ValueError): b.device_ready(details, {'result': {'passcodeRequired': True, 'unlockedSinceBoot': True}})
        with self.assertRaises(KeyError): b.device_ready({'result': {}}, lock)

    def test_exit_zero_cached_details_is_not_mac_readiness(self):
        def run(*args, **kwargs):
            if args[0] == 'security': return ('C'*40).encode()
            output = Path(args[args.index('--json-output')+1])
            if 'details' in args:
                output.write_text(json.dumps({'result': {'hardwareProperties': {'reality': 'physical'},
                    'connectionProperties': {'pairingState': 'paired', 'tunnelState': 'disconnected'},
                    'deviceProperties': {'bootState': 'booted', 'developerModeStatus': 'enabled'}}}))
            else:
                output.write_text(json.dumps({'result': {'passcodeRequired': False, 'unlockedSinceBoot': True}}))
            return b''  # devicectl exit 0, but data says offline.
        with patch.object(b.sys, 'platform', 'darwin'), patch.object(b, 'run', side_effect=run):
            with self.assertRaises(ValueError):
                b.mac_preflight({'bundle_id':'com.iseeyou.research','signing_identity':'C'*40,'device_udid':'phone'})

    def test_request_freshness_author_and_nonce(self):
        request = dict(status(state='pending', actor='cloud'), context=b.REQUEST_CONTEXT,
                       description='request-ready:'+'f'*32)
        self.assertEqual(b.fresh_request([request], 'cloud', NOW), request)
        for change in (dict(creator={'login':'stranger'}), dict(state='success'),
                       dict(description='not-a-request'),
                       dict(created_at=(NOW-dt.timedelta(seconds=121)).isoformat()),
                       dict(created_at=(NOW+dt.timedelta(seconds=1)).isoformat())):
            with self.subTest(change=change), self.assertRaises(ValueError):
                b.fresh_request([dict(request, **change)], 'cloud', NOW)
        response = dict(status(ident=2), description='ready:'+'f'*32)
        b.readiness([response], 'mac-user', NOW, request=request)
        with self.assertRaises(ValueError):
            b.readiness([dict(response, description='ready:'+'e'*32)], 'mac-user', NOW, request=request)
        with self.assertRaises(ValueError):
            b.readiness([dict(response, id=0)], 'mac-user', NOW, request=request)

    def test_request_offline_wait_expires_without_merge(self):
        now = dt.datetime.now(dt.timezone.utc).isoformat()
        request = dict(context=b.REQUEST_CONTEXT, id=1, state='pending',
                       creator={'login':'cloud'}, created_at=now, description='request-ready:'+'f'*32)
        def api(path, payload=None):
            if path == 'user': return {'login':'cloud'}
            return request
        with patch.object(b, 'repo_check'), patch.object(b, 'current_development'), patch.object(b, 'api', side_effect=api), patch.object(b, 'status_list', return_value=[request]), patch.object(b.time, 'monotonic', side_effect=[0, 91]):
            with self.assertRaises(ValueError): b.request_ready(SHA, 'mac-user', 90)

    def test_watcher_skips_initial_main_and_retries_install(self):
        def api(path):
            if '/commits/main' in path: return {'sha': current[0]}
            return {'object': {'sha': SHA}}
        with tempfile.TemporaryDirectory() as d:
            state = {}; path = Path(d)/'state.json'; current = ['b'*40]
            with patch.object(b, 'api', side_effect=api), patch.object(b, 'answer_request'), patch.object(b, 'deploy') as deploy:
                b.watch_once({}, state, path)
                deploy.assert_not_called()
                current[0] = SHA; deploy.side_effect = ValueError('phone asleep')
                with self.assertRaises(ValueError): b.watch_once({}, state, path)
                self.assertNotIn('last_installed', b.load_state(path))
                deploy.side_effect = None
                b.watch_once({}, state, path)
                self.assertEqual(b.load_state(path)['last_installed'], SHA)
                deploy.reset_mock(); b.watch_once({}, state, path); deploy.assert_not_called()
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_watch_answers_once_per_request_or_state_change(self):
        request = dict(context=b.REQUEST_CONTEXT, id=10, state='pending', creator={'login':'cloud'},
                       created_at=dt.datetime.now(dt.timezone.utc).isoformat(), description='request-ready:'+'f'*32)
        with tempfile.TemporaryDirectory() as d:
            state = {}; path = Path(d)/'state.json'
            with patch.object(b, 'status_list', return_value=[request]), patch.object(b, 'current_development') as current, patch.object(b, 'api') as api, patch.object(b, 'mac_preflight') as preflight:
                b.answer_request(SHA, {'cloud_actor':'cloud'}, state, path)
                b.answer_request(SHA, {'cloud_actor':'cloud'}, state, path)
                self.assertEqual(api.call_count, 1)
                self.assertEqual(current.call_args.args, (SHA,))
                preflight.side_effect = ValueError('offline')
                b.answer_request(SHA, {'cloud_actor':'cloud'}, state, path)
                self.assertEqual(api.call_count, 2)
                self.assertEqual(api.call_args.args[1]['state'], 'failure')
                b.answer_request(SHA, {'cloud_actor':'cloud'}, state, path)
                self.assertEqual(api.call_count, 2)

    def test_watch_ignores_untrusted_or_stale_requests(self):
        request = dict(context=b.REQUEST_CONTEXT, id=10, state='pending', creator={'login':'stranger'},
                       created_at=dt.datetime.now(dt.timezone.utc).isoformat(), description='request-ready:'+'f'*32)
        with patch.object(b, 'status_list', return_value=[request]), patch.object(b, 'mac_preflight') as preflight, patch.object(b, 'api') as api:
            b.answer_request(SHA, {'cloud_actor':'cloud'}, {}, Path('/unused'))
            preflight.assert_not_called(); api.assert_not_called()

    def test_launchagent_template_renders_private_paths_and_homebrew(self):
        spec = importlib.util.spec_from_file_location('renderer', Path(__file__).parents[1]/'scripts/deploy/render_agent.py')
        renderer = importlib.util.module_from_spec(spec); spec.loader.exec_module(renderer)
        template = (Path(__file__).parents[1]/'scripts/deploy/com.iseeyou.deploy.plist.in').read_bytes()
        data = plistlib.loads(renderer.render(template, '/Users/Example & Name', '/opt/homebrew/bin/python3'))
        self.assertEqual(data['ProgramArguments'][0], '/opt/homebrew/bin/python3')
        self.assertIn('watch', data['ProgramArguments'])
        self.assertIn('/Users/Example & Name/.local/state/iseeyou-deploy/state.json', data['ProgramArguments'])
        self.assertTrue(data['KeepAlive']); self.assertEqual(data['Umask'], 0o077)
        self.assertIn('/opt/homebrew/bin', data['EnvironmentVariables']['PATH'])
        self.assertNotIn('__HOME__', str(data))
        with self.assertRaises(ValueError): renderer.render(template, 'relative', '/usr/bin/python3')

    def test_device_optional_lock_fields_do_not_override_disconnect(self):
        details = {'result': {'hardwareProperties': {'reality': 'physical'},
                   'connectionProperties': {'pairingState':'paired','tunnelState': 'connected'},
                   'deviceProperties': {'bootState': 'booted', 'developerModeStatus': 'enabled'}}}
        b.device_ready(details, {'result': {}})
        details['result']['connectionProperties']['tunnelState'] = 'disconnected'
        with self.assertRaises(ValueError): b.device_ready(details, {'result': {}})

    def test_watcher_rechecks_exact_dev_tip_before_posting(self):
        request = dict(context=b.REQUEST_CONTEXT, id=10, state='pending', creator={'login':'cloud'},
                       created_at=dt.datetime.now(dt.timezone.utc).isoformat(), description='request-ready:'+'f'*32)
        with patch.object(b, 'status_list', return_value=[request]), patch.object(b, 'mac_preflight'), patch.object(b, 'current_development', side_effect=ValueError('dev advanced')), patch.object(b, 'api') as api:
            with self.assertRaises(ValueError): b.answer_request(SHA, {'cloud_actor':'cloud'}, {}, Path('/unused'))
            api.assert_not_called()

    def test_private_state_directory_and_symlink_refusal(self):
        with tempfile.TemporaryDirectory() as d:
            directory = Path(d)/'state'; directory.mkdir(); directory.chmod(0o755)
            with self.assertRaises(ValueError): b.save_state(directory/'state.json', {})
            directory.chmod(0o700)
            target = directory/'target'; target.write_text('preserved')
            state = directory/'state.json'; state.symlink_to(target)
            with self.assertRaises(ValueError): b.save_state(state, {})
            self.assertEqual(target.read_text(), 'preserved')

    def artifact_download(self, *args, **kwargs):
        if args[:3] != ('gh','run','download'): return b''
        root = Path(args[-1]); archive = root/'ISeeYou.app.zip'
        with zipfile.ZipFile(archive, 'w') as z:
            z.writestr('ISeeYou.app/Info.plist', plistlib.dumps(dict(
                CFBundleIdentifier='com.iseeyou.research', CFBundleSupportedPlatforms=['iPhoneOS'])))
            z.writestr('ISeeYou.app/Frameworks/SDK.framework/SDK', b'library')
        (root/'manifest.json').write_text(json.dumps(dict(repository_id=b.REPO_ID,
            sha=SHA, run_id='123', run_attempt='1', sha256=b.hashlib.sha256(archive.read_bytes()).hexdigest())))
        return b''

    def test_lock_after_download_preserves_cache_and_retry_never_redownloads(self):
        def api(path):
            if path.endswith('/commits/main'): return {'sha':SHA}
            if '/actions/workflows/' in path: return {'workflow_runs':[info()]}
            if '/actions/runs/' in path: return info()
            return {'id':b.REPO_ID}
        with tempfile.TemporaryDirectory() as d:
            profile=Path(d)/'profile'; profile.write_bytes(b'local-profile')
            config=dict(artifact_cache_dir=str(Path(d)/'cache'), download_timeout_seconds=3600,
                profile=str(profile), bundle_id='com.iseeyou.research', signing_identity='C'*40,device_udid='private-phone')
            locked=ValueError('iPhone requires passcode')
            with patch.object(b,'api',side_effect=api), patch.object(b,'run',side_effect=self.artifact_download) as run, patch.object(b,'mac_preflight',side_effect=[{},locked,locked,{},{},{}]):
                with self.assertRaisesRegex(b.DeploymentError,'after download readiness: phone locked'):
                    b.deploy(config,0,expected_sha=SHA)
                entry=Path(config['artifact_cache_dir'])/b.cache_key(info(),SHA)
                self.assertTrue((entry/'ISeeYou.app.zip').exists())
                b.verify_cache(entry,info(),SHA)
                with self.assertRaisesRegex(b.DeploymentError,'before download readiness: phone locked'):
                    b.deploy(config,0,expected_sha=SHA)
                b.deploy(config,0,expected_sha=SHA)
                self.assertEqual(sum(c.args[:3]==('gh','run','download') for c in run.call_args_list),1)
                self.assertEqual((entry/'ISeeYou.app.zip').stat().st_mode&0o777,0o600)
                with zipfile.ZipFile(entry/'ISeeYou.app.zip') as z:
                    self.assertNotIn('ISeeYou.app/embedded.mobileprovision',z.namelist())

    def test_corrupt_hash_forces_safe_redownload_and_new_attempt_key(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d); config={'artifact_cache_dir':str(root/'cache')}
            for n in ('first','retry','replacement'): (root/n).mkdir(mode=0o700)
            with patch.object(b,'run',side_effect=self.artifact_download) as run:
                b.cached_artifact(config,info(),SHA,root/'first')
                entry=Path(config['artifact_cache_dir'])/b.cache_key(info(),SHA)
                (entry/'ISeeYou.app.zip').write_bytes(b'tampered')
                b.cached_artifact(config,info(),SHA,root/'retry')
                self.assertEqual(run.call_count,2)
                b.verify_cache(entry,info(),SHA)
                self.assertNotEqual(b.cache_key(info(),SHA),b.cache_key(info(run_attempt=2),SHA))
                b.cached_artifact(config,info(),SHA,root/'replacement')
                self.assertEqual(run.call_count,2)

    def test_untrusted_build_never_uses_or_downloads_cache(self):
        with tempfile.TemporaryDirectory() as d, patch.object(b,'run') as run:
            with self.assertRaises(ValueError):
                b.cached_artifact({'artifact_cache_dir':str(Path(d)/'cache')},info(event='pull_request'),SHA,Path(d))
            run.assert_not_called()
            self.assertFalse((Path(d)/'cache').exists())

    def test_cache_symlinks_permissions_and_owner_rejected(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d); config={'artifact_cache_dir':str(root/'cache')}; target=root/'dest';target.mkdir()
            with patch.object(b,'run',side_effect=self.artifact_download) as run:
                b.cached_artifact(config,info(),SHA,target)
                entry=Path(config['artifact_cache_dir'])/b.cache_key(info(),SHA)
                archive=entry/'ISeeYou.app.zip'; archive.chmod(0o644)
                with self.assertRaises(ValueError): b.cached_artifact(config,info(),SHA,target)
                self.assertEqual(run.call_count,1)
                archive.chmod(0o600)
                with patch.object(b.os,'getuid',return_value=-1), self.assertRaises(ValueError):
                    b.cached_artifact(config,info(),SHA,target)
                archive.unlink(); archive.symlink_to(target/'ISeeYou.app.zip')
                with self.assertRaises(ValueError): b.cached_artifact(config,info(),SHA,target)
                self.assertEqual(run.call_count,1)

    def test_failed_download_never_publishes_partial_cache(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d); config={'artifact_cache_dir':str(root/'cache')}
            with patch.object(b,'run',side_effect=b.subprocess.TimeoutExpired('gh',3600)):
                with self.assertRaises(b.subprocess.TimeoutExpired):
                    b.cached_artifact(config,info(),SHA,root)
            self.assertFalse((root/'cache'/b.cache_key(info(),SHA)).exists())
            self.assertEqual([p.name for p in (root/'cache').iterdir()],['.cache.lock'])

    def test_stage_reason_sanitizes_private_errors(self):
        with self.assertRaises(b.DeploymentError) as result:
            with b.deployment_stage('local signing'):
                raise b.subprocess.CalledProcessError(1,['codesign','PRIVATE-IDENTITY'],stderr=b'signed URL or secret')
        self.assertEqual(str(result.exception),'local signing: operation failed; prerequisites or artifact unavailable')
        self.assertNotIn('PRIVATE',str(result.exception))

    def test_signing_failure_keeps_verified_cache(self):
        def api(path):
            if path.endswith('/commits/main'): return {'sha':SHA}
            if '/actions/workflows/' in path: return {'workflow_runs':[info()]}
            if '/actions/runs/' in path: return info()
            return {'id':b.REPO_ID}
        def command(*args,**kwargs):
            if args[0]=='codesign': raise b.subprocess.CalledProcessError(1,args,stderr=b'private diagnostic')
            return self.artifact_download(*args,**kwargs)
        with tempfile.TemporaryDirectory() as d:
            profile=Path(d)/'profile';profile.write_bytes(b'local-profile')
            config=dict(artifact_cache_dir=str(Path(d)/'cache'),profile=str(profile),
                bundle_id='com.iseeyou.research',signing_identity='C'*40,device_udid='phone')
            with patch.object(b,'api',side_effect=api),patch.object(b,'mac_preflight',return_value={}),patch.object(b,'run',side_effect=command) as run:
                with self.assertRaisesRegex(b.DeploymentError,'local signing:'):
                    b.deploy(config,0,expected_sha=SHA)
                b.verify_cache(Path(config['artifact_cache_dir'])/b.cache_key(info(),SHA),info(),SHA)
                run.side_effect=self.artifact_download
                b.deploy(config,0,expected_sha=SHA)
                self.assertEqual(sum(c.args[:3]==('gh','run','download') for c in run.call_args_list),1)

    def test_cache_cleanup_only_removes_older_verified_entries(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);destination=root/'attempt';destination.mkdir();config={'artifact_cache_dir':str(root/'cache')}
            with patch.object(b,'run',side_effect=self.artifact_download):
                b.cached_artifact(config,info(),SHA,destination)
            current=root/'cache'/b.cache_key(info(),SHA)
            older_info=info(id=122)
            older=root/'cache'/b.cache_key(older_info,SHA)
            b.shutil.copytree(current,older)
            manifest=json.loads((older/'manifest.json').read_text());manifest['run_id']='122'
            (older/'manifest.json').write_text(json.dumps(manifest))
            unrelated=root/'cache'/'user-file';unrelated.write_text('preserve')
            b.clean_cache_after_success(config,info(),SHA)
            self.assertFalse(older.exists());self.assertTrue(current.exists())
            self.assertEqual(unrelated.read_text(),'preserve')


if __name__ == '__main__':
    unittest.main()
