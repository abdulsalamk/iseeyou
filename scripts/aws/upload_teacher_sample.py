#!/usr/bin/env python3
"""Opt-in manual uploader for the shadow teacher pilot; never reads camera feeds."""
import argparse
import hashlib
import json
import subprocess
import tempfile
import uuid
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--profile', default='abdul')
    parser.add_argument('--image', type=Path, required=True)
    parser.add_argument('--metadata', type=Path, required=True,
                        help='JSON: frame_id, captured_at, model_version, predictions (normalized xyxy boxes)')
    parser.add_argument('--consent', action='store_true', required=True,
                        help='Confirm this specific image may be uploaded for cloud analysis')
    args = parser.parse_args()
    image = args.image.read_bytes()
    if not 0 < len(image) <= 3000000:
        parser.error('Image must be at most 3 MB')
    suffix = 'png' if image.startswith(b'\x89PNG\r\n\x1a\n') else 'jpg' if image.startswith(b'\xff\xd8\xff') else None
    if not suffix:
        parser.error('Expected JPEG or PNG')
    import importlib.util
    spec = importlib.util.spec_from_file_location('teacher', Path(__file__).resolve().parents[2] / 'infra/teacher/lambda/teacher.py')
    teacher = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(teacher)
    identifier = uuid.uuid4().hex
    bucket = 'iseeyou-teacher-data-885625664603-eu-west-2'
    image_key = f'raw/images/{identifier}.{suffix}'
    manifest = json.loads(args.metadata.read_text())
    manifest.update(schema_version=1, consent=True, image_key=image_key)
    teacher.validate_manifest(manifest)

    def aws(*command):
        result = subprocess.run(['aws', '--profile', args.profile, '--region', 'eu-west-2',
                                 '--output', 'json', *command], capture_output=True, text=True, check=True)
        return json.loads(result.stdout) if result.stdout.strip() else {}

    # Require the intended account before any upload. CLI credentials stay local.
    if aws('sts', 'get-caller-identity')['Account'] != '885625664603':
        raise SystemExit('AWS profile is connected to the wrong account')
    image_result = aws('s3api', 'put-object', '--bucket', bucket, '--key', image_key,
                       '--body', str(args.image.resolve()), '--server-side-encryption', 'AES256')
    manifest['image_version'] = image_result['VersionId']
    with tempfile.TemporaryDirectory(prefix='iseeyou-upload-') as temporary:
        path = Path(temporary) / 'manifest.json'
        path.write_text(json.dumps(manifest, allow_nan=False))
        path.chmod(0o600)
        key = f'raw/manifests/{identifier}.json'
        result = aws('s3api', 'put-object', '--bucket', bucket, '--key', key,
                     '--body', str(path), '--content-type', 'application/json',
                     '--server-side-encryption', 'AES256')
    identity = hashlib.sha256((key + ':' + result['VersionId']).encode()).hexdigest()
    print(json.dumps({'bucket': bucket, 'manifest_key': key, 'manifest_version': result['VersionId'],
                      'image_key': image_key, 'image_version': image_result['VersionId'],
                      'candidate_key': f'candidates/{identity}.json'}))

if __name__ == '__main__':
    main()
