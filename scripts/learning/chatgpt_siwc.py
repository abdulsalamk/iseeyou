"""Sign in with ChatGPT and create unapproved frame-label proposals locally."""
from __future__ import annotations

import base64
import hashlib
import http.server
import json
import math
import os
import secrets
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import webbrowser
from pathlib import Path

MODEL = 'gpt-6.1-sol'
API = 'https://api.openai.com/v1'
RESOURCE = 'https://api.openai.com/v1'
SCOPES = ('openid profile email offline_access resource.invoke chatgpt.tokens.use.direct')
USAGE_URL = 'https://chatgpt.com/#settings/Usage'
DISCOVERY_URL = 'https://auth.openai.com/.well-known/openid-configuration'
DEFAULT_HOME = Path.home() / '.config' / 'iseeyou-teacher' / 'chatgpt'


class ChatGPTError(ValueError):
    pass


class UsageLimitReached(ChatGPTError):
    pass


class InferencePaused(ChatGPTError):
    pass


class ReauthenticateRequired(ChatGPTError):
    pass


class _CallbackServer(http.server.HTTPServer):
    daemon_threads = True


def _private_directory(path: Path) -> Path:
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path, 0o700)
    return path


def _atomic_json(path: Path, value: dict) -> None:
    _private_directory(path.parent)
    fd, temporary = tempfile.mkstemp(prefix='.' + path.name + '.', dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            json.dump(value, stream, ensure_ascii=False, indent=2, allow_nan=False)
            stream.write('\n')
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    except Exception:
        try:
            os.close(fd)
        except OSError:
            pass
        Path(temporary).unlink(missing_ok=True)
        raise


def _read_json(path: Path) -> dict:
    if not path.is_file():
        raise ChatGPTError('ChatGPT sign-in is required. Run this command again and accept the browser sign-in prompt.')
    if path.stat().st_mode & 0o077:
        raise ChatGPTError(f'Credential file permissions must be 0600: {path}')
    try:
        return json.loads(path.read_text(encoding='utf-8'))
    except (OSError, json.JSONDecodeError) as exc:
        raise ChatGPTError('ChatGPT credential file is unreadable; sign in again.') from exc


def _http(url: str, *, method='GET', body=None, headers=None, timeout=45):
    request = urllib.request.Request(url, data=body, headers=headers or {}, method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, response.headers, response.read()
    except urllib.error.HTTPError as exc:
        return exc.code, exc.headers, exc.read()


def _json_http(url: str, *, method='GET', value=None, headers=None, timeout=45):
    content_headers = dict(headers or {})
    body = None
    if value is not None:
        body = json.dumps(value, separators=(',', ':'), allow_nan=False).encode()
        content_headers['Content-Type'] = 'application/json'
    status, response_headers, data = _http(url, method=method, body=body, headers=content_headers, timeout=timeout)
    try:
        payload = json.loads(data or b'{}')
    except json.JSONDecodeError as exc:
        raise ChatGPTError(f'OpenAI returned an unreadable response (HTTP {status}).') from exc
    return status, response_headers, payload


def _discovery() -> dict:
    status, _, document = _json_http(DISCOVERY_URL, timeout=20)
    if status != 200 or document.get('issuer') != 'https://auth.openai.com':
        raise ChatGPTError('Could not load the OpenAI sign-in configuration.')
    for key in ('authorization_endpoint', 'token_endpoint', 'jwks_uri'):
        url = urllib.parse.urlparse(document.get(key, ''))
        if url.scheme != 'https' or url.hostname != 'auth.openai.com':
            raise ChatGPTError('OpenAI sign-in configuration contained an unexpected endpoint.')
    return document


def _base64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b'=').decode('ascii')


def _pkce_pair() -> tuple[str, str]:
    verifier = _base64url(secrets.token_bytes(32))
    challenge = _base64url(hashlib.sha256(verifier.encode('ascii')).digest())
    return verifier, challenge


def _decode_segment(segment: str) -> bytes:
    return base64.urlsafe_b64decode(segment + '=' * (-len(segment) % 4))


def _verify_id_token(token: str, *, client_id: str, nonce: str, discovery: dict) -> dict:
    try:
        header_part, claims_part, signature_part = token.split('.')
        header = json.loads(_decode_segment(header_part))
        claims = json.loads(_decode_segment(claims_part))
    except (ValueError, json.JSONDecodeError) as exc:
        raise ChatGPTError('OpenAI returned a malformed identity token.') from exc
    if header.get('alg') != 'RS256' or not isinstance(header.get('kid'), str):
        raise ChatGPTError('OpenAI identity token used an unsupported signature.')
    status, _, jwks = _json_http(discovery['jwks_uri'], timeout=20)
    if status != 200 or not isinstance(jwks.get('keys'), list):
        raise ChatGPTError('Could not validate the OpenAI identity token.')
    key = next((item for item in jwks['keys'] if item.get('kid') == header['kid'] and item.get('kty') == 'RSA'), None)
    if key is None:
        raise ChatGPTError('OpenAI identity signing key was not found.')
    try:
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.asymmetric import padding, rsa
        public_key = rsa.RSAPublicNumbers(
            int.from_bytes(_decode_segment(key['e']), 'big'),
            int.from_bytes(_decode_segment(key['n']), 'big')).public_key()
        public_key.verify(_decode_segment(signature_part), (header_part + '.' + claims_part).encode('ascii'),
                          padding.PKCS1v15(), hashes.SHA256())
    except ImportError as exc:
        raise ChatGPTError('Install the local ChatGPT helper requirements before signing in.') from exc
    except Exception as exc:
        raise ChatGPTError('OpenAI identity token signature validation failed.') from exc
    now = int(time.time())
    audience = claims.get('aud')
    valid_audience = audience == client_id or (isinstance(audience, list) and client_id in audience)
    if (claims.get('iss') != discovery['issuer'] or not valid_audience
            or (claims.get('azp') is not None and claims.get('azp') != client_id)
            or (isinstance(audience, list) and len(audience) > 1 and claims.get('azp') != client_id)
            or type(claims.get('exp')) not in (int, float) or claims['exp'] <= now
            or (claims.get('nbf') is not None and (type(claims['nbf']) not in (int, float) or claims['nbf'] > now))
            or claims.get('nonce') != nonce or not isinstance(claims.get('sub'), str)):
        raise ChatGPTError('OpenAI identity token claims did not match this sign-in.')
    return claims


def _post_form(endpoint: str, values: dict) -> tuple[int, dict]:
    status, _, data = _http(endpoint, method='POST', body=urllib.parse.urlencode(values).encode('ascii'),
                            headers={'Content-Type': 'application/x-www-form-urlencoded'}, timeout=30)
    try:
        payload = json.loads(data or b'{}')
    except json.JSONDecodeError:
        payload = {}
    return status, payload


def _callback_listener():
    result = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path != '/auth/callback':
                self.send_error(404)
                return
            result.update(urllib.parse.parse_qs(parsed.query, keep_blank_values=True))
            body = b'ChatGPT sign-in received. You may close this browser tab and return to I See You.'
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_):
            return

    server = _CallbackServer(('127.0.0.1', 0), Handler)
    return server, result


