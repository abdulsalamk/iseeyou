import base64
import hashlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import unittest
import urllib.parse
import subprocess
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).parents[2]
LEARNING = ROOT / 'scripts/learning'
sys.path.insert(0, str(LEARNING))
pipeline_spec = importlib.util.spec_from_file_location('pipeline', LEARNING / 'pipeline.py')
pipeline = importlib.util.module_from_spec(pipeline_spec)
sys.modules['pipeline'] = pipeline
pipeline_spec.loader.exec_module(pipeline)
import chatgpt_siwc as siwc
fetch_spec = importlib.util.spec_from_file_location('fetch_local_queue', LEARNING / 'fetch_local_queue.py')
fetcher = importlib.util.module_from_spec(fetch_spec)
fetch_spec.loader.exec_module(fetcher)


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode()


class ChatGPTSIWCTests(unittest.TestCase):
    def test_id_token_signature_claims_and_nonce_are_verified(self):
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.asymmetric import padding, rsa
        private = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        numbers = private.public_key().public_numbers()
        jwk = {'kid': 'fixture-key', 'kty': 'RSA', 'e': b64url(numbers.e.to_bytes((numbers.e.bit_length()+7)//8, 'big')),
               'n': b64url(numbers.n.to_bytes((numbers.n.bit_length()+7)//8, 'big'))}
        claims = {'iss': 'https://auth.openai.com', 'aud': 'issued-client', 'exp': 9_999_999_999,
                  'nonce': 'expected-nonce', 'sub': 'fixture-user'}
        first = b64url(json.dumps({'alg': 'RS256', 'kid': 'fixture-key'}).encode())
        second = b64url(json.dumps(claims).encode())
        message = (first + '.' + second).encode()
        token = first + '.' + second + '.' + b64url(private.sign(message, padding.PKCS1v15(), hashes.SHA256()))
        discovery = {'issuer': 'https://auth.openai.com', 'jwks_uri': 'https://auth.openai.com/keys'}
        with patch.object(siwc, '_json_http', return_value=(200, {}, {'keys': [jwk]})):
            self.assertEqual(siwc._verify_id_token(token, client_id='issued-client', nonce='expected-nonce', discovery=discovery)['sub'], 'fixture-user')
            with self.assertRaisesRegex(siwc.ChatGPTError, 'claims'):
                siwc._verify_id_token(token, client_id='issued-client', nonce='wrong-nonce', discovery=discovery)

    def test_sign_in_does_not_save_credentials_without_plan_use_scope(self):
        class Server:
            server_port = 1455
            timeout = None
            def handle_request(self): pass
            def server_close(self): pass
        callback = {}
        def open_browser(url):
            callback.update({'state': [urllib.parse.parse_qs(urllib.parse.urlparse(url).query)['state'][0]],
                             'code': ['fixture-code'], 'client_id': ['issued-client']})
            return True
        tokens = {'access_token': 'secret-access', 'id_token': 'fixture-token', 'refresh_token': 'secret-refresh',
                  'expires_in': 3600, 'scope': 'openid profile email'}
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary) / 'chatgpt'
            with patch.object(siwc, '_discovery', return_value={'authorization_endpoint': 'https://auth.openai.com/authorize',
                    'token_endpoint': 'https://auth.openai.com/token', 'jwks_uri': 'https://auth.openai.com/keys', 'issuer': 'https://auth.openai.com'}), \
                 patch.object(siwc, '_callback_listener', return_value=(Server(), callback)), \
                 patch.object(siwc, '_post_form', return_value=(200, tokens)), \
                 patch.object(siwc, '_verify_id_token', return_value={'sub': 'fixture-user'}):
                with self.assertRaisesRegex(siwc.ChatGPTError, 'permission was not granted'):
                    siwc.sign_in(home, open_browser=open_browser, confirm=lambda _: 'y')
            self.assertFalse((home / 'credentials.json').exists())

    def test_stream_uses_fixed_model_and_privacy_parameters(self):
        class Response:
            status = 200
            def __enter__(self): return self
            def __exit__(self, *_): return False
            def __iter__(self):
                yield b'data: {"type":"response.output_text.delta","delta":"{}"}\n'
                yield b'\n'
        captured = {}
        def urlopen(request, timeout):
            captured['body'] = json.loads(request.data)
            captured['headers'] = request.headers
            return Response()
        with patch.object(siwc.urllib.request, 'urlopen', side_effect=urlopen):
            result = siwc._stream_response('fake-token', [('frame-1', b'fixture-jpeg')], [[]])
        self.assertEqual(result, '{}')
        self.assertEqual(captured['body']['model'], 'gpt-6.1-sol')
        self.assertFalse(captured['body']['store'])
        self.assertTrue(captured['body']['stream'])
        image = captured['body']['input'][0]['content'][2]['image_url']
        self.assertTrue(image.startswith('data:image/jpeg;base64,'))

    def test_usage_limit_error_pauses_instead_of_falling_back(self):
        with self.assertRaises(siwc.UsageLimitReached):
            raise siwc._response_error(429, {'error': {'code': 'subscription_sharing_usage_limit_exceeded'}})
        self.assertEqual(siwc.MODEL, 'gpt-6.1-sol')

    def test_labeling_pauses_and_resumes_without_repeating_completed_sample(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            queue = root / 'queue'; queue.mkdir(mode=0o700)
            home = root / 'credentials'; home.mkdir(mode=0o700)
            samples = []
            for number in (1, 2):
                image_name = f'frame-{number}.jpg'
                image = queue / image_name; image.write_bytes(b'\xff\xd8fixture' + bytes([number]))
                samples.append({'sample_id': f'sample-{number}', 'session_id': 'session-one',
                    'manifest_key': f'local/raw/manifests/sample-{number}.json', 'manifest_version': f'version-{number}',
                    'frames': [{'frame_id': f'frame-id-{number}', 'image_file': image_name, 'predictions': []}]})
            (queue / 'local_queue.json').write_text(json.dumps({'schema_version': 1, 'samples': samples}))
            siwc._atomic_json(home / 'credentials.json', {
                'client_id': 'issued-client', 'subject': 'fixture-user', 'id_token': 'fixture-id',
                'access_token': 'fixture-access', 'refresh_token': 'fixture-refresh', 'scope': ['chatgpt.tokens.use.direct'],
                'expires_at': 9_999_999_999, 'issuer': 'https://auth.openai.com',
            })
            proposal = json.dumps({'frames': [{'frame_id': 'frame-id-1', 'objects': [{'label': 'chair', 'box': [.1,.2,.8,.9]}], 'summary': 'chair'}]})
            with patch.object(siwc, '_discovery', return_value={'issuer': 'https://auth.openai.com'}), \
                 patch.object(siwc, '_ensure_model'), \
                 patch.object(siwc, '_stream_response', side_effect=[proposal, siwc.UsageLimitReached('limit')]) as call:
                with self.assertRaises(siwc.UsageLimitReached):
                    siwc.label_local(queue, home=home, confirm=lambda _: 'yes', open_browser=lambda _: True)
                self.assertEqual(call.call_count, 2)
                saved = json.loads((queue / 'chatgpt-proposals.json').read_text())
                self.assertIn('sample-1:version-1', saved['proposals'])
                self.assertNotIn('sample-2:version-2', saved['proposals'])
                review = json.loads((queue / 'review.json').read_text())
                self.assertFalse(review['samples'][0]['complete_annotation'])
                review['samples'][0]['reviewed_by'] = 'reviewer'
                review['samples'][0]['objects'] = [{'label': 'chair', 'box': [.1,.2,.8,.9]}]
                (queue / 'review.json').write_text(json.dumps(review))
            with patch.object(siwc, '_discovery', return_value={'issuer': 'https://auth.openai.com'}), \
                 patch.object(siwc, '_ensure_model'), \
                 patch.object(siwc, '_stream_response', return_value=json.dumps({'frames': [
                     {'frame_id': 'frame-id-2', 'objects': [], 'summary': ''}]})) as call:
                self.assertEqual(siwc.label_local(queue, home=home, confirm=lambda _: 'yes', open_browser=lambda _: True), 1)
                self.assertEqual(call.call_count, 1)
                review = json.loads((queue / 'review.json').read_text())
                first = next(row for row in review['samples'] if row['id'] == 'sample-1-0')
                self.assertEqual(first['reviewed_by'], 'reviewer')
                self.assertEqual(first['objects'][0]['label'], 'chair')

    def test_usage_confirmation_gate_prevents_any_openai_request(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary); queue = root / 'queue'; queue.mkdir()
            home = root / 'credentials'; home.mkdir()
            (queue / 'local_queue.json').write_text(json.dumps({'schema_version': 1, 'samples': [
                {'sample_id': 's', 'manifest_version': 'v', 'frames': []}]}))
            siwc._atomic_json(home / 'credentials.json', {'access_token': 'x', 'expires_at': 9_999_999_999,
                'scope': ['chatgpt.tokens.use.direct']})
            with patch.object(siwc, '_discovery') as discovery:
                with self.assertRaisesRegex(siwc.ChatGPTError, '10% app limit'):
                    siwc.label_local(queue, home=home, confirm=lambda _: 'no', open_browser=lambda _: True)
                discovery.assert_not_called()

    def test_local_queue_fetch_pins_manifest_version_and_verifies_frame_checksum(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            output = root / 'queue'
            image = b'\xff\xd8synthetic-frame'
            clip = b'synthetic-clip'
            checksum = lambda value: base64.b64encode(hashlib.sha256(value).digest()).decode()
            sample_id = '00000000-0000-0000-0000-000000000123'
            doc = {'learning_mode': 'local_mac', 'consent': True, 'sample_id': sample_id,
                'session_id': '00000000-0000-0000-0000-000000000456',
                'image_key': f'local/raw/images/{sample_id}.jpg', 'image_version': 'image-v1',
                'clip_key': f'local/raw/clips/{sample_id}.mp4', 'clip_version': 'clip-v1', 'clip_sha256': checksum(clip),
                'image_size': len(image), 'image_sha256': checksum(image), 'frame_id': sample_id+'-0',
                'captured_at': '2026-10-25T12:00:00Z', 'predictions': [], 'frame_images': [{
                    'image_key': f'local/raw/images/{sample_id}.jpg', 'image_version': 'image-v1',
                    'image_sha256': checksum(image), 'frame_id': sample_id+'-0',
                    'captured_at': '2026-10-25T12:00:00Z', 'offset_seconds': 0, 'predictions': [],
                }]}
            def fake_aws(*args):
                if args[:2] == ('sts', 'get-caller-identity'):
                    return {'Account': '885625664603'}
                if args[:2] == ('s3api', 'list-objects-v2'):
                    return {'Contents': [{'Key': f'local/raw/manifests/{sample_id}.json', 'LastModified': '2026-10-25T12:00:00Z'}]}
                if args[:2] == ('s3api', 'get-object'):
                    key_index = args.index('--key') + 1
                    key, target = args[key_index], Path(args[-1])
                    if key.endswith('.json'):
                        target.write_text(json.dumps(doc))
                        return {'VersionId': 'manifest-v1'}
                    target.write_bytes(image if '/images/' in key else clip)
                    return {'VersionId': 'media-v1'}
                raise AssertionError('Unexpected AWS command')
            with patch.object(fetcher, 'aws', side_effect=fake_aws), \
                 patch.object(sys, 'argv', ['fetch_local_queue.py', '--output', str(output)]):
                fetcher.main()
            index = json.loads((output / 'local_queue.json').read_text())
            row = index['samples'][0]
            self.assertEqual(row['manifest_version'], 'manifest-v1')
            self.assertEqual(row['frames'][0]['frame_id'], sample_id+'-0')
            self.assertEqual(row['frames'][0]['image_file'], f'{sample_id}.jpg')


if __name__ == '__main__':
    unittest.main()
