"""验证 Mac 产品来源检查；所有 Git 操作只在临时目录，不访问远端。"""
from pathlib import Path
import subprocess
import tempfile
import unittest

from core_dependency import SOURCE_URL, core_snapshot


class CoreDependencyTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.repo = Path(self.temp.name).resolve()
        self.core = self.repo/'packages/LivesCore'
        files = {
            'packages/LivesCore/Package.swift': '// fixture',
            'packages/LivesCore/Sources/LivesCore/Resources/WatermarkAppIcon.png': 'fixture',
            'native/LivePhotoService/Package.swift': '.package(path: "../../packages/LivesCore")',
            '.gitignore': '.build/\n',
        }
        for name, contents in files.items():
            path = self.repo/name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(contents)
        self.git('init')
        self.git('config', 'user.email', 'test@example.invalid')
        self.git('config', 'user.name', 'Migration test')
        self.git('remote', 'add', 'origin', SOURCE_URL)
        self.git('add', '.')
        self.git('commit', '-m', 'fixture')

    def git(self, *args):
        return subprocess.check_output(['git', '-c', 'core.fsmonitor=false', *args], cwd=self.repo, text=True, stderr=subprocess.DEVNULL).strip()

    def tearDown(self):
        self.temp.cleanup()

    def test_clean_snapshot_binds_product_revision_and_core_tree(self):
        result = core_snapshot(self.repo, release=True)
        self.assertEqual(result['path'], 'packages/LivesCore')
        self.assertEqual(result['revision'], self.git('rev-parse', 'HEAD'))
        self.assertEqual(result['tree'], self.git('rev-parse', 'HEAD:packages/LivesCore'))

    def test_local_snapshot_ignores_ignored_build_cache(self):
        cache = self.repo/'.build/cache'
        cache.parent.mkdir()
        cache.write_text('generated')
        core_snapshot(self.repo, release=True)

    def test_uncommitted_changes_block_release(self):
        path = self.repo/'packages/LivesCore/Package.swift'
        original = path.read_text()
        path.write_text('modified')
        core_snapshot(self.repo)
        with self.assertRaises(ValueError): core_snapshot(self.repo, release=True)
        path.write_text(original)

    def test_unexpected_origin_is_rejected_at_release(self):
        self.git('remote', 'set-url', 'origin', 'https://github.com/example/not-this-repo.git')
        with self.assertRaises(ValueError): core_snapshot(self.repo, release=True)
        self.git('remote', 'set-url', 'origin', SOURCE_URL)
        core_snapshot(self.repo, release=True)

    def test_external_core_path_is_rejected(self):
        path = self.repo/'native/LivePhotoService/Package.swift'
        path.write_text('.package(path: "/tmp/other-core")')
        with self.assertRaises(ValueError): core_snapshot(self.repo)
        path.write_text('.package(path: "../../../../packages/LivesCore")')
        with self.assertRaises(ValueError): core_snapshot(self.repo)

    def test_symlink_core_and_nested_repository_are_rejected(self):
        original = self.core.with_name('original-core')
        self.core.rename(original)
        self.core.symlink_to(original, target_is_directory=True)
        with self.assertRaises(ValueError): core_snapshot(self.repo)
        self.core.unlink()
        original.rename(self.core)
        subprocess.run(['git', 'init', str(self.core)], check=True, capture_output=True)
        with self.assertRaises(ValueError): core_snapshot(self.repo)


if __name__ == '__main__':
    unittest.main()
