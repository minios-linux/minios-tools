"""Container copying for RAM sessions. Storage selection belongs to the caller."""

import errno
import fcntl
import hashlib
import os
import re
import select
import shutil
import signal
import stat
import tempfile


FIFREEZE = 0xC0045877
FITHAW = 0xC0045878
CHUNK_SIZE = 1024 * 1024


class RamSaveError(OSError):
    pass


class SaveCancelled(RamSaveError):
    pass


class FrozenFilesystem:
    """A separate process owns freeze/thaw, including after writer death."""

    def __init__(self, descriptor, cancel_path=None, ioctl=fcntl.ioctl, cancelled=None):
        self.descriptor = descriptor
        self.cancel_path = cancel_path
        self.ioctl = ioctl
        self.cancelled = cancelled or (lambda: bool(self.cancel_path and os.path.exists(self.cancel_path)))
        self.pid = None
        self.command = None
        self.events = None

    def _guard(self, command, events):
        frozen = False
        result = b'T'
        try:
            # A cancelled writer's process group must not kill its thaw guard.
            os.setsid()
            signal.signal(signal.SIGINT, signal.SIG_IGN)
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            self.ioctl(self.descriptor, FIFREEZE, 0)
            frozen = True
            os.write(events, b'F')
            while True:
                if self.cancelled():
                    result = b'C'
                    break
                ready, _, _ = select.select([command], [], [], 0.2)
                if ready:
                    # EOF also covers a writer killed during freeze or copy.
                    os.read(command, 1)
                    break
        except BaseException:
            result = b'E'
        finally:
            if frozen:
                try:
                    self.ioctl(self.descriptor, FITHAW, 0)
                except BaseException:
                    result = b'E'
            try:
                os.write(events, result)
            except OSError:
                pass
            os._exit(0 if result in (b'T', b'C') else 1)

    def __enter__(self):
        if self.cancelled():
            raise SaveCancelled('Session saving was cancelled')
        command_read, command_write = os.pipe()
        event_read, event_write = os.pipe()
        try:
            self.pid = os.fork()
        except BaseException:
            for descriptor in (command_read, command_write, event_read, event_write):
                os.close(descriptor)
            raise
        if self.pid == 0:
            os.close(command_write)
            os.close(event_read)
            self._guard(command_read, event_write)
        os.close(command_read)
        os.close(event_write)
        self.command = command_write
        self.events = event_read
        try:
            if os.read(self.events, 1) != b'F':
                raise RamSaveError('Cannot freeze the session filesystem')
        except BaseException:
            self.close()
            raise
        return self

    def close(self):
        if self.command is not None:
            os.close(self.command)
            self.command = None
        result = b''
        try:
            if self.events is not None:
                result = os.read(self.events, 1)
        finally:
            if self.events is not None:
                os.close(self.events)
                self.events = None
            status = 0
            if self.pid is not None:
                _, status = os.waitpid(self.pid, 0)
                self.pid = None
        if result == b'C':
            raise SaveCancelled('Session saving was cancelled')
        if result != b'T' or status != 0:
            raise RamSaveError('Session freeze/thaw did not complete successfully')

    def __exit__(self, exception_type, exception, traceback):
        self.close()
        return False


def copy_container_file(source, destination, progress=None, cancelled=None):
    """Copy a stable regular file; return its digest and logical byte count."""
    source_fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    target_fd = None
    copied = 0
    digest = hashlib.sha256()
    try:
        before = os.fstat(source_fd)
        if not stat.S_ISREG(before.st_mode):
            raise RamSaveError('Container source is not a regular file')
        target_fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL |
                            os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
        while True:
            if cancelled and cancelled():
                raise SaveCancelled('Session saving was cancelled')
            data = os.read(source_fd, CHUNK_SIZE)
            if not data:
                break
            digest.update(data)
            # Preserve zero ranges on filesystems supporting sparse files.
            if not data.strip(b'\0'):
                os.lseek(target_fd, len(data), os.SEEK_CUR)
            else:
                remaining = memoryview(data)
                while remaining:
                    written = os.write(target_fd, remaining)
                    if written <= 0:
                        raise RamSaveError(errno.EIO, 'Short container write')
                    remaining = remaining[written:]
            copied += len(data)
            if progress:
                progress(copied, before.st_size)
        after = os.fstat(source_fd)
        if (copied != before.st_size or
                (before.st_size, before.st_mtime_ns, before.st_ctime_ns) !=
                (after.st_size, after.st_mtime_ns, after.st_ctime_ns)):
            raise RamSaveError('Container changed during copying')
        os.ftruncate(target_fd, copied)
        # Durability and verification can be completed after thawing.
        return {'sha256': digest.hexdigest(), 'size': copied}
    finally:
        if target_fd is not None:
            os.close(target_fd)
        os.close(source_fd)