def sign_in(home: Path = DEFAULT_HOME, *, open_browser=webbrowser.open, confirm=input) -> dict:
    home = _private_directory(home)
    credential_path = home / 'credentials.json'
    host_path = home / 'host.json'
    host = _read_json(host_path) if host_path.exists() else {'ext_agent_host_id': 'urn:uuid:' + str(uuid.uuid4())}
    if not str(host.get('ext_agent_host_id', '')).startswith('urn:uuid:'):
        raise ChatGPTError('Stored ChatGPT host ID is invalid.')
    if not host_path.exists():
        _atomic_json(host_path, host)
    prior = None
    if credential_path.exists():
        prior = _read_json(credential_path)
    answer = confirm('Continue to ChatGPT sign-in in your browser and review the plan-use permission? [y/N] ').strip().lower()
    if answer not in ('y', 'yes'):
        raise ChatGPTError('ChatGPT sign-in cancelled; no labeling request was made.')
    discovery = _discovery()
    server, callback = _callback_listener()
    redirect_uri = f'http://127.0.0.1:{server.server_port}/auth/callback'
    state, nonce = secrets.token_urlsafe(32), secrets.token_urlsafe(32)
    verifier, challenge = _pkce_pair()
    client_id = prior.get('client_id') if prior else 'dynamic_agent_client'
    params = {
        'response_type': 'code', 'client_id': client_id,
        'redirect_uri': redirect_uri, 'scope': SCOPES,
        'state': state, 'nonce': nonce, 'code_challenge_method': 'S256',
        'code_challenge': challenge, 'resource': RESOURCE,
        'ext_agent_host_id': host['ext_agent_host_id'],
    }
    if not prior:
        params['agent_name_hint'] = 'I See You Local Learning'
    else:
        params['id_token_hint'] = prior.get('id_token', '')
    authorization_url = discovery['authorization_endpoint'] + '?' + urllib.parse.urlencode(params)
    server.timeout = 180
    try:
        if not open_browser(authorization_url):
            print('Open this ChatGPT sign-in URL in your browser:')
            print(authorization_url)
        print('Waiting up to three minutes for ChatGPT sign-in in the browser…')
        server.handle_request()
    finally:
        server.server_close()
    if not callback:
        raise ChatGPTError('ChatGPT sign-in timed out; no labeling request was made.')
    if callback.get('state', [''])[0] != state:
        raise ChatGPTError('ChatGPT sign-in state did not match; no token was exchanged.')
    if callback.get('error'):
        raise ChatGPTError('ChatGPT sign-in was declined or failed; no labeling request was made.')
    code = callback.get('code', [''])[0]
    issued_client = callback.get('client_id', [client_id])[0]
    if not code or not issued_client or (prior and issued_client != prior.get('client_id')):
        raise ChatGPTError('ChatGPT returned an incomplete or mismatched sign-in result.')
    status, tokens = _post_form(discovery['token_endpoint'], {
        'grant_type': 'authorization_code', 'client_id': issued_client,
        'code': code, 'code_verifier': verifier, 'redirect_uri': redirect_uri,
        'resource': RESOURCE,
    })
    if status != 200 or not tokens.get('access_token') or not tokens.get('id_token'):
        raise ChatGPTError('ChatGPT token exchange failed; start a fresh sign-in.')
    claims = _verify_id_token(tokens['id_token'], client_id=issued_client, nonce=nonce, discovery=discovery)
    granted = set(str(tokens.get('scope', '')).split())
    if 'chatgpt.tokens.use.direct' not in granted:
        raise ChatGPTError('ChatGPT plan-use permission was not granted. No image requests were sent.')
    saved = {
        'client_id': issued_client, 'subject': claims['sub'], 'id_token': tokens['id_token'],
        'access_token': tokens['access_token'], 'refresh_token': tokens.get('refresh_token', ''),
        'scope': sorted(granted), 'expires_at': int(time.time()) + int(tokens.get('expires_in', 3600)),
        'issuer': discovery['issuer'],
    }
    _atomic_json(credential_path, saved)
    return saved


