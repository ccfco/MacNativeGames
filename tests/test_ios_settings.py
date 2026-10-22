"""The iPad Settings pane's mode -> environment mapping, without UIKit or a device."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class IOSSettings(unittest.TestCase):
    def test_picture_and_frame_modes(self):
        compiler = shutil.which('cc')
        if not compiler:
            self.skipTest('A C compiler is required')
        with tempfile.TemporaryDirectory() as directory:
            executable = Path(directory) / 'ios-settings'
            build = subprocess.run(
                [compiler, '-std=c11', '-O2', '-Wall', '-Wextra', '-Werror',
                 '-I', str(ROOT / 'games/totk/ios/Sources'),
                 str(ROOT / 'tests/test_ios_settings.c'),
                 str(ROOT / 'games/totk/ios/Sources/settings_map.c'),
                 '-o', str(executable)],
                capture_output=True, text=True)
            self.assertEqual(build.returncode, 0, build.stdout + build.stderr)
            run = subprocess.run([str(executable)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stdout + run.stderr)
            self.assertIn('ios settings ok', run.stdout)
