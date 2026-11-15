import importlib.util
import json
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location('sender', Path(__file__).resolve().parents[1] / 'tools/notchlite-remote.py')
sender = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sender)

class RemoteSenderTests(unittest.TestCase):
    def test_payload_minimization(self):
        event = sender.event_from_hook('claude', 'working', {'session_id': 'abc', 'cwd': '/srv/app',
            'prompt': 'PRIVATE', 'tool_input': {'secret': 'PRIVATE'}, 'transcript_path': '/private'})
        self.assertEqual(set(event), {'agent', 'kind', 'session', 'cwd', 'tool', 'ts'})
        self.assertNotIn('PRIVATE', json.dumps(event))

    def test_invalid_session(self):
        for value in [{}, [], {'session_id': 1}, {'session_id': 'a' * 201}]:
            with self.assertRaises(ValueError):
                sender.event_from_hook('claude', 'working', value)

    def test_install_preserves_hooks_and_is_idempotent(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'settings.json'
            original = {'model': 'test', 'hooks': {'Stop': [{'matcher': '*', 'hooks': [
                {'type': 'command', 'command': 'my-original-hook'}]}]}}
            path.write_text(json.dumps(original))
            args = SimpleNamespace(settings=str(path), agent='claude', target='notchlite-mac')
            sender.install(args)
            once = json.loads(path.read_text())
            sender.install(args)
            self.assertEqual(once, json.loads(path.read_text()))
            self.assertEqual(once['model'], 'test')
            self.assertEqual(once['hooks']['Stop'][0], original['hooks']['Stop'][0])
            self.assertEqual(len(list(Path(directory).glob('*.bak'))), 2)

if __name__ == '__main__':
    unittest.main()