def _credentials(home: Path, discovery: dict) -> dict:
    path = home / 'credentials.json'
    saved = _read_json(path)
    if saved.get('expires_at', 0) > time.time() + 60:
        return saved
    if not saved.get('refresh_token'):
        raise ChatGPTError('ChatGPT sign-in expired. Run label-local again to sign in.')
    status, tokens = _post_form(discovery['token_endpoint'], {
        'grant_type': 'refresh_token', 'client_id': saved['client_id'],
        'refresh_token': saved['refresh_token'], 'resource': RESOURCE,
    })
    if status != 200:
        if tokens.get('error') in ('invalid_grant', 'invalid_refresh_token', 'refresh_token_expired', 'refresh_token_invalidated', 'refresh_token_reused'):
            raise ReauthenticateRequired('ChatGPT refresh token is no longer usable; sign in again.')
        raise ChatGPTError(f'ChatGPT token refresh failed (HTTP {status}); queued samples were left untouched.')
    if not tokens.get('access_token'):
        raise ChatGPTError('ChatGPT refresh returned no access token; queued samples were left untouched.')
    updated = dict(saved)
    updated['access_token'] = tokens['access_token']
    updated['refresh_token'] = tokens.get('refresh_token', saved['refresh_token'])
    updated['expires_at'] = int(time.time()) + int(tokens.get('expires_in', 3600))
    if tokens.get('scope'):
        updated['scope'] = sorted(set(tokens['scope'].split()))
    if 'chatgpt.tokens.use.direct' not in updated.get('scope', []):
        raise ChatGPTError('ChatGPT plan-use permission is no longer enabled; no image request was sent.')
    _atomic_json(path, updated)
    return updated


