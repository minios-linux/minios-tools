"""Run as root in a private mount namespace; freeze only a disposable ext4."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'lib'))
from minios_ram_save import FrozenFilesystem, copy_container_file, verify_container_file


def run(*arguments):
    subprocess.run(list(map(str, arguments)), check=True)


if os.geteuid() != 0:
    sys.exit(77)
if os.stat('/proc/self/ns/mnt').st_ino == os.stat('/proc/1/ns/mnt').st_ino:
    raise RuntimeError('Use unshare --mount for the disposable filesystem test')
run('mount', '--make-rprivate', '/')
with tempfile.TemporaryDirectory(prefix='minios-ram-save-') as directory:
    root = Path(directory)
    source = root / 'source.img'
    target = root / 'target.img'
    mounted = root / 'source'
    copied = root / 'copy'
    mounted.mkdir()
    copied.mkdir()
    with source.open('wb') as image:
        image.truncate(64 << 20)
    run('mkfs.ext4', '-q', '-F', source)
    run('mount', '-o', 'loop', source, mounted)
    try:
        payload = mounted / 'payload'
        payload.write_bytes(b'before freeze')
        descriptor = os.open(str(mounted), os.O_RDONLY | os.O_DIRECTORY)
        try:
            with FrozenFilesystem(descriptor):
                result = copy_container_file(str(source), str(target))
        finally:
            os.close(descriptor)
        # This write must work after thaw and must not change the copied image.
        payload.write_bytes(b'after thaw')
        verify_container_file(str(target), result)
        run('mount', '-o', 'loop,ro,noload', target, copied)
        try:
            assert (copied / 'payload').read_bytes() == b'before freeze'
        finally:
            run('umount', copied)
        assert payload.read_bytes() == b'after thaw'
    finally:
        run('umount', mounted)
print('PASS: ext4 freeze, direct container copy, thaw and snapshot contents')