def verify_container_file(path, expected):
    """Verify and flush a private candidate before publishing it."""
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
    digest = hashlib.sha256()
    try:
        current = os.fstat(descriptor)
        if not stat.S_ISREG(current.st_mode) or current.st_size != expected['size']:
            raise RamSaveError('Copied container has an unexpected size or type')
        while True:
            data = os.read(descriptor, CHUNK_SIZE)
            if not data:
                break
            digest.update(data)
        if digest.hexdigest() != expected['sha256']:
            raise RamSaveError('Copied container digest does not match')
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        try:
            os.fsync(descriptor)
        except OSError as error:
            if error.errno not in (errno.EINVAL, errno.ENOTSUP):
                raise
    finally:
        os.close(descriptor)


def write_record(path, text):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'w', encoding='utf-8') as stream:
        stream.write(text)
        stream.flush()
        os.fsync(stream.fileno())


class ContainerTransaction:
    """Publish one numbered directory while retaining its previous generation.

    The caller holds the store's metadata lock throughout this transaction.
    The small journal is also readable by initramfs after a power loss.
    """

    def __init__(self, store, session):
        if not re.fullmatch(r'[0-9]+', session):
            raise RamSaveError('Invalid target session number')
        self.store = store
        self.session = session
        self.target = os.path.join(store, session)
        self.path = tempfile.mkdtemp(prefix='.ram-save-', dir=store)
        self.new = os.path.join(self.path, 'new')
        self.old = os.path.join(self.path, 'old')
        self.token = os.path.basename(self.path)
        self.prepared = False
        self.publication_uncertain = False
        self.target_identity = None

    def prepare(self):
        if os.path.lexists(self.target):
            current = os.lstat(self.target)
            if not stat.S_ISDIR(current.st_mode):
                raise RamSaveError('Target session is not a real directory')
            self.target_identity = (current.st_dev, current.st_ino)
            had_session = '1'
        else:
            had_session = '0'
        write_record(os.path.join(self.path, 'session'), self.session + '\n')
        write_record(os.path.join(self.path, 'had-session'), had_session + '\n')
        for name in ('session.conf', 'session.json'):
            source = os.path.join(self.store, name)
            if os.path.lexists(source):
                before = os.path.join(self.path, name + '.before')
                result = copy_container_file(source, before)
                verify_container_file(before, result)
            else:
                write_record(os.path.join(self.path, name + '.absent'), '')
        os.mkdir(self.new, 0o700)
        write_record(os.path.join(self.path, 'prepared'), '')
        sync_directory(self.path)
        sync_directory(self.store)
        self.prepared = True
        return self.new

    def publish(self, update_metadata):
        if not self.prepared:
            raise RamSaveError('Session transaction was not prepared')
        if os.path.lexists(self.target):
            current = os.lstat(self.target)
            if not stat.S_ISDIR(current.st_mode) or self.target_identity != (current.st_dev, current.st_ino):
                raise RamSaveError('Target session changed before publication')
        elif self.target_identity is not None:
            raise RamSaveError('Target session disappeared before publication')
        write_record(os.path.join(self.new, '.ram-save-owner'), self.token + '\n')
        sync_directory(self.new)
        write_record(os.path.join(self.path, 'ready'), '')
        sync_directory(self.path)
        try:
            if os.path.exists(self.target):
                os.rename(self.target, self.old)
                sync_directory(self.store)
                sync_directory(self.path)
            os.rename(self.new, self.target)
            sync_directory(self.store)
            sync_directory(self.path)
            if not update_metadata():
                raise RamSaveError('Cannot publish session metadata')
            sync_directory(self.store)
            write_record(os.path.join(self.path, 'commit.new'), '')
            os.rename(os.path.join(self.path, 'commit.new'), os.path.join(self.path, 'committed'))
            sync_directory(self.path)
        except BaseException:
            if os.path.exists(os.path.join(self.path, 'committed')):
                self.publication_uncertain = True
            else:
                recover_container_transaction(self.store, self.path)
            raise

    def cleanup(self):
        if self.publication_uncertain:
            return
        if os.path.exists(self.path):
            if os.path.exists(os.path.join(self.path, 'ready')):
                recover_container_transaction(self.store, self.path)
            else:
                shutil.rmtree(self.path)
                sync_directory(self.store)