def _usage_prompt(sample_count: int, confirm=input, open_browser=webbrowser.open) -> None:
    print('Before labeling, set this app’s weekly limit to 10% in ChatGPT Settings > Usage.')
    print(USAGE_URL)
    open_browser(USAGE_URL)
    if confirm('Have you set the ChatGPT app limit to 10%? [y/N] ').strip().lower() not in ('y', 'yes'):
        raise ChatGPTError('Set and confirm the 10% app limit before labeling; no image requests were sent.')
    if confirm(f'This run will send sampled still frames from {sample_count} local session(s) to OpenAI for label proposals. Continue? [y/N] ').strip().lower() not in ('y', 'yes'):
        raise ChatGPTError('Local frame labeling cancelled; no image requests were sent.')


def _ensure_model(token: str) -> None:
    status, _, catalog = _json_http(API + '/models', headers={'Authorization': 'Bearer ' + token}, timeout=30)
    if status != 200:
        raise ChatGPTError(f'Could not verify {MODEL} availability for this ChatGPT account (HTTP {status}).')
    models = catalog.get('models')
    if not isinstance(models, list) or not any(item.get('slug') == MODEL and item.get('visibility') == 'list' for item in models if isinstance(item, dict)):
        raise ChatGPTError(f'{MODEL} is not available to this ChatGPT account. No fallback model was used.')


def _response_error(status: int, payload: dict) -> ChatGPTError:
    response = payload.get('response', {}) if isinstance(payload, dict) else {}
    error = payload.get('error', {}) if isinstance(payload, dict) else {}
    if not error and isinstance(response, dict):
        error = response.get('error', {})
    code = error.get('code') if isinstance(error, dict) else None
    if code == 'subscription_sharing_usage_limit_exceeded':
        return UsageLimitReached('ChatGPT reports this app’s usage limit has been reached. Labeling is paused; queued work and completed proposals are preserved.')
    if status == 429:
        return InferencePaused('ChatGPT returned HTTP 429. Labeling is paused; check ChatGPT Settings > Usage before resuming.')
    detail = error.get('message') if isinstance(error, dict) else payload.get('detail') if isinstance(payload, dict) else None
    nested = payload.get('response') if isinstance(payload, dict) else None
    request_id = (payload.get('request_id') or (nested.get('id') if isinstance(nested, dict) else None)) if isinstance(payload, dict) else None
    suffix = f' Request ID: {request_id}.' if request_id else ''
    return ChatGPTError(f'ChatGPT labeling request failed (HTTP {status}{", " + code if code else ""}): {str(detail or "request rejected")[:300]}.{suffix}')


def _stream_response(token: str, images: list[tuple[str, bytes]], predictions: list[list[dict]]) -> str:
    content = [{'type': 'input_text', 'text': (
        'Review the provided sampled camera frames independently. Return only one JSON object with this shape: '
        '{"frames":[{"frame_id":"...","objects":[{"label":"...","box":[xmin,ymin,xmax,ymax]}],"summary":"..."}]}. '
        'Boxes use normalized top-left xyxy coordinates in [0,1]. List visible objects and tight boxes; use [] for no supported objects. '
        'Do not infer hidden objects or use the detector predictions as ground truth. Preserve every supplied frame_id exactly. '
        'These are annotation proposals that a human will review.'
    )}]
    for index, (frame_id, image) in enumerate(images):
        content.append({'type': 'input_text', 'text': f'frame_id={frame_id}; existing detector suggestions (unverified): {json.dumps(predictions[index], ensure_ascii=False)}'})
        content.append({'type': 'input_image', 'image_url': 'data:image/jpeg;base64,' + base64.b64encode(image).decode('ascii'), 'detail': 'high'})
    body = json.dumps({
        'model': MODEL,
        'input': [{'role': 'user', 'content': content}],
        'store': False,
        'stream': True,
    }, separators=(',', ':'), allow_nan=False).encode()
    request = urllib.request.Request(API + '/responses', data=body, method='POST', headers={
        'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json', 'Accept': 'text/event-stream',
    })
    try:
        response = urllib.request.urlopen(request, timeout=120)
    except urllib.error.HTTPError as exc:
        try:
            error = json.loads(exc.read() or b'{}')
        except json.JSONDecodeError:
            error = {}
        raise _response_error(exc.code, error) from exc
    output = []
    event_data = []
    with response:
        if response.status < 200 or response.status >= 300:
            raise ChatGPTError(f'ChatGPT labeling request failed (HTTP {response.status}).')
        for raw in response:
            line = raw.decode('utf-8', errors='replace').strip()
            if line.startswith('data:'):
                data = line[5:].strip()
                if data == '[DONE]':
                    continue
                event_data.append(data)
                try:
                    event = json.loads(data)
                except json.JSONDecodeError:
                    continue
                if event.get('type') == 'response.output_text.delta':
                    output.append(event.get('delta', ''))
                elif event.get('type') in ('response.failed', 'error'):
                    raise _response_error(200, event)
            elif not line and event_data:
                event_data.clear()
    text = ''.join(output)
    if not text:
        raise ChatGPTError('ChatGPT stream ended without annotation output; this sample remains eligible to retry.')
    return text


