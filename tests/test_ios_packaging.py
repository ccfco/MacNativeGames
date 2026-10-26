"""games/totk/ios/tools/build_ipa.py: what an iOS build leaves out of the way and copies (2026-10-23)."""
import sys
import tempfile
import time
import unittest
from pathlib import Path

TOOLS = Path(__file__).resolve().parents[1]/'games/totk/ios/tools'
sys.path.insert(0, str(TOOLS))
import build_ipa  # noqa: E402
import install_device  # noqa: E402


class Discard(unittest.TestCase):
    def test_a_folder_is_moved_aside_at_once_and_deleted_later(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); old = root/'TOTK.app'
            (old/'GameData/shader-seed').mkdir(parents=True)
            for i in range(50):
                (old/f'GameData/shader-seed/{i}.metallib').write_bytes(b'x')
            build_ipa.discard(old)
            self.assertFalse(old.exists())   # the path is free for the new build right away
            for _ in range(100):
                if not any(root.iterdir()):
                    break
                time.sleep(0.05)
            self.assertEqual(list(root.iterdir()), [])   # and the moved folder is gone once the background delete ran

    def test_a_missing_path_is_fine(self):
        with tempfile.TemporaryDirectory() as d:
            build_ipa.discard(Path(d)/'none')


class SeedBeside(unittest.TestCase):
    """--ios-game-data documents leaves the startup shaders beside the output; the README installs the .ipa, and the
    seed was pushed only for an .app folder, so the game said 'No shaders' after a successful install."""
    def layout(self, root, output):
        (root/'Tears of the Kingdom-shader-seed').mkdir()
        (root/'Tears of the Kingdom-shader-seed/fingerprint.txt').write_text('f' * 64)
        app = root/'signed/Payload/TOTK.app'; (app/'GameData').mkdir(parents=True)
        return root/output, app

    def test_an_ipa_gets_its_seed(self):
        with tempfile.TemporaryDirectory() as d:
            ipa, app = self.layout(Path(d), 'Tears of the Kingdom.ipa'); ipa.write_bytes(b'PK')
            self.assertEqual(install_device.seed_beside(ipa, app), Path(d)/'Tears of the Kingdom-shader-seed')

    def test_an_app_folder_gets_its_seed(self):
        with tempfile.TemporaryDirectory() as d:
            out, app = self.layout(Path(d), 'Tears of the Kingdom.app'); out.mkdir()
            self.assertEqual(install_device.seed_beside(out, out), Path(d)/'Tears of the Kingdom-shader-seed')

    def test_an_app_that_carries_its_seed_gets_none(self):
        with tempfile.TemporaryDirectory() as d:
            ipa, app = self.layout(Path(d), 'Tears of the Kingdom.ipa'); (app/'GameData/shader-seed').mkdir()
            self.assertIsNone(install_device.seed_beside(ipa, app))


def read_pack(parts):
    """ios/Sources/main.m seed_unpack, in Python: the files of a pack stream cut into parts."""
    data = b''.join(p.read_bytes() for p in parts); assert data[:9] == b'TOTKPACK1'; at, out = 9, {}
    while True:
        nl = int.from_bytes(data[at:at + 2], 'little'); at += 2
        if not nl: return out, at == len(data)
        name = data[at:at + nl].decode(); at += nl
        size = int.from_bytes(data[at:at + 8], 'little'); at += 8
        out[name] = data[at:at + size]; at += size


class ShaderPack(unittest.TestCase):
    def test_files_come_back_whole_across_part_boundaries(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d); seed = root/'seed'; seed.mkdir(); parts = []
            files = {'a.metal': b'x' * 1000, 'b.json': b'{}', 'empty.variants': b'', 'c.metallib': bytes(range(256)) * 3}
            for n, b in files.items():
                (seed/n).write_bytes(b)
            install_device.write_pack(seed, sorted(files), root, 'shader-seed-x', 97, parts.append)
            self.assertGreater(len(parts), 10)   # cut in the middle of names, sizes and contents
            self.assertTrue(all(p.stat().st_size <= 97 for p in parts))
            got, exact = read_pack(parts)
            self.assertEqual(got, files)
            self.assertTrue(exact)   # nothing after the end mark



