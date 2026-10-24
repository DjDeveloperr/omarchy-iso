#!/usr/bin/env python3
"""Run inside the live QEMU guest; formats only newly-created scratch files."""
import json
from pathlib import Path
import statistics
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, '/usr/share/omarchy-iso')
from orchestrator import luks_calibration as calibration


def command(argv, **kwargs):
    start=time.monotonic()
    result=subprocess.run(argv, check=True, capture_output=True, **kwargs)
    return result, time.monotonic()-start


report={'memory_kib': calibration.memory_available(), 'runs': []}
state=calibration.STATE
saved=state.read_bytes()
cache=json.loads(saved)
report['calibration']=cache
assert calibration.cached_options(2000,512), 'boot service produced no usable calibration'
# archinstall parses argv on import; the real dependency shipped by this ISO.
sys.argv=sys.argv[:1]
from archinstall.lib.disk.luks import Luks2
from orchestrator import luks_tuning
luks_tuning.apply()

try:
    with tempfile.TemporaryDirectory(prefix='luks-calibration-', dir='/var/tmp') as tmp:
        tmp=Path(tmp)
        key=tmp/'test-key'
        password=b'only-a-disposable-vm-test'
        key.write_bytes(password)
        key.chmod(0o600)
        for mode in ('cached', 'absent', 'malformed', 'archinstall'):
            if mode == 'absent': state.unlink(missing_ok=True)
            elif mode == 'malformed': state.write_text('{partial')
            else: state.write_bytes(saved)
            image=tmp/f'{mode}.img'
            with image.open('xb') as stream: stream.truncate(64*1024*1024)
            if mode == 'archinstall':
                start=time.monotonic()
                returned=Luks2(image).encrypt(iter_time=2000, key_file=key)
                assert returned == key
                elapsed=time.monotonic()-start
                output=''
            else:
                result,elapsed=command(['omarchy-luks-calibrate','format',str(image)],input=password)
                output=result.stderr.decode()
                assert ('Using this boot' in output) == (mode == 'cached'), output
            result,_=command(['cryptsetup','luksDump','--dump-json-metadata',str(image)])
            metadata=json.loads(result.stdout)
            slot=metadata['keyslots']['0']
            kdf=slot['kdf']
            assert kdf['type']=='argon2id'
            assert slot['key_size']==64
            if mode in ('cached','archinstall'):
                assert (kdf['time'],kdf['memory'],kdf['cpus']) == (cache['iterations'],cache['memory'],cache['parallel'])
            else:
                assert kdf['memory']==cache['memory'] and kdf['cpus']==cache['parallel']
            unlock=[]
            for _ in range(3):
                _,duration=command(['cryptsetup','open','--test-passphrase','--key-file',str(key),str(image)])
                unlock.append(duration)
            report['runs'].append(dict(mode=mode, format_seconds=elapsed, unlock_seconds=unlock,
                                       kdf=kdf, metadata=metadata, stderr=output))
            image.unlink()
        runs={row['mode']:row for row in report['runs']}
        ordinary=statistics.median(runs['absent']['unlock_seconds'])
        cached=statistics.median(runs['cached']['unlock_seconds'])
        report['cached_to_ordinary_unlock_ratio']=cached/ordinary
        report['format_saved_seconds']=runs['absent']['format_seconds']-runs['cached']['format_seconds']
        # CI is noisy. Preserve raw measurements, but fail a material cost
        # regression rather than pretending elapsed times can be identical.
        assert 0.70 <= cached/ordinary <= 1.40, report
        assert report['format_saved_seconds'] > 1, report
        assert len({row['kdf']['salt'] for row in report['runs']})==4
finally:
    state.write_bytes(saved)
    print(json.dumps(report, indent=2))