def _validate_proposal(text: str, expected: list[str]) -> list[dict]:
    try:
        document = json.loads(text)
    except json.JSONDecodeError as exc:
        raise ChatGPTError('ChatGPT returned invalid JSON; the response was not saved as a proposal.') from exc
    frames = document.get('frames') if isinstance(document, dict) else None
    if not isinstance(frames, list) or len(frames) != len(expected):
        raise ChatGPTError('ChatGPT returned the wrong number of frame proposals.')
    by_id = {}
    for frame in frames:
        if not isinstance(frame, dict) or frame.get('frame_id') not in expected or frame['frame_id'] in by_id:
            raise ChatGPTError('ChatGPT returned a missing or unexpected frame ID.')
        objects = frame.get('objects')
        if not isinstance(objects, list) or len(objects) > 100:
            raise ChatGPTError('ChatGPT returned an invalid object list.')
        checked = []
        for obj in objects:
            if not isinstance(obj, dict):
                raise ChatGPTError('ChatGPT returned an invalid object annotation.')
            label, box = obj.get('label'), obj.get('box')
            if (not isinstance(label, str) or not label.strip() or len(label) > 100
                    or not isinstance(box, list) or len(box) != 4
                    or any(type(value) not in (int, float) or not math.isfinite(value) or not 0 <= value <= 1 for value in box)
                    or box[0] >= box[2] or box[1] >= box[3]):
                raise ChatGPTError('ChatGPT returned an invalid label or normalized box.')
            checked.append({'label': label.strip(), 'box': [float(value) for value in box]})
        summary = frame.get('summary', '')
        by_id[frame['frame_id']] = {'frame_id': frame['frame_id'], 'objects': checked,
                                    'summary': summary[:240] if isinstance(summary, str) else ''}
    return [by_id[frame_id] for frame_id in expected]


def _materialize_review(queue: Path, index: dict, proposals: dict) -> None:
    review_path = queue / 'review.json'
    existing = {}
    if review_path.exists():
        try:
            existing = {row['id']: row for row in json.loads(review_path.read_text()).get('samples', [])}
        except (OSError, json.JSONDecodeError, KeyError, TypeError):
            raise ChatGPTError('Existing review.json is unreadable; it was left unchanged.')
    rows = []
    for sample in index.get('samples', []):
        key = f"{sample['sample_id']}:{sample['manifest_version']}"
        proposal = proposals.get(key)
        if not proposal:
            continue
        group = sample['session_id']
        for frame_index, frame in enumerate(proposal['frames']):
            image_file = sample['frames'][frame_index]['image_file']
            row_id = f"{sample['sample_id']}-{frame_index}"
            if row_id in existing:
                rows.append(existing[row_id])
                continue
            image_path = (queue / image_file).resolve()
            if not image_path.is_relative_to(queue.resolve()) or not image_path.is_file():
                raise ChatGPTError('A queued image path is missing or unsafe; review.json was not written.')
            rows.append({
                'id': row_id, 'image': image_file, 'sha256': hashlib.sha256(image_path.read_bytes()).hexdigest(),
                'group': '', 'split': '', 'reviewed_by': '', 'complete_annotation': False, 'objects': [],
                'source': {'local_manifest_key': sample['manifest_key'], 'local_manifest_version': sample['manifest_version'],
                           'session_id': group, 'frame_id': frame['frame_id']},
                'teacher_proposal': {'objects': frame['objects'], 'summary': frame['summary'], 'model': MODEL},
            })
    document = {'schema_version': 1, 'names': __import__('pipeline').COCO, 'samples': rows}
    temporary = review_path.with_suffix('.json.tmp')
    temporary.write_text(json.dumps(document, indent=2, allow_nan=False) + '\n', encoding='utf-8')
    os.chmod(temporary, 0o600)
    os.replace(temporary, review_path)


