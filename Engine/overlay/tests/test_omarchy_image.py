# SPDX-License-Identifier: MIT
from contextlib import contextmanager
import hashlib
import io
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
import zipfile
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'src'))
from omarchy_image import write_image, flush_device, WRITE_VERIFICATION


class ImageTests(unittest.TestCase):
    def setUp(self):
        self.data = b'x' * 8192
        self.info = SimpleNamespace(name='disk0s6', uuid='ABC', size=16384)
        self.target = io.BytesIO()
        self.flushed = []

    @contextmanager
    def opener(self, name):
        self.assertEqual(name, self.info.name)
        yield self.target

    def package(self, content=None, declared=None):
        content = self.data if content is None else content
        return SimpleNamespace(
            getinfo=lambda name: SimpleNamespace(file_size=len(content) if declared is None else declared),
            open=lambda member: io.BytesIO(content),
        )

    def run_write(self, package=None, flush=None):
        return write_image(package or self.package(), 'root.img', self.info,
                           opener=self.opener,
                           flush=flush or (lambda target: self.flushed.append(True)))

    def test_exact_write_hash_and_flush_receipt(self):
        receipt = self.run_write()
        self.assertEqual(self.target.getvalue(), self.data)
        self.assertEqual(receipt['content_sha256'], hashlib.sha256(self.data).hexdigest())
        self.assertEqual(receipt['verification'], WRITE_VERIFICATION)
        self.assertEqual(receipt['installed_bytes'], len(self.data))
        self.assertEqual(self.flushed, [True])

    def test_partial_writes_complete(self):
        class Partial(io.BytesIO):
            def write(self, data):
                return super().write(data[:137])
        self.target = Partial()
        self.run_write()
        self.assertEqual(self.target.getvalue(), self.data)

    def test_invalid_write_progress_never_flushes_or_returns_receipt(self):
        for result in [0, -1, None, 999999]:
            with self.subTest(result=result):
                self.target = SimpleNamespace(write=lambda data: result)
                with self.assertRaises(OSError):
                    self.run_write()
        self.assertEqual(self.flushed, [])

    def test_wrong_size_or_target_is_rejected_before_open(self):
        for name, size, declared in [('disk0', 16384, 8192), ('disk0s6', 4096, 8192),
                                      ('disk0s6', 16384, 0), ('disk0s6', 16384, 8191)]:
            self.info.name, self.info.size = name, size
            with self.subTest(name=name, size=size, declared=declared):
                with self.assertRaises(ValueError):
                    self.run_write(self.package(declared=declared))
        self.assertEqual(self.target.getvalue(), b'')

    def test_truncated_and_excess_stream_fail_without_flush(self):
        for content in [b'x' * 4096, b'x' * 9000]:
            with self.subTest(size=len(content)), self.assertRaises(ValueError):
                self.run_write(self.package(content, declared=8192))
        self.assertEqual(self.flushed, [])

    def test_bad_zip_crc_fails_without_flush(self):
        blob = io.BytesIO()
        with zipfile.ZipFile(blob, 'w', compression=zipfile.ZIP_STORED) as archive:
            archive.writestr('root.img', self.data)
        bad = bytearray(blob.getvalue())
        bad[bad.index(self.data)] ^= 1
        with zipfile.ZipFile(io.BytesIO(bad)) as archive:
            with self.assertRaises(zipfile.BadZipFile):
                self.run_write(archive)
        self.assertEqual(self.flushed, [])

    def test_write_exception_and_flush_failure_propagate(self):
        class Broken(io.BytesIO):
            def write(self, data):
                raise OSError('write failure')
        self.target = Broken()
        with self.assertRaisesRegex(OSError, 'write failure'):
            self.run_write()
        self.assertEqual(self.flushed, [])
        self.target = io.BytesIO()
        def fail(target):
            raise OSError('flush failure')
        with self.assertRaisesRegex(OSError, 'flush failure'):
            self.run_write(flush=fail)

    def test_darwin_device_flush_uses_media_sync_not_barrier(self):
        target = SimpleNamespace(flush=lambda: None, fileno=lambda: 55)
        with patch('omarchy_image.sys.platform', 'darwin'), \
             patch('omarchy_image.os.fstat', return_value=SimpleNamespace(st_mode=0o020600)), \
             patch('omarchy_image.fcntl.ioctl') as ioctl:
            flush_device(target)
        ioctl.assert_called_once_with(55, 0x80186416, bytes(24))



class TimingTests(unittest.TestCase):
    def setUp(self):
        import omarchy_image
        import tempfile
        self.image = omarchy_image
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.log = self.root / 'performance.jsonl'
        self.esp = self.root / 'esp'
        self.esp.mkdir()
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(self.image._mirrors.clear)
        env = patch.dict('os.environ', {'OMARCHY_PERFORMANCE_LOG': str(self.log)})
        env.start()
        self.addCleanup(env.stop)

    def records(self, path):
        import json
        return [json.loads(line) for line in path.read_text().splitlines()]

    def test_phases_carry_utc_start_and_end(self):
        with self.image.timing('prepare_target'):
            pass
        (record,) = self.records(self.log)
        self.assertEqual((record['phase'], record['outcome']), ('prepare_target', 'completed'))
        self.assertRegex(record['started_at'], r'^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ$')
        self.assertLessEqual(record['started_at'], record['ended_at'])

    def test_the_esp_copy_has_the_log_so_far_and_every_later_record(self):
        with self.image.timing('prepare_target'):
            pass
        self.image.mirror_to(str(self.esp))
        self.image.mirror_to(str(self.esp))
        self.image.mark('recovery_handoff_begin')
        copy = self.esp / self.image.TIMING_NAME
        self.assertEqual([r['phase'] for r in self.records(copy)],
                         ['prepare_target', 'recovery_handoff_begin'])
        self.assertEqual(self.records(copy), self.records(self.log))
        self.assertEqual(copy.stat().st_mode & 0o777, 0o644)
        self.assertEqual(self.records(copy)[-1]['outcome'], 'mark')


if __name__ == '__main__':
    unittest.main()
