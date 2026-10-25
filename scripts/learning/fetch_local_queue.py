#!/usr/bin/env python3
"""Fetch Local Mac teacher sessions from the isolated private S3 queue."""
import argparse
import json
import subprocess
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
        fetched = 0
        for item in manifests:
            key = item['Key']
            aws('s3api', 'get-object', '--bucket', BUCKET, '--key', key, str(target / Path(key).name))
            doc = json.loads((target / Path(key).name).read_text())
            if doc.get('learning_mode') != 'local_mac' or doc.get('consent') is not True:
                raise ValueError('Unexpected mode or missing consent in local queue manifest')
            media = [(doc['image_key'], doc['image_version']), (doc['clip_key'], doc['clip_version'])]
            media.extend((frame['image_key'], frame['image_version']) for frame in doc.get('frame_images', []))
            for media_key, version in media:
                if not media_key.startswith('local/raw/') or not version:
                    raise ValueError('Unexpected or unversioned object in local queue manifest')
                destination = target / Path(media_key).name
                aws('s3api', 'get-object', '--bucket', BUCKET, '--key', media_key,
                    '--version-id', version, str(destination))
            fetched += 1
        print(f'Fetched {fetched} Local Mac queue samples into {target}; S3 objects remain queued.')
    except Exception:
        # Keep partial output for inspection and never delete source objects.
        raise


if __name__ == '__main__':
    main()
