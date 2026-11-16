import importlib.util
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('write_appcast', ROOT / 'scripts/write_appcast.py')
write_appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(write_appcast)
SPARKLE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'


class WriteAppcastTests(unittest.TestCase):
    def publish(self, version, feed_version=None, notes=None, **env):
        with tempfile.TemporaryDirectory() as directory:
            feed = Path(directory) / 'appcast.xml'
            if feed_version:
                write_appcast.write(feed, feed_version, f'v{feed_version}', '14.2', 'old', '1', env={})
            before = feed.read_text() if feed.exists() else None
            notes_path = None
            if notes is not None:
                notes_path = Path(directory) / 'notes.md'
                notes_path.write_text(notes)
            published = write_appcast.write(feed, version, f'v{version}', '14.2', 'sig==', '42', notes_path, env=env)
            text = feed.read_text()
            return published, before, text, ET.fromstring(text).find('channel/item')

    def test_minor_release_replaces_the_item(self):
        published, _, _, item = self.publish('1.91.0', '1.90.0')
        self.assertTrue(published)
        self.assertEqual(item.find(f'{SPARKLE}version').text, '1.91.0')
        self.assertEqual(item.find('enclosure').get('url'),
                         'https://github.com/yazinsai/OpenOats/releases/download/v1.91.0/OpenOats.dmg')
        self.assertEqual(item.find('enclosure').get(f'{SPARKLE}edSignature'), 'sig==')

    def test_new_major_is_held_back_without_approval(self):
        published, before, text, _ = self.publish('2.0.0', '1.90.0')
        self.assertFalse(published)
        self.assertEqual(text, before)

    def test_new_major_publishes_once_approved(self):
        published, _, _, item = self.publish('2.0.0', '1.90.0', SPARKLE_MAJOR_UPGRADE_APPROVED='2')
        self.assertTrue(published)
        self.assertEqual(item.find(f'{SPARKLE}version').text, '2.0.0')

    def test_approval_for_another_major_does_not_count(self):
        published, _, _, _ = self.publish('3.0.0', '2.4.0', SPARKLE_MAJOR_UPGRADE_APPROVED='2')
        self.assertFalse(published)

    def test_never_installs_across_a_major_silently(self):
        _, _, _, item = self.publish('2.0.1', '2.0.0')
        self.assertEqual(item.find(f'{SPARKLE}minimumAutoupdateVersion').text, '2.0.0')

    def test_phased_rollout_is_opt_in(self):
        _, _, _, item = self.publish('2.0.1', '2.0.0')
        self.assertIsNone(item.find(f'{SPARKLE}phasedRolloutInterval'))
        _, _, _, item = self.publish('2.0.1', '2.0.0', SPARKLE_PHASED_ROLLOUT_INTERVAL='86400')
        self.assertEqual(item.find(f'{SPARKLE}phasedRolloutInterval').text, '86400')
        self.assertIsNotNone(item.find('pubDate'))

    def test_release_notes_are_embedded_as_markdown(self):
        notes = '## Removed\n- Live transcript & suggestions <b>\n- odd ]]> text\n'
        _, _, _, item = self.publish('2.0.1', '2.0.0', notes=notes)
        description = item.find('description')
        self.assertEqual(description.get(f'{SPARKLE}format'), 'markdown')
        self.assertEqual(description.text, notes)

    def test_empty_feed_publishes(self):
        published, _, _, _ = self.publish('2.0.0')
        self.assertTrue(published)


if __name__ == '__main__':
    unittest.main()
