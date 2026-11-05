import importlib.util
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("desktop", Path.home() / ".config/omarchy/plugins/nov.dock/desktop.py")
desktop = importlib.util.module_from_spec(spec)
spec.loader.exec_module(desktop)


class DesktopTests(unittest.TestCase):
    def test_download_order_partial_files_and_unsafe_names(self):
        with tempfile.TemporaryDirectory() as directory:
            names = ['old.txt', '<img src="https:evil">.txt', 'new $(touch injected).txt', 'hidden.part', '.secret', 'pending.crdownload']
            for n, name in enumerate(names):
                path = Path(directory, name)
                path.write_text('test')
                os.utime(path, (n + 1, n + 1))
            data = desktop.downloads(directory)
            self.assertEqual([f['name'] for f in data['items']], names[:3][::-1])
            self.assertIn('%3Cimg', data['items'][1]['uri'])
            self.assertTrue(all(f['uri'].startswith('file:///') for f in data['items']))

    def test_modes_and_default(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, XDG_STATE_HOME=directory):
            state = Path(directory) / 'omarchy/workspace-layouts'
            state.mkdir(parents=True)
            (state / 'default.lua').write_text('o.workspace_mode({ default = "floating" })')
            (state / '2.lua').write_text('o.workspace_mode({ workspace = 2, mode = "dwindle" })')
            self.assertEqual(desktop.mode(1), 'floating')
            self.assertEqual(desktop.mode(2), 'dwindle')
            self.assertEqual(desktop.mode(-98), 'dwindle')

    def test_invalid_address_never_executes(self):
        with patch.object(desktop, 'run') as run:
            with self.assertRaises(ValueError):
                desktop.control('border', '0x123"; os.execute("bad")')
            run.assert_not_called()

    def test_closed_window_is_not_retargeted(self):
        with patch.object(desktop, 'run', return_value='[]') as run:
            with self.assertRaises(ValueError):
                desktop.control('border', '0x123')
            self.assertEqual(run.call_count, 1)

    def test_global_border_applies_to_all_floating_windows(self):
        import json
        floating = {"address": "0x123", "floating": True, "workspace": {"id": 4}, "tags": []}
        other = {"address": "0x456", "floating": True, "workspace": {"id": 4}, "tags": []}
        tiled = {"address": "0x789", "floating": False, "workspace": {"id": 2}, "tags": []}
        with tempfile.TemporaryDirectory() as directory:
            flag = Path(directory, "nov-dock/borderless")
            with patch.object(desktop, 'BORDERLESS_FILE', flag), \
                 patch.object(desktop, 'run', side_effect=[''] + [json.dumps([floating, other, tiled])] + [''] * 8) as run, \
                 patch.object(desktop, 'mode', side_effect=lambda ws: 'floating' if ws == 4 else 'dwindle'):
                desktop.toggle_borders()
                self.assertTrue(flag.exists())
                self.assertIn('enabled = true', run.call_args_list[0].args[-1])
                touched = " ".join(call.args[-1] for call in run.call_args_list[2:])
                self.assertIn('address:0x123', touched)
                self.assertIn('address:0x456', touched)
                self.assertNotIn('address:0x789', touched)
                self.assertIn('value = "0"', touched)

    def test_turning_borders_back_on_restores_tagged_windows(self):
        import json
        tagged = {"address": "0x123", "floating": True, "workspace": {"id": 4}, "tags": [desktop.TAG]}
        with tempfile.TemporaryDirectory() as directory:
            flag = Path(directory, "borderless")
            flag.touch()
            with patch.object(desktop, 'BORDERLESS_FILE', flag), \
                 patch.object(desktop, 'run', side_effect=['', json.dumps([tagged]), '', '']) as run, \
                 patch.object(desktop, 'mode', return_value='floating'):
                desktop.toggle_borders()
                self.assertFalse(flag.exists())
                self.assertIn('enabled = false', run.call_args_list[0].args[-1])
                self.assertIn('value = "unset"', run.call_args_list[2].args[-1])

if __name__ == '__main__':
    unittest.main()
