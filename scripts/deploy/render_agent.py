#!/usr/bin/env python3
"""Render an inert LaunchAgent plist; never register or start it."""
import argparse
import os
from pathlib import Path
import plistlib
import sys


def render(template, home, python):
    if not Path(home).is_absolute() or not Path(python).is_absolute():
        raise ValueError('Home and Python paths must be absolute')
    data = plistlib.loads(template)
    def substitute(value):
        if isinstance(value, str):
            return value.replace('__HOME__', str(home)).replace('__PYTHON3__', str(python))
        if isinstance(value, list):
            return [substitute(v) for v in value]
        if isinstance(value, dict):
            return {k: substitute(v) for k, v in value.items()}
        return value
    return plistlib.dumps(substitute(data))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    output = Path(args.output).expanduser()
    payload = render(Path(__file__).with_name('com.iseeyou.deploy.plist.in').read_bytes(),
                     Path.home(), Path(sys.executable).resolve())
    # Preserve any existing user LaunchAgent; user must review/remove it explicitly.
    fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'wb') as f:
        f.write(payload)
    print('Rendered plist only. Review it before any launchctl command.')


if __name__ == '__main__':
    main()
