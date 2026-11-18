import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

BINARY = Path(sys.argv.pop(1)).resolve()
WORK = Path(sys.argv.pop(1)).resolve()
ROOT = Path(__file__).resolve().parents[1]
SCENARIOS = Path('Tools/WindowLab/Scenarios')


class WindowLabCLITests(unittest.TestCase):
    def run_cli(self, *arguments, cwd=ROOT):
        env = dict(os.environ, LLVM_PROFILE_FILE=str(WORK / 'windowlab-%p.profraw'))
        return subprocess.run([str(BINARY), *arguments], cwd=cwd, env=env,
                              capture_output=True, text=True, timeout=10)

    def run_transition_replay(self, steps):
        with tempfile.TemporaryDirectory(dir=WORK) as directory:
            root = Path(directory)
            scenarios = root / SCENARIOS
            scenarios.mkdir(parents=True)
            (scenarios / 'close-verification.json').write_text(json.dumps(
                dict(name='close-verification', steps=steps)))
            return self.run_cli('transitionReplay', 'close-verification', cwd=root)

    def test_modes_are_explicit(self):
        for args in [(), ('unknown-mode',)]:
            with self.subTest(args=args):
                result = self.run_cli(*args)
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertIn('Specify a mode', result.stderr)

    def test_all_committed_replays(self):
        scenarios = sorted((ROOT / SCENARIOS).glob('*.json'))
        self.assertTrue(scenarios, 'No replay fixtures found')
        for scenario in scenarios:
            with self.subTest(scenario=scenario.name):
                fixture = json.loads(scenario.read_text(encoding='utf-8'))
                if 'mode' in fixture:
                    mode = fixture['mode']
                elif not scenario.stem.endswith('-replay'):
                    continue
                elif scenario.stem.startswith('placement-'):
                    mode = 'placementReplay'
                elif scenario.stem in ('focused-active-replay', 'close-timeout-replay'):
                    mode = 'transitionReplay'
                else:
                    mode = 'replay'
                self.assertIn(mode, ('replay', 'placementReplay', 'transitionReplay'),
                              'Fixture has an unsupported replay mode')
                result = self.run_cli(mode, scenario.stem)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_identity_replay_requires_tracked_endpoints_even_for_unstable_identity(self):
        for step_index in (0, -1):
            with self.subTest(step_index=step_index), tempfile.TemporaryDirectory(dir=WORK) as directory:
                root = Path(directory)
                scenarios = root / SCENARIOS
                scenarios.mkdir(parents=True)
                source = ROOT / SCENARIOS / 'cg-window-number-reuse-replay.json'
                scenario = json.loads(source.read_text())
                for observation in scenario['steps'][step_index]['observations']:
                    observation['track'] = False
                (scenarios / source.name).write_text(json.dumps(scenario))

                result = self.run_cli('replay', source.stem, cwd=root)

                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn('replay scenario requires tracked endpoints', result.stderr)

    def test_transition_replay_accepts_a_confirmed_pending_close(self):
        window = dict(source='coreGraphics', pid=42, cgWindowID=21, title='Fixture',
                      bounds='0:30:800:600', isMinimized=False)
        result = self.run_transition_replay([
            dict(label='baseline', observation=dict(window, kind='appeared'), expectedStatus='inactive'),
            dict(label='confirmation', observation=dict(window, kind='disappeared', atSeconds=1),
                 trackCloseAtSeconds=0.5, expectedStatus='closedPending'),
        ])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('status: closedPending', result.stdout)

    def test_transition_replay_rejects_unconfirmed_close(self):
        window = dict(source='coreGraphics', pid=42, cgWindowID=21, title='Fixture',
                      kind='disappeared', bounds='0:30:800:600', isMinimized=False, atSeconds=1)
        cases = [
            dict(label='unknown window', observation=window),
            dict(label='close request for unknown window', observation=window, trackCloseAtSeconds=0.5),
            dict(label='filtered observation', observation=dict(
                window, bundleIdentifier='com.tencent.xinWeChat', title='Favorites')),
        ]
        for case in cases:
            with self.subTest(case=case['label']):
                result = self.run_transition_replay([dict(case, expectedStatus='closedPending')])
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)

    def test_transition_replay_rejects_close_requested_after_disappearance(self):
        window = dict(source='coreGraphics', pid=42, cgWindowID=21, title='Fixture',
                      bounds='0:30:800:600', isMinimized=False)
        result = self.run_transition_replay([
            dict(label='baseline', observation=dict(window, kind='appeared'), expectedStatus='inactive'),
            dict(label='first disappearance', observation=dict(window, kind='disappeared', atSeconds=1),
                 expectedStatus='disappeared'),
            dict(label='duplicate disappearance', observation=dict(window, kind='disappeared', atSeconds=3),
                 trackCloseAtSeconds=2, expectedStatus='closedPending'),
        ])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('unexpected lifecycle status', result.stderr)

    def test_transition_replay_rejects_close_confirmation_from_different_owner(self):
        window = dict(source='coreGraphics', pid=42, cgWindowID=21, title='Fixture',
                      bounds='0:30:800:600', isMinimized=False)
        baseline = dict(label='baseline', observation=dict(window, kind='appeared'), expectedStatus='inactive')
        request = dict(label='close request', observation=dict(window, kind='unchanged', atSeconds=0.5),
                       trackCloseAtSeconds=0.5, expectedStatus='inactive')
        unrelated = dict(label='different process', observation=dict(window, pid=43, kind='disappeared', atSeconds=1),
                         expectedStatus='closedPending')
        replacement = dict(label='window number reused', observation=dict(window, pid=43, kind='appeared', atSeconds=0.75),
                           expectedStatus='inactive')
        cases = {
            'foreign request': [baseline, dict(unrelated, trackCloseAtSeconds=0.5)],
            'foreign disappearance': [baseline, request, unrelated],
            'replacement disappearance': [baseline, request, replacement, unrelated],
        }
        for case, steps in cases.items():
            with self.subTest(case=case):
                result = self.run_transition_replay(steps)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn('status: ' + ('disappeared' if case == 'replacement disappearance' else 'discarded'),
                              result.stdout)

    def test_transition_replay_keeps_reused_number_active_when_old_owner_closes(self):
        window = dict(source='coreGraphics', pid=42, cgWindowID=21, title='Fixture',
                      bounds='0:30:800:600', isMinimized=False)
        result = self.run_transition_replay([
            dict(label='baseline', observation=dict(window, kind='appeared'), expectedStatus='inactive'),
            dict(label='close request', observation=dict(window, kind='unchanged', atSeconds=0.5),
                 trackCloseAtSeconds=0.5, expectedStatus='inactive'),
            dict(label='window number reused',
                 observation=dict(window, pid=43, kind='appeared', isFocusedWindow=True, atSeconds=0.75),
                 expectedStatus='active'),
            dict(label='old window closed', observation=dict(window, kind='disappeared', atSeconds=1),
                 expectedStatus='closedPending'),
            dict(label='new window remains active', observation=dict(window, pid=43, kind='unchanged', atSeconds=1.25),
                 expectedStatus='active'),
        ])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_transition_replay_rejects_inexact_native_close_evidence(self):
        window = dict(source='coreGraphics', pid=42, cgWindowID=21, title='Fixture',
                      bounds='0:30:800:600', isMinimized=False)
        baseline = dict(label='baseline', observation=dict(window, kind='appeared'), expectedStatus='inactive')
        request = dict(label='close request', observation=dict(window, kind='unchanged', atSeconds=0.5),
                       trackCloseAtSeconds=0.5, expectedStatus='inactive')
        different = dict(label='different window', observation=dict(window, cgWindowID=22, kind='disappeared', atSeconds=1),
                         expectedStatus='discarded')
        no_number = dict(label='unknown window number',
                         observation=dict(window, source='accessibility', cgWindowID=None, kind='disappeared', atSeconds=1),
                         expectedStatus='disappeared')
        replacement = dict(label='new seat number', observation=dict(window, cgWindowID=22, kind='appeared', atSeconds=0.75),
                           expectedStatus='inactive')
        reopened = dict(label='original window visible', observation=dict(window, kind='appeared', atSeconds=1.25),
                        expectedStatus='inactive')
        original_gone = dict(label='original window gone', observation=dict(window, kind='disappeared', atSeconds=1.5),
                             expectedStatus='disappeared')
        cases = {
            'registration': [baseline, dict(different, trackCloseAtSeconds=0.5), reopened, original_gone],
            'different number': [baseline, request, different, dict(original_gone, expectedStatus='closedPending')],
            'missing number': [baseline, request, no_number, reopened, original_gone],
            'number changed while pending': [baseline, request, replacement, dict(different, expectedStatus='disappeared')],
        }
        for case, steps in cases.items():
            with self.subTest(case=case):
                result = self.run_transition_replay(steps)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_transition_replay_rejects_ax_only_close_confirmation(self):
        window = dict(source='accessibility', pid=42, title='Fixture', bounds='0:30:800:600', isMinimized=False)
        result = self.run_transition_replay([
            dict(label='baseline', observation=dict(window, kind='appeared'), expectedStatus='inactive'),
            dict(label='close request', observation=dict(window, kind='unchanged', atSeconds=0.5),
                 trackCloseAtSeconds=0.5, expectedStatus='inactive'),
            dict(label='window missing from AX', observation=dict(window, kind='disappeared', atSeconds=1),
                 expectedStatus='disappeared'),
        ])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_transition_replay_rejects_ax_disappearance_with_a_remembered_window_number(self):
        window = dict(source='coreGraphics', pid=42, cgWindowID=21, title='Fixture',
                      bounds='0:30:800:600', isMinimized=False)
        result = self.run_transition_replay([
            dict(label='baseline', observation=dict(window, kind='appeared'), expectedStatus='inactive'),
            dict(label='close request', observation=dict(window, kind='unchanged', atSeconds=0.5),
                 trackCloseAtSeconds=0.5, expectedStatus='inactive'),
            dict(label='AX loss with cached number',
                 observation=dict(window, source='accessibility', kind='disappeared', atSeconds=1),
                 expectedStatus='disappeared'),
            dict(label='later Core Graphics confirmation',
                 observation=dict(window, kind='disappeared', atSeconds=1.25), expectedStatus='closedPending'),
        ])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_transition_replay_keeps_rebound_window_and_its_close_request(self):
        window = dict(source='coreGraphics', pid=42, cgWindowID=21, title='Fixture',
                      bounds='0:30:800:600', isMinimized=False)
        replacement = dict(window, cgWindowID=22, isFocusedWindow=True)
        for appearance in ('appeared', 'restored'):
            with self.subTest(appearance=appearance):
                result = self.run_transition_replay([
                    dict(label='baseline', observation=dict(window, kind='appeared'), expectedStatus='inactive'),
                    dict(label='old close request', observation=dict(window, kind='unchanged', atSeconds=0.5),
                         trackCloseAtSeconds=0.5, expectedStatus='inactive'),
                    dict(label='new native window', observation=dict(replacement, kind=appearance, atSeconds=0.75),
                         expectedStatus='active'),
                    dict(label='new close request', observation=dict(replacement, kind='unchanged', atSeconds=0.9),
                         trackCloseAtSeconds=0.9, expectedStatus='active'),
                    dict(label='late disappearance of old window',
                         observation=dict(window, kind='disappeared', atSeconds=1), expectedStatus='discarded'),
                    dict(label='replacement remains active',
                         observation=dict(replacement, kind='unchanged', atSeconds=1.25), expectedStatus='active'),
                    dict(label='exact confirmation of new close request',
                         observation=dict(replacement, kind='disappeared', atSeconds=1.5), expectedStatus='closedPending'),
                ])
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn('new native window\n  identity: cg-21', result.stdout)

    def test_transition_replay_retires_request_after_early_disappearance(self):
        window = dict(source='coreGraphics', pid=42, cgWindowID=21, title='Fixture',
                      bounds='0:30:800:600', isMinimized=False)
        result = self.run_transition_replay([
            dict(label='baseline', observation=dict(window, kind='appeared'), expectedStatus='inactive'),
            dict(label='early disappearance', observation=dict(window, kind='disappeared', atSeconds=0.25),
                 trackCloseAtSeconds=0.5, expectedStatus='disappeared'),
            dict(label='duplicate disappearance', observation=dict(window, kind='disappeared', atSeconds=1),
                 expectedStatus='disappeared'),
            dict(label='reopened', observation=dict(window, kind='appeared', atSeconds=1.25),
                 expectedStatus='inactive'),
            dict(label='disappearance after reopening', observation=dict(window, kind='disappeared', atSeconds=1.5),
                 expectedStatus='disappeared'),
        ])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_identity_replay_omits_uncomputed_lifecycle(self):
        result = self.run_cli('replay', 'minimize-restore-replay')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('minimized=true', result.stdout)
        self.assertNotIn('new_state:', result.stdout)

    def test_invalid_replays_fail_without_a_trap(self):
        observation = dict(kind='unchanged', source='accessibility', pid=42, isMinimized=False,
                           title='Fixture', bounds='0:30:800:600')
        replay = dict(name='fixture', expectedStableIdentity=False,
                      steps=[dict(label='one', observations=[observation])])
        cases = [
            ('replay', '{broken'),
            ('replay', dict(replay, steps=[dict(label='one', observations=[dict(observation, kind='invalid')])])),
            ('replay', dict(replay, steps=[dict(label='one', observations=[dict(observation, source='invalid')])])),
            ('replay', dict(replay, steps=[dict(label='one', observations=[dict(observation, bounds='1e30:0:800:600')])])),
            ('placementReplay', dict(name='duplicate', initialOrderedWindowIDs=['one', 'one'], steps=[])),
            ('placementReplay', dict(name='status', initialOrderedWindowIDs=['one'], steps=[
                dict(label='one', windowID='one', newStatus='invalid', atSeconds=0, expectedOrder=['one'])])),
        ]
        with tempfile.TemporaryDirectory(dir=WORK) as directory:
            root = Path(directory)
            scenarios = root / SCENARIOS
            scenarios.mkdir(parents=True)
            for index, (mode, payload) in enumerate(cases):
                name = f'invalid-{index}'
                (scenarios / f'{name}.json').write_text(payload if isinstance(payload, str) else json.dumps(payload))
                with self.subTest(mode=mode, index=index):
                    result = self.run_cli(mode, name, cwd=root)
                    self.assertEqual(result.returncode, 64, result.stdout + result.stderr)
            escaped = self.run_cli('replay', '../outside', cwd=root)
            self.assertEqual(escaped.returncode, 64, escaped.stderr)


if __name__ == '__main__':
    WORK.mkdir(parents=True, exist_ok=True)
    unittest.main()
