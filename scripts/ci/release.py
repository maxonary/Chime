#!/usr/bin/env python3
"""Native Xcode internal-only release. No third-party signing/upload service.

The upload entrypoint refuses local, PR, fork, stale-commit and disabled runs.
Pure helpers and verify-archive can be tested without Apple credentials.
"""
import base64
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import secrets
import shlex
import subprocess
import sys
import tempfile
import uuid

from changes import changed_paths, classify

TEAM = 'Q37KAF726J'
BUNDLES = {
    'maxonary.chime': 'IPHONE_PROFILE_BASE64',
    'maxonary.chime.watchkitapp': 'WATCH_PROFILE_BASE64',
    'maxonary.chime.watchkitapp.widgets': 'WIDGET_PROFILE_BASE64',
}
REQUIRED = ['APPLE_DISTRIBUTION_P12_BASE64', 'APPLE_DISTRIBUTION_P12_PASSWORD',
            *BUNDLES.values(), 'ASC_PRIVATE_KEY_BASE64', 'ASC_KEY_ID', 'ASC_ISSUER_ID',
            'TESTFLIGHT_BUILD_OFFSET', 'GH_TOKEN']


def run(args, quiet=False):
    result = subprocess.run(args, capture_output=quiet, check=False)
    if result.returncode:
        # Do not stringify args/CalledProcessError: security commands contain passwords.
        raise RuntimeError(f'{Path(args[0]).name} failed with exit code {result.returncode}')
    return result.stdout if quiet else b''


def build_number(offset, run_number, attempt):
    values = [offset, run_number, attempt]
    if any(not isinstance(v, str) or not re.fullmatch(r'[1-9][0-9]*', v) for v in values):
        raise ValueError('Build offset, run number and attempt must be positive integers')
    major = int(offset) + int(run_number)
    if major > 9999 or int(attempt) > 99:
        raise ValueError('Build namespace exhausted; review allocation before continuing')
    # Conservative three-component numeric namespace. Reruns get a new minor.
    return f'{major}.{int(attempt)}.0'


def export_options(profiles, certificate_sha1):
    if set(profiles) != set(BUNDLES):
        raise ValueError('Exactly the iPhone, Watch and widgets profiles are required')
    return {
        'method': 'app-store-connect', 'destination': 'upload', 'teamID': TEAM,
        'signingStyle': 'manual', 'signingCertificate': certificate_sha1,
        'provisioningProfiles': profiles, 'manageAppVersionAndBuildNumber': False,
        'testFlightInternalTestingOnly': True, 'uploadSymbols': True,
        'stripSwiftSymbols': True,
    }


def profile_uuid(profile, bundle, certificate_sha1, now=None):
    now = now or datetime.now(timezone.utc)
    expiry = profile.get('ExpirationDate')
    entitlements = profile.get('Entitlements', {})
    if not isinstance(expiry, datetime):
        raise ValueError('Profile expiration missing')
    if expiry.tzinfo is None:
        expiry = expiry.replace(tzinfo=timezone.utc)
    if expiry <= now or profile.get('TeamIdentifier') != [TEAM]:
        raise ValueError('Profile expired or belongs to a different team')
    if entitlements.get('application-identifier') != TEAM + '.' + bundle:
        raise ValueError('Provisioning profile does not match the exact bundle identifier')
    if entitlements.get('get-task-allow') is not False or 'ProvisionedDevices' in profile or profile.get('ProvisionsAllDevices'):
        raise ValueError('Only App Store distribution profiles are accepted')
    if certificate_sha1 not in [hashlib.sha1(cert).hexdigest().upper() for cert in profile.get('DeveloperCertificates', [])]:
        raise ValueError('Profile does not authorize the imported signing certificate')
    return str(uuid.UUID(profile['UUID'])).upper()


def prepare_project(project, number, profiles, certificate_sha1):
    """Mutate only the ephemeral runner checkout; no source version bump commit."""
    result = json.loads(json.dumps(project))
    counts = {bundle: [] for bundle in BUNDLES}
    for item in result['objects'].values():
        if item.get('isa') != 'XCBuildConfiguration':
            continue
        settings = item.get('buildSettings', {})
        bundle = settings.get('PRODUCT_BUNDLE_IDENTIFIER')
        if bundle is None:
            continue
        if bundle not in BUNDLES:
            raise ValueError('Unexpected target bundle identifier; update signing mappings')
        counts[bundle].append(item['name'])
        settings['CURRENT_PROJECT_VERSION'] = number
        if item['name'] == 'Release':
            settings.update({'CODE_SIGN_STYLE': 'Manual', 'DEVELOPMENT_TEAM': TEAM,
                             'CODE_SIGN_IDENTITY': certificate_sha1,
                             'PROVISIONING_PROFILE_SPECIFIER': profiles[bundle]})
    if any(sorted(configs) != ['Debug', 'Release'] for configs in counts.values()):
        raise ValueError('Expected Debug and Release configurations for all three app targets')
    return result


