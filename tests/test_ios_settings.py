"""The iPad Settings pane's mode -> environment mapping, without UIKit or a device."""
import plistlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class IOSSettings(unittest.TestCase):
    def _helper(self):
        compiler = shutil.which('cc')
        if not compiler:
            self.skipTest('A C compiler is required')
        directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, directory)
        executable = directory / 'ios-settings'
        build = subprocess.run(
            [compiler, '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
             '-I', str(ROOT / 'games/totk/ios/Sources'),
             str(ROOT / 'tests/test_ios_settings.c'),
             str(ROOT / 'games/totk/ios/Sources/settings_map.c'),
             '-o', str(executable)],
            capture_output=True, text=True)
        self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
        return executable

    def test_picture_and_frame_modes(self):
        run = subprocess.run([str(self._helper())], capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        self.assertIn('ios settings ok', run.stdout)

    def test_pane_values_are_accepted(self):
        executable = self._helper()
        with open(ROOT / 'games/totk/ios/Settings.bundle/Root.plist', 'rb') as file:
            root = plistlib.load(file)
        rows = {item['Key']: item for item in root['PreferenceSpecifiers'] if 'Key' in item}
        for key, flag in (('TOTK_IOS_PICTURE_MODE', '--picture'), ('TOTK_FPS_CAP', '--frame-cap')):
            self.assertIn(key, rows)
            row = rows[key]
            self.assertIn('Values', row)
            self.assertIn('Titles', row)
            self.assertIn('DefaultValue', row)
            values = row['Values']
            self.assertTrue(values, key)
            self.assertEqual(len(values), len(row['Titles']), key)
            self.assertEqual(len(values), len(set(values)), key)
            for value in values:
                with self.subTest(key=key, value=value):
                    run = subprocess.run([str(executable), flag, value], capture_output=True, text=True)
                    self.assertEqual(run.returncode, 0, f'{key}={value}: {run.stdout}{run.stderr}')
        run = subprocess.run([str(executable), '--defaults'], capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
        picture_default, frame_default = run.stdout.splitlines()
        self.assertEqual(picture_default, rows['TOTK_IOS_PICTURE_MODE']['DefaultValue'])
        self.assertEqual(frame_default, rows['TOTK_FPS_CAP']['DefaultValue'])

    def test_overlays_are_separate_switches(self):
        with open(ROOT / 'games/totk/ios/Settings.bundle/Root.plist', 'rb') as file:
            root = plistlib.load(file)
        rows = {item['Key']: item for item in root['PreferenceSpecifiers'] if 'Key' in item}
        # The runtime's single mode is derived from the two switches, so the pane must not offer a third state.
        self.assertNotIn('TOTK_HUD_MODE', rows)
        for key in ('TOTK_FPS_OVERLAY', 'TOTK_SHADER_OVERLAY'):
            self.assertIn(key, rows)
            self.assertEqual(rows[key]['Type'], 'PSToggleSwitchSpecifier')
            self.assertIs(rows[key]['DefaultValue'], True)
