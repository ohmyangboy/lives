"""发布边界的本地回归，不调用 GitHub 或 Apple。"""
import io
import json
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import release



class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def archive(self, names):
        p = self.root / 'archive.tar.gz'
        with tarfile.open(p, 'w:gz') as a:
            for name in names:
                m = tarfile.TarInfo(name)
                m.size = 1
                a.addfile(m, io.BytesIO(b'x'))
        return p

    def test_archive_rejects_traversal_private_sources_and_missing_dependencies(self):
        for names in [['third-party/../../secret'], ['Lives-source/src/App.tsx'], ['third-party/native/LivesCore/Domain.swift'], ['third-party/README.md']]:
            with self.assertRaises(ValueError): release.validate_archive(self.archive(names))

    def test_changed_frozen_payload_is_rejected_before_network(self):
        stage = self.root / 'stage'
        (stage / 'payload').mkdir(parents=True)
        (stage / 'payload/notes').write_text('reviewed')
        data = {'kind': 'release', 'version': '0.1.15', 'tag': 'v0.1.15', 'files': release.tree(stage / 'payload')}
        (stage / 'manifest.json').write_text(json.dumps(data))
        (stage / 'payload/notes').write_text('changed')
        with patch.object(release, 'STAGE', stage), patch.object(release, 'run') as run:
            with self.assertRaises(ValueError): release.load()
            run.assert_not_called()

    def test_server_contract_uses_current_version_and_verifies_bytes(self):
        stage = self.root / 'stage'
        assets = stage / 'payload/assets'
        assets.mkdir(parents=True)
        name = release.asset_names('0.1.15')[0]
        (assets / name).write_bytes(b'dmg')
        digest = release.sha(assets / name)
        data = {'version': '0.1.15', 'files': {'assets/' + name: digest}}
        meta = {'currentVersion': 'v0.1.15', 'size': 3, 'sha256': digest}
        with patch.object(release, 'STAGE', stage), patch.object(release, 'fetch', side_effect=[json.dumps(meta).encode(), b'dmg']):
            release.verify_download(data)
        with patch.object(release, 'STAGE', stage), patch.object(release, 'fetch', side_effect=[json.dumps(meta).encode(), b'bad']):
            with self.assertRaises(ValueError): release.verify_download(data)

    def test_existing_release_asset_cannot_be_overwritten(self):
        data = {'version': '0.1.15'}
        with patch.object(release, 'run') as run:
            with self.assertRaises(ValueError): release.verify_assets(data, {'assets': [{'name': 'private-source.zip'}]})
            run.assert_not_called()

    def test_receipt_binds_artifacts_to_app_and_core(self):
        snapshot = {'version': '0.1.15', 'appCommit': 'a' * 40, 'core': {'revision': 'b' * 40}}
        for name in release.asset_names(snapshot['version']):
            (self.root / name).write_text('artifact')
        receipt = {**snapshot, 'files': {name: release.sha(self.root / name) for name in release.asset_names(snapshot['version'])}}
        (self.root / 'build-receipt.json').write_text(json.dumps(receipt))
        release.verify_receipt(snapshot, self.root)
        with self.assertRaises(ValueError): release.verify_receipt({**snapshot, 'appCommit': 'c' * 40}, self.root)
        (self.root / release.asset_names(snapshot['version'])[0]).write_text('changed')
        with self.assertRaises(ValueError): release.verify_receipt(snapshot, self.root)



if __name__ == '__main__':
    unittest.main()