def verify_archive(archive, expected_number=None):
    applications = Path(archive) / 'Products' / 'Applications'
    roots = list(applications.glob('*.app'))
    if len(roots) != 1:
        raise ValueError('Archive must contain exactly one top-level iPhone application')
    root = roots[0]
    apps = [root, *root.rglob('*.app'), *root.rglob('*.appex')]
    found = {}
    for app in apps:
        with (app / 'Info.plist').open('rb') as source:
            info = plistlib.load(source)
        bundle = info['CFBundleIdentifier']
        if bundle in found:
            raise ValueError('Duplicate embedded application identifier')
        found[bundle] = (str(info['CFBundleVersion']), info['CFBundleShortVersionString'])
    if set(found) != set(BUNDLES) or len(set(found.values())) != 1:
        raise ValueError('Archive must embed iPhone, Watch and widgets with matching versions')
    if expected_number and next(iter(found.values()))[0] != expected_number:
        raise ValueError('Archive build number differs from the allocated number')
    # Check that the Watch and extension are embedded in the proper containers.
    watch = list((root / 'Watch').glob('*.app'))
    if len(watch) != 1 or len(list((watch[0] / 'PlugIns').glob('*.appex'))) != 1:
        raise ValueError('Expected embedded Watch application and its widget extension')
    print('Verified archive: iPhone + Watch + widgets, matching versions')
    return root


def assert_release_context(env):
    if (env.get('GITHUB_ACTIONS') != 'true' or env.get('RUNNER_ENVIRONMENT') != 'github-hosted'
            or env.get('GITHUB_EVENT_NAME') != 'push' or env.get('GITHUB_REF') != 'refs/heads/main'
            or env.get('GITHUB_REPOSITORY') != 'maxonary/Chime'
            or env.get('TESTFLIGHT_UPLOAD_ENABLED') != 'true'):
        raise ValueError('Upload requires an enabled main push on the trusted GitHub-hosted workflow')
    if not re.fullmatch(r'[0-9a-f]{40}', env.get('GITHUB_SHA', '')):
        raise ValueError('Invalid commit identity')
    missing = [name for name in REQUIRED if not env.get(name)]
    if missing:
        raise ValueError('Missing release configuration: ' + ', '.join(missing))
    if not re.fullmatch(r'[A-Z0-9]{10}', env['ASC_KEY_ID']):
        raise ValueError('Invalid App Store Connect key ID')
    uuid.UUID(env['ASC_ISSUER_ID'])


def assert_current_main(env):
    head = run(['git', 'rev-parse', 'HEAD'], quiet=True).decode().strip()
    current = run(['gh', 'api', f"repos/{env['GITHUB_REPOSITORY']}/git/ref/heads/main", '--jq', '.object.sha'], quiet=True).decode().strip()
    if head != env['GITHUB_SHA'] or current != head:
        raise ValueError('Refusing stale or mismatched main commit; let the newer run finish')


def decode_secret(env, name, destination):
    data = base64.b64decode(env[name], validate=True)
    if not data or len(data) > 2 * 1024 * 1024:
        raise ValueError('Invalid signing material size: ' + name)
    with open(destination, 'xb') as output:
        os.chmod(destination, 0o600)
        output.write(data)