def label_local(queue: Path, *, home: Path = DEFAULT_HOME, confirm=input, open_browser=webbrowser.open) -> int:
    queue = queue.expanduser().resolve()
    index_path = queue / 'local_queue.json'
    if not queue.is_dir() or not index_path.is_file():
        raise ChatGPTError('Queue folder must come from fetch_local_queue.py and contain local_queue.json.')
    index = json.loads(index_path.read_text(encoding='utf-8'))
    if index.get('schema_version') != 1 or not isinstance(index.get('samples'), list):
        raise ChatGPTError('Unsupported local queue index.')
    proposal_path = queue / 'chatgpt-proposals.json'
    pause_path = queue / 'chatgpt-paused.json'
    proposal_document = json.loads(proposal_path.read_text()) if proposal_path.exists() else {'schema_version': 1, 'model': MODEL, 'proposals': {}}
    proposals = proposal_document['proposals']
    pending = [sample for sample in index['samples']
               if f"{sample['sample_id']}:{sample['manifest_version']}" not in proposals]
    if not pending:
        _materialize_review(queue, index, proposals)
        print('No unlabeled Local Mac samples are waiting.')
        return 0
    if pause_path.exists():
        pause = json.loads(pause_path.read_text(encoding='utf-8'))
        message = ('ChatGPT previously reported this app’s usage limit.' if pause.get('reason') == 'chatgpt_usage_limit'
                   else 'ChatGPT previously paused labeling with HTTP 429.')
        print(message)
        if confirm('Have you checked usage and want to resume labeling? [y/N] ').strip().lower() not in ('y', 'yes'):
            raise InferencePaused('Queue remains paused after a previous ChatGPT 429 response.')
        pause_path.unlink()
    credential_path = home / 'credentials.json'
    if not credential_path.is_file():
        saved = sign_in(home, open_browser=open_browser, confirm=confirm)
    else:
        saved = _read_json(credential_path)
    _usage_prompt(len(pending), confirm=confirm, open_browser=open_browser)
    discovery = _discovery()
    try:
        saved = _credentials(home, discovery)
    except ReauthenticateRequired:
        saved = sign_in(home, open_browser=open_browser, confirm=confirm)
    if 'chatgpt.tokens.use.direct' not in saved.get('scope', []):
        raise ChatGPTError('ChatGPT plan-use permission is not enabled; no image requests were sent.')
    _ensure_model(saved['access_token'])
    requests_made = 0
    for sample in pending:
        key = f"{sample['sample_id']}:{sample['manifest_version']}"
        if key in proposals:
            continue
        frames = sample.get('frames', [])
        if not 1 <= len(frames) <= 3:
            raise ChatGPTError('A local sample must contain one to three sampled image frames.')
        images, predictions, expected = [], [], []
        for frame in frames:
            image_path = (queue / frame['image_file']).resolve()
            if not image_path.is_relative_to(queue) or not image_path.is_file():
                raise ChatGPTError('Queued frame image is missing or unsafe.')
            raw = image_path.read_bytes()
            if not 0 < len(raw) <= 3_000_000:
                raise ChatGPTError('Queued frame image exceeds the 3 MB request bound.')
            images.append((frame['frame_id'], raw))
            predictions.append(frame.get('predictions', []))
            expected.append(frame['frame_id'])
        try:
            response = _stream_response(saved['access_token'], images, predictions)
        except (UsageLimitReached, InferencePaused) as exc:
            reason = 'chatgpt_usage_limit' if isinstance(exc, UsageLimitReached) else 'chatgpt_http_429'
            _atomic_json(pause_path, {'schema_version': 1, 'reason': reason,
                                      'sample_id': sample['sample_id'], 'paused_at': int(time.time())})
            raise
        checked = _validate_proposal(response, expected)
        proposals[key] = {
            'sample_id': sample['sample_id'], 'manifest_key': sample['manifest_key'],
            'manifest_version': sample['manifest_version'], 'session_id': sample['session_id'],
            'frames': checked, 'model': MODEL, 'created_at': int(time.time()),
        }
        _atomic_json(proposal_path, proposal_document)
        _materialize_review(queue, index, proposals)
        requests_made += 1
    if not proposal_path.exists():
        _atomic_json(proposal_path, proposal_document)
        _materialize_review(queue, index, proposals)
    pause_path.unlink(missing_ok=True)
    print(f'ChatGPT ({MODEL}) produced proposals for {requests_made} sample(s); all annotations remain unapproved in {queue / "review.json"}.')
    return requests_made
