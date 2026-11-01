#!/usr/bin/env python3
"""Fetch Local Mac teacher sessions from the isolated private S3 queue."""
import argparse
import base64
import hashlib
import json
import os
import subprocess
import tempfile
from pathlib import Path

BUCKET = 'iseeyou-teacher-data-885625664603-eu-west-2'


def aws(*args):
    result = subprocess.run(['aws', '--profile', 'abdul', '--region', 'eu-west-2',
        '--output', 'json', '--no-cli-pager', *args], capture_output=True, text=True, timeout=120)
    if result.returncode:
        raise RuntimeError('AWS queue access failed; credentials and service errors remain local')
    return json.loads(result.stdout) if result.stdout.strip() else {}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, help='New private output directory')
    parser.add_argument('--limit', type=int, default=100)
    args = parser.parse_args()
    if not 1 <= args.limit <= 1000:
        parser.error('--limit must be 1..1000')
    target = Path(args.output).expanduser().resolve()
    if target.exists():
        parser.error('Output already exists; use a new private directory')
    target.mkdir(mode=0o700, parents=True)
    try:
        identity = aws('sts', 'get-caller-identity')
        if identity.get('Account') != '885625664603':
            raise RuntimeError('Refusing to read queue from an unexpected AWS account')
        listing = aws('s3api', 'list-objects-v2', '--bucket', BUCKET,
                      '--prefix', 'local/raw/manifests/')
        manifests = sorted(listing.get('Contents', []), key=lambda row: row['LastModified'])[-args.limit:]
        queue_rows = []
        for item in manifests:
            key = item['Key']
            manifest_path = target / Path(key).name
            manifest_info = aws('s3api', 'get-object', '--bucket', BUCKET, '--key', key, str(manifest_path))
            doc = json.loads(manifest_path.read_text())
            if doc.get('learning_mode') != 'local_mac' or doc.get('consent') is not True:
                raise ValueError('Unexpected mode or missing consent in local queue manifest')
            media = [(doc['clip_key'], doc['clip_version'], doc['clip_sha256'])]
            frame_rows = doc.get('frame_images') or [{
                'image_key': doc['image_key'], 'image_version': doc.get('image_version'),
                'image_size': doc['image_size'], 'image_sha256': doc['image_sha256'],
                'frame_id': doc['frame_id'], 'captured_at': doc['captured_at'],
                'offset_seconds': 0, 'predictions': doc.get('predictions', []),
            }]
            frame_files = []
            for frame in frame_rows:
                media_key, version = frame['image_key'], frame.get('image_version')
                if not media_key.startswith('local/raw/') or not version:
                    raise ValueError('Unexpected or unversioned object in local queue manifest')
                destination = target / Path(media_key).name
                if not destination.exists():
                    aws('s3api', 'get-object', '--bucket', BUCKET, '--key', media_key,
                        '--version-id', version, str(destination))
                digest = base64.b64encode(hashlib.sha256(destination.read_bytes()).digest()).decode('ascii')
                if digest != frame['image_sha256']:
                    raise ValueError('Downloaded frame checksum does not match the versioned manifest')
                frame_files.append({
                    'frame_id': frame['frame_id'], 'image_file': destination.name,
                    'captured_at': frame['captured_at'], 'offset_seconds': frame.get('offset_seconds', 0),
                    'image_sha256': frame['image_sha256'], 'predictions': frame.get('predictions', []),
                })
            for media_key, version, expected_checksum in media:
                if not media_key.startswith('local/raw/') or not version:
                    raise ValueError('Unexpected or unversioned object in local queue manifest')
                destination = target / Path(media_key).name
                if not destination.exists():
                    aws('s3api', 'get-object', '--bucket', BUCKET, '--key', media_key,
                        '--version-id', version, str(destination))
                digest = base64.b64encode(hashlib.sha256(destination.read_bytes()).digest()).decode('ascii')
                if digest != expected_checksum:
                    raise ValueError('Downloaded clip checksum does not match the versioned manifest')
            queue_rows.append({
                'sample_id': doc['sample_id'], 'session_id': doc['session_id'],
                'manifest_file': manifest_path.name, 'manifest_key': key,
                'manifest_version': manifest_info['VersionId'], 'frames': frame_files,
            })
        index_path = target / 'local_queue.json'
        fd, temporary = tempfile.mkstemp(prefix='.local_queue.', dir=target)
        with os.fdopen(fd, 'w', encoding='utf-8') as stream:
            json.dump({'schema_version': 1, 'samples': queue_rows}, stream, indent=2, allow_nan=False)
            stream.write('\n')
        os.chmod(temporary, 0o600)
        os.replace(temporary, index_path)
        print(f'Fetched {len(queue_rows)} Local Mac samples into {target}; S3 objects remain queued.')
    except Exception:
        # Keep partial output for inspection and never delete source objects.
        raise


if __name__ == '__main__':
    main()