def upload_internal():
    env = os.environ
    assert_release_context(env)
    with open(env['GITHUB_EVENT_PATH']) as source:
        event = json.load(source)
    if event['after'] != env['GITHUB_SHA'] or not classify(changed_paths('push', event))['upload']:
        raise ValueError('No application changes at the validated push commit')
    assert_current_main(env)
    number = build_number(env['TESTFLIGHT_BUILD_OFFSET'], env['GITHUB_RUN_NUMBER'], env['GITHUB_RUN_ATTEMPT'])
    print(f"Preparing internal TestFlight {number} from {env['GITHUB_SHA']}", flush=True)
    previous_keychains = shlex.split(run(['security', 'list-keychains', '-d', 'user'], quiet=True).decode())
    installed_profiles = []
    keychain_created = False
    with tempfile.TemporaryDirectory(prefix='chime-signing-', dir=env['RUNNER_TEMP']) as directory:
        private = Path(directory)
        keychain = str(private / 'signing.keychain-db')
        password = secrets.token_hex(32)
        try:
            p12 = private / 'distribution.p12'
            key = private / 'AuthKey.p8'
            decode_secret(env, 'APPLE_DISTRIBUTION_P12_BASE64', p12)
            decode_secret(env, 'ASC_PRIVATE_KEY_BASE64', key)
            run(['security', 'create-keychain', '-p', password, keychain], quiet=True)
            keychain_created = True
            run(['security', 'set-keychain-settings', '-lut', '21600', keychain], quiet=True)
            run(['security', 'unlock-keychain', '-p', password, keychain], quiet=True)
            run(['security', 'import', str(p12), '-k', keychain, '-P', env['APPLE_DISTRIBUTION_P12_PASSWORD'],
                 '-T', '/usr/bin/codesign', '-T', '/usr/bin/security'], quiet=True)
            run(['security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', password, keychain], quiet=True)
            run(['security', 'list-keychains', '-d', 'user', '-s', keychain, *previous_keychains], quiet=True)
            identities = run(['security', 'find-identity', '-v', '-p', 'codesigning', keychain], quiet=True).decode()
            matches = re.findall(r'\b([A-F0-9]{40}) "Apple Distribution:', identities)
            if len(matches) != 1:
                raise ValueError('P12 must contain exactly one valid Apple Distribution identity')
            certificate = matches[0]
            profiles = {}
            for bundle, secret_name in BUNDLES.items():
                source = private / (secret_name + '.mobileprovision')
                decode_secret(env, secret_name, source)
                profile = plistlib.loads(run(['security', 'cms', '-D', '-i', str(source)], quiet=True))
                identifier = profile_uuid(profile, bundle, certificate)
                profiles[bundle] = identifier
                # Current Xcode location and legacy location; neither is overwritten.
                for folder in ['Library/Developer/Xcode/UserData/Provisioning Profiles', 'Library/MobileDevice/Provisioning Profiles']:
                    target = Path.home() / folder / (identifier + '.mobileprovision')
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with target.open('xb') as output:
                        installed_profiles.append(target)
                        os.chmod(target, 0o600)
                        output.write(source.read_bytes())
            project_path = Path('chime.xcodeproj/project.pbxproj')
            project = json.loads(run(['plutil', '-convert', 'json', '-o', '-', str(project_path)], quiet=True))
            updated = prepare_project(project, number, profiles, certificate)
            # Xcode accepts XML property lists as well as OpenStep project files.
            project_path.write_bytes(plistlib.dumps(updated, sort_keys=False))
            archive = private / 'Chime.xcarchive'
            run(['xcodebuild', '-project', 'chime.xcodeproj', '-scheme', 'Chime', '-configuration', 'Release',
                 '-destination', 'generic/platform=iOS', '-derivedDataPath', str(private / 'DerivedData'),
                 '-archivePath', str(archive), 'archive'])
            root = verify_archive(archive, number)
            run(['codesign', '--verify', '--deep', '--strict', str(root)])
            options = private / 'ExportOptions.plist'
            options.write_bytes(plistlib.dumps(export_options(profiles, certificate)))
            assert_current_main(env)  # Check again after the long archive, immediately before upload.
            run(['xcodebuild', '-exportArchive', '-archivePath', str(archive), '-exportPath', str(private / 'export'),
                 '-exportOptionsPlist', str(options), '-authenticationKeyPath', str(key),
                 '-authenticationKeyID', env['ASC_KEY_ID'], '-authenticationKeyIssuerID', env['ASC_ISSUER_ID']])
            print(f'Uploaded internal-only build {number}; Apple processing and internal-group availability are separate.')
            if env.get('GITHUB_STEP_SUMMARY'):
                with open(env['GITHUB_STEP_SUMMARY'], 'a') as summary:
                    summary.write(f'Internal-only TestFlight upload: **{number}**, commit `{env["GITHUB_SHA"]}`.\n\nApple processing remains pending; no external testing or App Store submission.\n')
        finally:
            for target in installed_profiles:
                try:
                    target.unlink(missing_ok=True)
                except OSError:
                    print("Warning: profile cleanup failed; discard this ephemeral runner", file=sys.stderr)
            if keychain_created:
                # Cleanup must continue even if one security operation fails.
                subprocess.run(['security', 'list-keychains', '-d', 'user', '-s', *previous_keychains], capture_output=True)
                subprocess.run(['security', 'delete-keychain', keychain], capture_output=True)
            # TemporaryDirectory deletes private keys, P12, profiles, archives and export output.


if __name__ == '__main__':
    try:
        if len(sys.argv) in (3, 4) and sys.argv[1] == 'verify-archive':
            verify_archive(sys.argv[2], sys.argv[3] if len(sys.argv) == 4 else None)
        elif sys.argv[1:] == ['upload-internal']:
            upload_internal()
        else:
            raise ValueError('Usage: release.py verify-archive ARCHIVE [BUILD] | upload-internal')
    except (ValueError, RuntimeError, KeyError, OSError, plistlib.InvalidFileException) as error:
        # Only our diagnostics; never dump environment variables or command arguments.
        print(f'Release stopped: {error}', file=sys.stderr)
        sys.exit(1)
