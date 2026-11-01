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


class WindowLabCLITests(unittest.TestCase):
    def run_cli(self, *arguments, cwd=ROOT):
        env = dict(os.environ, LLVM_PROFILE_FILE=str(WORK / 'windowlab-%p.profraw'))
        return subprocess.run([str(BINARY), *arguments], cwd=cwd, env=env,
                              capture_output=True, text=True, timeout=10)

    def test_modes_are_explicit(self):
        for args in [(), ('unknown-mode',)]:
            with self.subTest(args=args):
                result = self.run_cli(*args)
                self.assertEqual(result.returncode, 64, result.stderr)
                self.assertIn('Specify a mode', result.stderr)

    def test_all_committed_replays(self):
        for scenario in sorted((ROOT / 'Tools/WindowLab/Scenarios').glob('*-replay.json')):
            mode = ('placementReplay' if scenario.stem.startswith('placement-') else
                    'transitionReplay' if scenario.stem in ['focused-active-replay', 'close-timeout-replay'] else 'replay')
            with self.subTest(scenario=scenario.name):
                result = self.run_cli(mode, scenario.stem)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

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
            scenarios = root / 'Tools/WindowLab/Scenarios'
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
