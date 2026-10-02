import copy
from datetime import datetime, timedelta, timezone
import hashlib
from pathlib import Path
import plistlib
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from changes import classify, changed_paths
from release import BUNDLES, TEAM, REQUIRED, assert_current_main, assert_release_context, build_number, export_options, prepare_project, profile_uuid, verify_archive


class PipelineTests(unittest.TestCase):
    def test_path_filters_skip_gateway_and_docs_uploads(self):
        self.assertEqual(classify(['gateway/src/server.ts']), {'gateway': True, 'apple': False, 'upload': False})
        for paths in [['README.md'], ['ios/TESTFLIGHT.md', 'watch/SETUP.md'], ['docs/foo.md'], ['gateway/README.md']]:
            self.assertEqual(classify(paths), {'gateway': False, 'apple': False, 'upload': False})
        for path in ['chime Watch App/Views/Bubble.swift', 'Chime Widgets/Info.plist', 'chime.xcodeproj/project.pbxproj', 'watch/Chime.entitlements', 'ios/Asset.png']:
            self.assertEqual(classify([path]), {'gateway': False, 'apple': True, 'upload': True})
        for path in ['scripts/ci/release.py', '.github/workflows/chime-ci.yml']:
            self.assertEqual(classify([path]), {'gateway': True, 'apple': True, 'upload': False})
        self.assertEqual(classify(['watch/tests/AudioCodecTests.swift']), {'gateway': False, 'apple': True, 'upload': False})
        self.assertFalse(classify(['scripts/check-watch.sh'])['upload'])
        self.assertTrue(classify(['gateway/package-lock.json', 'chime Watch App/ChimeApp.swift'])['upload'])

    def test_full_diff_handles_renames_spaces_and_bursts(self):
        paths = [f'docs/{i}.md' for i in range(500)] + ['chime Watch App/Views/New Name.swift']
        with patch('changes.subprocess.check_output', return_value=('\0'.join(paths) + '\0').encode()) as command:
            result = changed_paths('pull_request', {'pull_request': {'base': {'sha': 'a' * 40}, 'head': {'sha': 'b' * 40}}})
            self.assertTrue(classify(result)['upload'])
            self.assertIn('--no-renames', command.call_args.args[0])
            self.assertIn('a' * 40 + '...' + 'b' * 40, command.call_args.args[0])
        with self.assertRaises(ValueError):
            changed_paths('workflow_run', {})

    def test_build_numbers_are_valid_monotonic_and_rerun_unique(self):
        self.assertEqual(build_number('1000', '12', '1'), '1012.1.0')
        numbers = [build_number('1000', '12', '1'), build_number('1000', '12', '2'), build_number('1000', '13', '1')]
        self.assertEqual(sorted(numbers, key=lambda s: tuple(map(int, s.split('.')))), numbers)
        for args in [('0', '1', '1'), ('1', '1', '100'), ('9999', '1', '1'), ('secret', '1', '1'), ('1', '-1', '1')]:
            with self.assertRaises(ValueError):
                build_number(*args)

    def test_internal_only_export_cannot_change_build_number_or_auto_sign(self):
        options = export_options(dict.fromkeys(BUNDLES, 'profile'), 'A' * 40)
        self.assertTrue(options['testFlightInternalTestingOnly'])
        self.assertFalse(options['manageAppVersionAndBuildNumber'])
        self.assertEqual(options['signingStyle'], 'manual')
        self.assertEqual(options['destination'], 'upload')
        self.assertEqual(options['teamID'], TEAM)
        with self.assertRaises(ValueError):
            export_options({'maxonary.chime': 'one'}, 'A' * 40)

    def test_all_targets_and_configurations_share_allocated_version(self):
        objects = {}
        for bundle in BUNDLES:
            for name in ['Debug', 'Release']:
                objects[bundle + name] = {'isa': 'XCBuildConfiguration', 'name': name, 'buildSettings': {'PRODUCT_BUNDLE_IDENTIFIER': bundle, 'CURRENT_PROJECT_VERSION': '8'}}
        source = {'objects': objects}
        updated = prepare_project(source, '1001.1.0', dict.fromkeys(BUNDLES, 'profile'), 'fingerprint')
        self.assertEqual({item['buildSettings']['CURRENT_PROJECT_VERSION'] for item in updated['objects'].values()}, {'1001.1.0'})
        self.assertEqual({item['buildSettings']['CURRENT_PROJECT_VERSION'] for item in source['objects'].values()}, {'8'})
        for item in updated['objects'].values():
            if item['name'] == 'Release':
                self.assertEqual(item['buildSettings']['PROVISIONING_PROFILE_SPECIFIER'], 'profile')
                self.assertEqual(item['buildSettings']['CODE_SIGN_STYLE'], 'Manual')
        broken = copy.deepcopy(source); broken['objects'].pop(next(iter(objects)))
        with self.assertRaises(ValueError):
            prepare_project(broken, '1001.1.0', dict.fromkeys(BUNDLES, 'profile'), 'fingerprint')

    def test_profiles_bind_team_bundle_certificate_and_distribution_type(self):
        cert = b'fixture certificate'
        profile = {'ExpirationDate': datetime.now(timezone.utc) + timedelta(days=1), 'TeamIdentifier': [TEAM],
                   'UUID': '11111111-2222-3333-4444-555555555555', 'DeveloperCertificates': [cert],
                   'Entitlements': {'application-identifier': TEAM + '.maxonary.chime', 'get-task-allow': False}}
        fingerprint = hashlib.sha1(cert).hexdigest().upper()
        self.assertEqual(profile_uuid(profile, 'maxonary.chime', fingerprint), profile['UUID'])
        for change in [{'TeamIdentifier': ['WRONG']}, {'ExpirationDate': datetime.now(timezone.utc) - timedelta(days=1)}, {'ProvisionedDevices': []}, {'DeveloperCertificates': [b'wrong']}]:
            with self.assertRaises(ValueError):
                profile_uuid({**profile, **change}, 'maxonary.chime', fingerprint)
        with self.assertRaises(ValueError):
            profile_uuid(profile, 'maxonary.chime.watchkitapp', fingerprint)
        development = copy.deepcopy(profile); development['Entitlements']['get-task-allow'] = True
        with self.assertRaises(ValueError):
            profile_uuid(development, 'maxonary.chime', fingerprint)

    def test_upload_guards_reject_prs_forks_local_runs_and_missing_secrets(self):
        env = {key: 'fixture' for key in REQUIRED}
        env.update({'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'github-hosted', 'GITHUB_EVENT_NAME': 'push',
                    'GITHUB_REF': 'refs/heads/main', 'GITHUB_REPOSITORY': 'maxonary/Chime', 'GITHUB_SHA': 'a' * 40,
                    'TESTFLIGHT_UPLOAD_ENABLED': 'true', 'ASC_KEY_ID': 'ABCDEFGHIJ', 'ASC_ISSUER_ID': '11111111-2222-3333-4444-555555555555'})
        assert_release_context(env)
        for key, value in [('GITHUB_EVENT_NAME', 'pull_request'), ('GITHUB_EVENT_NAME', 'pull_request_target'), ('GITHUB_REF', 'refs/heads/feature'), ('GITHUB_REPOSITORY', 'fork/Chime'), ('GITHUB_ACTIONS', ''), ('RUNNER_ENVIRONMENT', 'self-hosted'), ('TESTFLIGHT_UPLOAD_ENABLED', '')]:
            with self.assertRaises(ValueError):
                assert_release_context({**env, key: value})
        for key in REQUIRED:
            with self.assertRaisesRegex(ValueError, 'Missing release configuration'):
                assert_release_context({**env, key: ''})

    def test_stale_or_wrong_checkout_cannot_upload(self):
        env = {'GITHUB_SHA': 'a' * 40, 'GITHUB_REPOSITORY': 'maxonary/Chime'}
        with patch('release.run', side_effect=[b'a' * 40, b'a' * 40]):
            assert_current_main(env)
        for heads in [[b'b' * 40, b'a' * 40], [b'a' * 40, b'b' * 40]]:
            with patch('release.run', side_effect=heads), self.assertRaises(ValueError):
                assert_current_main(env)

    def test_archive_requires_embedded_watch_widgets_and_matching_builds(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / 'Products/Applications/chime.app'
            watch = root / 'Watch/watch.app'
            widgets = watch / 'PlugIns/widgets.appex'
            for path, bundle in zip([root, watch, widgets], BUNDLES):
                path.mkdir(parents=True, exist_ok=True)
                (path / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': bundle, 'CFBundleVersion': '1001.1.0', 'CFBundleShortVersionString': '1.0'}))
            self.assertEqual(verify_archive(directory, '1001.1.0'), root)
            with self.assertRaises(ValueError):
                verify_archive(directory, '1002.1.0')
            widget_info = widgets / 'Info.plist'
            info = plistlib.loads(widget_info.read_bytes()); info['CFBundleVersion'] = '8'
            widget_info.write_bytes(plistlib.dumps(info))
            with self.assertRaises(ValueError):
                verify_archive(directory)


if __name__ == '__main__':
    unittest.main()
