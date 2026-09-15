"""官网公开输出校验的本地回归，不访问网络。"""
from pathlib import Path
import tempfile
import unittest

from check_website import validate_site


class WebsiteCheckTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def test_rejects_placeholders_private_paths_and_source_maps(self):
        index = self.root/'index.html'
        for text in ['__LIVES_VERSION__', '__LIVES_DOWNLOAD_URL__', '/Users/test/private', '//# sourceMappingURL=a.js.map', 'PRIVATE KEY-----']:
            index.write_text(text)
            with self.assertRaises(ValueError): validate_site(self.root)
        index.write_text('官网')
        (self.root/'private.swift').write_text('private source')
        with self.assertRaises(ValueError): validate_site(self.root)

    def test_accepts_current_static_formats(self):
        (self.root/'index.html').write_text('v0.1.15')
        (self.root/'site.webmanifest').write_text('{}')
        self.assertEqual(len(validate_site(self.root)), 2)

    def test_hidden_files_and_directory_are_rejected(self):
        (self.root/'index.html').write_text('官网')
        (self.root/'.DS_Store').write_text('')
        with self.assertRaises(ValueError): validate_site(self.root)
        (self.root/'.DS_Store').unlink()
        (self.root/'.github').mkdir()
        (self.root/'.github/config.yml').write_text('x')
        with self.assertRaises(ValueError): validate_site(self.root)

    def test_symlink_is_not_a_public_file(self):
        (self.root/'index.html').symlink_to('/etc/hosts')
        with self.assertRaises(ValueError): validate_site(self.root)

    def test_missing_index_is_rejected(self):
        (self.root/'styles.css').write_text('body{}')
        with self.assertRaises(ValueError): validate_site(self.root)


if __name__ == '__main__':
    unittest.main()