def _transaction_value(path, name):
    descriptor = os.open(os.path.join(path, name), os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(descriptor, 'r', encoding='ascii') as stream:
        value = stream.read(128)
        if stream.read(1):
            raise RamSaveError('Invalid session transaction record')
        return value.strip()


def recover_container_transaction(store, path):
    """Finish cleanup of a commit, or restore data and both metadata files."""
    if (os.path.dirname(os.path.abspath(path)) != os.path.abspath(store) or
            not re.fullmatch(r'\.ram-save-[A-Za-z0-9_-]+', os.path.basename(path)) or
            not stat.S_ISDIR(os.lstat(path).st_mode)):
        raise RamSaveError('Invalid session transaction directory')
    if not os.path.isfile(os.path.join(path, 'ready')):
        if os.path.isfile(os.path.join(path, 'prepared')) and not os.path.lexists(os.path.join(path, 'old')):
            session = _transaction_value(path, 'session')
            if not re.fullmatch(r'[0-9]+', session):
                raise RamSaveError('Invalid uncommitted session transaction')
            shutil.rmtree(path)
            sync_directory(store)
            return True
        return False
    if os.path.isfile(os.path.join(path, 'committed')):
        shutil.rmtree(path)
        sync_directory(store)
        return True
    session = _transaction_value(path, 'session')
    had_session = _transaction_value(path, 'had-session')
    if not re.fullmatch(r'[0-9]+', session) or had_session not in ('0', '1'):
        raise RamSaveError('Invalid interrupted session transaction')
    target = os.path.join(store, session)
    old = os.path.join(path, 'old')
    rejected = os.path.join(path, 'rejected')
    if os.path.lexists(old) and not stat.S_ISDIR(os.lstat(old).st_mode):
        raise RamSaveError('Invalid previous session directory')
    if os.path.lexists(target):
        if not stat.S_ISDIR(os.lstat(target).st_mode):
            raise RamSaveError('Invalid current session directory')
        try:
            owner = _transaction_value(target, '.ram-save-owner')
        except FileNotFoundError:
            owner = None
        if owner == os.path.basename(path):
            if os.path.lexists(rejected):
                raise RamSaveError('Interrupted session recovery is ambiguous')
            os.rename(target, rejected)
            sync_directory(store)
            sync_directory(path)
        elif os.path.exists(old) or had_session == '0':
            raise RamSaveError('Target session changed after interrupted saving')
    if os.path.exists(old):
        os.rename(old, target)
        sync_directory(store)
        sync_directory(path)
    elif had_session == '1' and not os.path.isdir(target):
        raise RamSaveError('Previous session directory is missing')
    # Reclaim the uncommitted candidate before restoring metadata on a full store.
    for candidate in (rejected, os.path.join(path, 'new')):
        if os.path.lexists(candidate):
            if not stat.S_ISDIR(os.lstat(candidate).st_mode):
                raise RamSaveError('Invalid candidate directory')
            shutil.rmtree(candidate)
    sync_directory(path)
    for name in ('session.conf', 'session.json'):
        before = os.path.join(path, name + '.before')
        destination = os.path.join(store, name)
        if os.path.isfile(before):
            temporary = os.path.join(path, name + '.restore')
            if os.path.lexists(temporary):
                os.unlink(temporary)
            result = copy_container_file(before, temporary)
            verify_container_file(temporary, result)
            os.replace(temporary, destination)
        elif os.path.isfile(os.path.join(path, name + '.absent')):
            if os.path.lexists(destination):
                os.unlink(destination)
        else:
            raise RamSaveError('Previous session metadata is missing')
        sync_directory(store)
    shutil.rmtree(path)
    sync_directory(store)
    return True
