"""Exercise copying and the thaw guard without freezing the test host."""
import hashlib
import os
from pathlib import Path
import select
import signal
import sys
import tempfile
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
from minios_ram_save import (CHUNK_SIZE, FIFREEZE, FITHAW, ContainerTransaction, FrozenFilesystem,
                             RamSaveError, SaveCancelled, copy_container_file,
                             recover_container_transaction, verify_container_file, write_record)


class RamSaveTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.events = self.root / 'events'
        self.fd = os.open(str(self.root), os.O_RDONLY | os.O_DIRECTORY)

    def tearDown(self):
        os.close(self.fd)
        self.temp.cleanup()

    def ioctl(self, descriptor, command, argument):
        assert descriptor == self.fd
        with self.events.open('ab', buffering=0) as output:
            output.write(b'freeze\n' if command == FIFREEZE else b'thaw\n')

    def wait_for_thaw(self):
        for _ in range(100):
            if self.events.exists() and self.events.read_bytes().endswith(b'thaw\n'):
                return
            time.sleep(.02)
        self.fail('thaw guard did not release the filesystem')

    def test_normal_copy_releases_freeze(self):
        with FrozenFilesystem(self.fd, ioctl=self.ioctl):
            self.assertEqual(self.events.read_bytes(), b'freeze\n')
        self.assertEqual(self.events.read_bytes(), b'freeze\nthaw\n')

    def test_copy_exception_releases_freeze(self):
        with self.assertRaisesRegex(ValueError, 'copy failed'):
            with FrozenFilesystem(self.fd, ioctl=self.ioctl):
                raise ValueError('copy failed')
        self.wait_for_thaw()

    def test_freeze_failure_does_not_thaw_an_unowned_freeze(self):
        def fail_freeze(descriptor, command, argument):
            if command == FITHAW:
                self.events.write_text('unexpected thaw')
            raise OSError('freeze failed')
        with self.assertRaises(RamSaveError):
            with FrozenFilesystem(self.fd, ioctl=fail_freeze):
                self.fail('copy began despite failed freeze')
        self.assertFalse(self.events.exists())

    def test_cancellation_thaws_even_while_writer_is_busy(self):
        cancel = self.root / 'cancel'
        with self.assertRaises(SaveCancelled):
            with FrozenFilesystem(self.fd, str(cancel), ioctl=self.ioctl):
                cancel.touch()
                self.wait_for_thaw()

    def test_killed_writer_is_thawed_by_independent_guard(self):
        ready_read, ready_write = os.pipe()
        writer = os.fork()
        if writer == 0:
            os.setsid()
            os.close(ready_read)
            with FrozenFilesystem(self.fd, ioctl=self.ioctl):
                os.write(ready_write, b'F')
                time.sleep(60)
            os._exit(0)
        os.close(ready_write)
        try:
            ready, _, _ = select.select([ready_read], [], [], 5)
            self.assertTrue(ready, 'writer did not acquire freeze')
            self.assertEqual(os.read(ready_read, 1), b'F')
        finally:
            os.killpg(writer, signal.SIGKILL)
            os.waitpid(writer, 0)
            os.close(ready_read)
        self.wait_for_thaw()

    def test_sparse_container_and_digest(self):
        source, target = self.root / 'source', self.root / 'target'
        data = b'header' + bytes(CHUNK_SIZE * 2) + b'payload'
        source.write_bytes(data)
        progress = []
        result = copy_container_file(str(source), str(target),
                                     lambda done, total: progress.append((done, total)))
        self.assertEqual(target.read_bytes(), data)
        self.assertEqual(result['sha256'], hashlib.sha256(data).hexdigest())
        self.assertEqual(progress[-1], (len(data), len(data)))
        verify_container_file(str(target), result)
        target.write_bytes(b'X' * len(data))
        with self.assertRaises(RamSaveError):
            verify_container_file(str(target), result)

    def test_existing_target_and_links_are_rejected(self):
        source, target = self.root / 'source', self.root / 'target'
        source.write_bytes(b'new')
        target.write_bytes(b'old')
        with self.assertRaises(OSError):
            copy_container_file(str(source), str(target))
        self.assertEqual(target.read_bytes(), b'old')
        link = self.root / 'link'
        link.symlink_to(source)
        with self.assertRaises(OSError):
            copy_container_file(str(link), str(self.root / 'other'))

    def test_cancel_and_source_mutation_never_report_success(self):
        source = self.root / 'source'
        source.write_bytes(b'A' * (CHUNK_SIZE * 2))
        with self.assertRaises(SaveCancelled):
            copy_container_file(str(source), str(self.root / 'cancelled'),
                                cancelled=lambda: True)
        changed = [False]
        def mutate(done, total):
            if not changed[0]:
                source.write_bytes(b'changed')
                changed[0] = True
        with self.assertRaises(RamSaveError):
            copy_container_file(str(source), str(self.root / 'changed'), progress=mutate)

    def transaction_fixture(self):
        (self.root / '1').mkdir()
        (self.root / '1' / 'changes.img').write_bytes(b'old container')
        (self.root / '2').mkdir()
        (self.root / '2' / 'changes.img').write_bytes(b'other session')
        (self.root / 'session.conf').write_text('old metadata')
        transaction = ContainerTransaction(str(self.root), '1')
        target = Path(transaction.prepare())
        (target / 'changes.img').write_bytes(b'new container')
        return transaction

    def test_transaction_publishes_data_before_removing_backup(self):
        transaction = self.transaction_fixture()
        def metadata():
            self.assertEqual((self.root / '1' / 'changes.img').read_bytes(), b'new container')
            self.assertEqual((Path(transaction.old) / 'changes.img').read_bytes(), b'old container')
            (self.root / 'session.conf').write_text('new metadata')
            return True
        transaction.publish(metadata)
        self.assertTrue(Path(transaction.old).exists())
        transaction.cleanup()
        self.assertFalse(Path(transaction.path).exists())
        self.assertEqual((self.root / '2' / 'changes.img').read_bytes(), b'other session')

    def test_metadata_failure_restores_data_and_metadata(self):
        transaction = self.transaction_fixture()
        def metadata():
            (self.root / 'session.conf').write_text('partial metadata')
            (self.root / 'session.json').write_text('{}')
            return False
        with self.assertRaises(RamSaveError):
            transaction.publish(metadata)
        self.assertEqual((self.root / '1' / 'changes.img').read_bytes(), b'old container')
        self.assertEqual((self.root / 'session.conf').read_text(), 'old metadata')
        self.assertFalse((self.root / 'session.json').exists())

    def test_recovery_between_directory_renames(self):
        transaction = self.transaction_fixture()
        write_record(os.path.join(transaction.path, 'ready'), '')
        os.rename(transaction.target, transaction.old)
        self.assertFalse(Path(transaction.target).exists())
        recover_container_transaction(str(self.root), transaction.path)
        self.assertEqual((self.root / '1' / 'changes.img').read_bytes(), b'old container')

    def test_recovery_after_new_directory_publication(self):
        transaction = self.transaction_fixture()
        write_record(os.path.join(transaction.new, '.ram-save-owner'), transaction.token + '\n')
        write_record(os.path.join(transaction.path, 'ready'), '')
        os.rename(transaction.target, transaction.old)
        os.rename(transaction.new, transaction.target)
        (self.root / 'session.conf').write_text('partial metadata')
        recover_container_transaction(str(self.root), transaction.path)
        self.assertEqual((self.root / '1' / 'changes.img').read_bytes(), b'old container')
        self.assertEqual((self.root / 'session.conf').read_text(), 'old metadata')

    def test_recovery_does_not_replace_an_unrecognized_target(self):
        transaction = self.transaction_fixture()
        write_record(os.path.join(transaction.path, 'ready'), '')
        os.rename(transaction.target, transaction.old)
        Path(transaction.target).mkdir()
        with self.assertRaises(RamSaveError):
            recover_container_transaction(str(self.root), transaction.path)
        self.assertTrue(Path(transaction.old).is_dir())


if __name__ == '__main__':
    unittest.main()