class FullHD(unittest.TestCase):
    """Settings › Full HD (docked): off by default, Tears of the Kingdom only, with the 1600x900 scene (1.4.3 renders
    960x540 on the phone otherwise), and no switch in Breath of the Wild's Settings pane (build_ipa.py)."""
    def test_switch_off_by_default_and_docked_at_1600x900(self):
        import plistlib, re
        ios = TOOLS.parent
        specs = plistlib.loads((ios/'Settings.bundle/Root.plist').read_bytes())['PreferenceSpecifiers']
        switch = [s for s in specs if s.get('Key') == 'TOTK_DOCKED']
        self.assertEqual(len(switch), 1)
        self.assertIs(switch[0]['DefaultValue'], False)
        main = (ios/'Sources/main.m').read_text()
        # The switch is the pane's preset layer (main.m's apply_settings): it hands its own drawable and scene over
        # through settings_map.c's table, which is where the docked values live.
        self.assertIn('totk_preset_env_build([d boolForKey:@"TOTK_DOCKED"], &prenv)', main)
        for line in ('setenv("TOTK_IOS_DRAWABLE_H", prenv.drawable, 0)', 'setenv("TOTK_RENDER_RES", prenv.scene, 0)'):
            self.assertIn(line, main)
        preset = re.search(r'int totk_preset_env_build\(int docked.*?\n}', (ios/'Sources/settings_map.c').read_text(), re.S)
        self.assertIsNotNone(preset)
        table = preset.group(0) if preset else ''
        for value in ('"docked"', '"1080"', '"1600x900"'):
            self.assertIn(value, table)
        # Breath of the Wild keeps its handheld operation mode: the exception lives inside one helper, so neither branch
        # repeats the #ifndef. The only other site is visionOS's own platform default.
        self.assertIn('#ifndef GAME_BOTW\n    setenv("TOTK_OPERATION_MODE", mode, 1);\n#else\n    (void)mode;', main)
        vision = 'setenv("TOTK_OPERATION_MODE","docked",1);'
        self.assertIn(vision, main)
        self.assertEqual(main.replace(vision, '').count('setenv("TOTK_OPERATION_MODE",'), 2,
                         'the two operation-mode sites are the helper\'s two branches')
        self.assertIn("'      - path: Gen/Settings.bundle'", (TOOLS/'build_ipa.py').read_text())

    def test_botw_pane_drops_totk_only_rows(self):
        import plistlib
        root = plistlib.loads((TOOLS.parent/'Settings.bundle/Root.plist').read_bytes())
        # The TOTKApp mark on each row is the only list of what Breath of the Wild must not show; if the marks were
        # dropped, the filtered pane would keep every row and the assertions below would pass vacuously.
        marked = {s['Key'] for s in root['PreferenceSpecifiers'] if s.get('TOTKApp') == 'totk'}
        self.assertTrue(marked, 'no row is marked TOTKApp=totk')
        build_ipa.settings_without_totk(root)
        specs = root['PreferenceSpecifiers']
        keys = {s['Key'] for s in specs if 'Key' in s}
        for key in marked:
            self.assertNotIn(key, keys)
        for key in ('TOTK_LANG', 'TOTK_PHONE_FPS', 'TOTK_FPS_OVERLAY', 'TOTK_SHADER_OVERLAY', 'TOTK_DEBUG_LOG'):
            self.assertIn(key, keys)
        # A group whose rows were all removed must not stay behind as an empty header.
        for i, spec in enumerate(specs):
            if spec.get('Type') == 'PSGroupSpecifier':
                self.assertLess(i + 1, len(specs), spec.get('Title'))
                self.assertNotEqual(specs[i+1].get('Type'), 'PSGroupSpecifier', spec.get('Title'))

    def test_export_scene_is_a_pane_value(self):
        # build_ipa.py embeds one scene size so the patch exists in the exported code; the pane's row must offer it, or
        # the embedded patch and the panel disagree about what the device may select.
        import plistlib, re
        build = (TOOLS/'build_ipa.py').read_text()
        match = re.search(r"TOTK_RENDER_RES='(\d+x\d+)'", build)
        self.assertIsNotNone(match, 'the export scene size is missing')
        values = plistlib.loads((TOOLS.parent/'Settings.bundle/Root.plist').read_bytes())
        scene = [s for s in values['PreferenceSpecifiers'] if s.get('Key') == 'TOTK_RENDER_RES'][0]
        self.assertIn(match.group(1) if match else '', scene['Values'])


if __name__ == '__main__':
    unittest.main()
