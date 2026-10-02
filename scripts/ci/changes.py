#!/usr/bin/env python3
"""Classify the complete git diff (no API pagination/300-file path-filter limit)."""
import json
import os
import subprocess


def classify(paths):
    gateway = apple = upload = False
    for path in paths:
        docs = path.endswith('.md') or path.startswith('docs/')
        pipeline = path.startswith(('.github/workflows/', 'scripts/ci/'))
        gateway |= pipeline or (path.startswith('gateway/') and not docs)
        app = not docs and path.startswith(('chime.xcodeproj/', 'chime Watch App/', 'Chime Widgets/', 'ios/', 'watch/'))
        tests_only = path.startswith('watch/tests/')
        apple |= pipeline or app or path == 'scripts/check-watch.sh'
        upload |= app and not tests_only and path != 'watch/SETUP.md' and not path.endswith('.sh')
    return {'gateway': gateway, 'apple': apple, 'upload': upload}


def changed_paths(event_name, event):
    if event_name == 'pull_request':
        base = event['pull_request']['base']['sha']
        head = event['pull_request']['head']['sha']
        revision = f'{base}...{head}'
    elif event_name == 'push':
        base, head = event['before'], event['after']
        if base == '0' * 40:
            return subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', '-z', head]).decode().split('\0')[:-1]
        revision = f'{base}..{head}'
    else:
        raise ValueError('Only pull_request and push events are supported')
    return subprocess.check_output(['git', 'diff', '--name-only', '--no-renames', '-z', revision]).decode().split('\0')[:-1]


if __name__ == '__main__':
    with open(os.environ['GITHUB_EVENT_PATH']) as source:
        result = classify(changed_paths(os.environ['GITHUB_EVENT_NAME'], json.load(source)))
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        for key, value in result.items():
            output.write(f'{key}={str(value).lower()}\n')
    print(json.dumps(result))
