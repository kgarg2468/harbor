"""Hermetic script copies: every machine-changing command is replaced by a shim."""
import fcntl
import hashlib
import json
import os
import re
import signal
from pathlib import Path
import subprocess
import tempfile
import time
import unittest

SCRIPTS = Path(__file__).resolve().parents[2] / 'scripts'
SHIM = '''#!/usr/bin/python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
root = pathlib.Path(os.environ['FIXTURE'])
with (root/'calls').open('a') as f: f.write(json.dumps([name]+args)+'\\n')
if name == 'sudo':
    if args == ['-v']: sys.exit(0)
    if '-l' in args: sys.exit(int(os.environ.get('VERIFY_FAIL', '0')))
    args = [a for a in args if a != '-n']
    os.execvp(args[0], args)
if name == 'mv': os.execv('/bin/mv', ['/bin/mv']+args)
if name == 'lockf':
    (root/'lock-entered').touch()
    os.execv('/usr/bin/lockf', ['/usr/bin/lockf']+args)
if name == 'pmset': sys.exit(int(os.environ.get('PMSET_FAIL', '0')))
if name == 'ps':
    if args[1] == os.environ.get('EXITED_PID'): sys.exit(1)
    print(args[1])
if name == 'kill': sys.exit(int(args[-1] == os.environ.get('FAIL_PID')))
if name == 'pgrep': sys.exit(0 if os.environ.get('RUNNING') == '1' else 1)
if name == 'id': print('0' if os.environ.get('ROOT_USER') else ('501' if '-u' in args else os.environ.get('ACCOUNT_NAME', 'alice')))
if name == 'swift':
    if '--show-bin-path' in args: print(root/'bin')
if name == 'install':
    import shutil
    shutil.copyfile(args[-2], args[-1])
if name == 'plutil':
    if len(args) > 1 and os.environ.get('POWER_EDIT_FAIL') == ':'.join(args[:2]):
        calls = [json.loads(line) for line in (root/'calls').read_text().splitlines()]
        if any(c[0] == 'pmset' for c in calls): sys.exit(71)
    if os.environ.get('WRITE_FAIL') and '-replace' in args: sys.exit(1)
    os.execv('/usr/bin/plutil', ['/usr/bin/plutil']+args)
'''

# Executed only in fixture paths; simulates the native contract without signals,
# CoreAudio, ServiceManagement or Keychain. Real implementations have Swift tests.
HELPER = '''#!/usr/bin/python3
import fcntl, json, os, pathlib, sys
args = sys.argv[1:]
root = pathlib.Path(os.environ['FIXTURE'])
with (root/'calls').open('a') as f: f.write(json.dumps(['native', sys.argv[0]]+args)+'\\n')
if args == ['--maintenance-protocol']:
    print('insomnia-maintenance-v1'); sys.exit(0)
support = pathlib.Path(os.environ.get('INSOMNIA_HOME') or pathlib.Path(os.environ['HOME'])/'Library/Application Support/Insomnia')
with (support/'recovery.lock').open('a') as held:
    try: fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError: pass
    else: sys.exit(91)
if args[0] == '--maintenance-uninstall': sys.exit(int(os.environ.get('MAINTENANCE_FAIL', '0')))
p = pathlib.Path(args[1]); state = json.loads(p.read_text())
if args[0] == '--validate-recovery-state':
    if not isinstance(state, dict): sys.exit(1)
    for key in ['sleepDisabledByUs', 'lowPowerSetByUs', 'originalSleepDisabled', 'originalBatteryLowPowerMode']:
        if key in state and type(state[key]) != bool: sys.exit(1)
    pids = state.get('frozenPids', [])
    sys.exit(0 if isinstance(pids, list) and all(type(p) == int and 0 < p <= 2147483647 for p in pids) else 1)
if args[0] != '--recover-owned': sys.exit(2)
owned = state.get('frozenProcesses', [])
legacy = set(state.get('frozenPids', [])) - {p['pid'] for p in owned}
remaining = [p for p in owned if str(p['pid']) == os.environ.get('FAIL_PID') and str(p['pid']) != os.environ.get('EXITED_PID')]
state['frozenProcesses'] = remaining
state['frozenPids'] = sorted(legacy | {p['pid'] for p in remaining})
if not state['frozenPids']: state['dockerFrozen'] = False
if state.get('savedOutputDeviceUID') and not os.environ.get('AUDIO_FAIL'):
    for key in ['savedOutputDeviceUID', 'savedMuted', 'savedOutputVolume']: state.pop(key, None)
p.write_text(json.dumps(state))
sys.exit(int(bool(state['frozenPids'] or any(k in state for k in ['savedMuted', 'savedOutputVolume', 'savedOutputDeviceUID']))))
'''

class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root/'home & tests'
        self.support = self.home/'support & journal'
        self.support.mkdir(parents=True, mode=0o700)
        self.shims = self.root/'shims'
        self.shims.mkdir()
        names = ['sudo', 'pmset', 'kill', 'ps', 'pgrep', 'pkill', 'osascript', 'sleep',
                 'launchctl', 'codesign', 'swift', 'id', 'visudo', 'install', 'plutil', 'lockf', 'mv']
        for name in names:
            p = self.shims/name
            p.write_text(SHIM)
            p.chmod(0o700)
        self.repo = self.root/'repo'
        (self.repo/'scripts').mkdir(parents=True)
        (self.repo/'Resources').mkdir()
        (self.repo/'Resources/Info.plist').write_text('<?xml version="1.0"?><plist version="1.0"><dict/></plist>')
        (self.root/'bin').mkdir()
        binary = self.root/'bin/Insomnia'
        binary.write_text(HELPER)
        binary.chmod(0o700)
        for source in SCRIPTS.glob('*.sh'):
            code = source.read_text()
            for name in names:
                for prefix in ['/usr/bin/', '/usr/sbin/', '/bin/']:
                    code = code.replace(prefix+name, str(self.shims/name))
            code = code.replace('if kill ', 'if "'+str(self.shims/'kill')+'" ')
            code = code.replace('/etc/sudoers.d/insomnia', str(self.root/'sudoers'))
            code = code.replace('/private/tmp/com.kgarg.insomnia-install.lock', str(self.root/'installer.lock'))
            (self.repo/'scripts'/source.name).write_text(code)
        self.env = dict(os.environ, HOME=str(self.home), INSOMNIA_HOME=str(self.support),
                        FIXTURE=str(self.root), PATH=str(self.shims)+':/usr/bin:/bin', USER='forged')
        self.install_helper()

    def install_helper(self):
        helper = self.support/'InsomniaRecovery'
        helper.write_text(HELPER)
        helper.chmod(0o700)
        (self.support/'InsomniaRecovery.protocol').write_text(
            'insomnia-maintenance-v1 ' + hashlib.sha256(helper.read_bytes()).hexdigest() + '\n')

    def run_script(self, name, *args, **env):
        return subprocess.run(['/bin/bash', str(self.repo/'scripts'/name), *args],
                              env=dict(self.env, **env), capture_output=True, text=True, timeout=15)

    def state(self, **values):
        value = dict(sleepDisabledByUs=True, lowPowerSetByUs=True, frozenPids=[42], dockerFrozen=True)
        value.update(values)
        if 'frozenProcesses' not in values and isinstance(value['frozenPids'], list):
            value['frozenProcesses'] = [dict(pid=pid, startTimeMicroseconds=123, bootID='fixture')
                                        for pid in value['frozenPids'] if type(pid) == int and pid > 0]
        (self.support/'state.json').write_text(json.dumps(value))
        (self.support/'session.json').write_text('{"endsAt":"2000-01-01T00:00:00Z"}')

    def journal(self):
        return json.loads((self.support/'state.json').read_text())

    def calls(self):
        p = self.root/'calls'
        return [json.loads(s) for s in p.read_text().splitlines()] if p.exists() else []

class RecoveryTests(Fixture):
    def test_untrusted_helper_is_never_executed_but_power_progress_is_saved(self):
        self.state()
        (self.support/'InsomniaRecovery').write_text('#!/bin/bash\nexit 0\n')
        self.assertNotEqual(self.run_script('backstop.sh', '--force').returncode, 0)
        self.assertFalse(self.journal()['sleepDisabledByUs'])
        self.assertEqual(self.journal()['frozenPids'], [42])
        self.assertFalse(any(c[0] == 'native' for c in self.calls()))

    def test_missing_helper_allows_power_only_restore_and_blocks_corrupt_power(self):
        (self.support/'InsomniaRecovery').unlink()
        self.state(frozenPids=[], dockerFrozen=False, originalSleepDisabled=True)
        self.assertEqual(self.run_script('backstop.sh', '--force').returncode, 0)
        self.assertNotIn('originalSleepDisabled', self.journal())
        self.assertIn(['pmset', '-a', 'disablesleep', '1'], self.calls())
        self.state(originalSleepDisabled='unknown')
        before = (self.support/'state.json').read_bytes()
        count = sum(c[0] == 'pmset' for c in self.calls())
        self.assertNotEqual(self.run_script('backstop.sh', '--force').returncode, 0)
        self.assertEqual((self.support/'state.json').read_bytes(), before)
        self.assertEqual(sum(c[0] == 'pmset' for c in self.calls()), count)

    def test_legacy_pids_are_retained_without_any_shell_signal(self):
        self.state(frozenPids=[42], frozenProcesses=[])
        self.assertNotEqual(self.run_script('backstop.sh', '--force').returncode, 0)
        self.assertEqual(self.journal()['frozenPids'], [42])
        self.assertFalse(any(c[0] in ['kill', 'ps'] for c in self.calls()))
        self.assertNotIn('/bin/kill', (SCRIPTS/'backstop.sh').read_text())

    def test_helper_partial_progress_survives_failure_and_original_off_restores(self):
        self.state(frozenPids=[42, 43], originalSleepDisabled=False, originalBatteryLowPowerMode=False,
                   savedOutputDeviceUID='device', savedOutputVolume=0.6, savedMuted=False)
        result = self.run_script('backstop.sh', '--force', FAIL_PID='43', AUDIO_FAIL='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.journal()['frozenPids'], [43])
        self.assertEqual(self.journal()['savedOutputDeviceUID'], 'device')
        self.assertNotIn('originalSleepDisabled', self.journal())
        self.assertIn(['pmset', '-a', 'disablesleep', '0'], self.calls())
        self.assertIn(['pmset', '-b', 'lowpowermode', '0'], self.calls())

    def test_failed_power_preserves_both_original_and_owned_flag(self):
        self.state(originalSleepDisabled=True, originalBatteryLowPowerMode=False)
        self.assertNotEqual(self.run_script('backstop.sh', '--force', PMSET_FAIL='1').returncode, 0)
        self.assertTrue(self.journal()['sleepDisabledByUs'])
        self.assertTrue(self.journal()['originalSleepDisabled'])
        self.assertFalse(self.journal()['originalBatteryLowPowerMode'])

    def test_log_rotation_keeps_bounded_whole_lines_and_private_modes(self):
        self.state()
        log = self.support/'Logs/insomnia.log'
        log.parent.mkdir()
        log.write_text(('legacy line\n' * 30000))
        log.chmod(0o644)
        self.assertEqual(self.run_script('backstop.sh', '--force').returncode, 0)
        for file in [log, log.with_name('insomnia.log.1')]:
            self.assertLessEqual(file.stat().st_size, 262144)
            self.assertEqual(file.stat().st_mode & 0o777, 0o600)
        self.assertTrue(log.with_name('insomnia.log.1').read_text().startswith('legacy line\n'))
        self.assertEqual(log.parent.stat().st_mode & 0o777, 0o700)

    def test_legacy_oversized_archive_is_bounded_without_active_rotation(self):
        self.state()
        log = self.support/'Logs/insomnia.log'
        log.parent.mkdir()
        log.write_text('recent line\n')
        backup = log.with_name('insomnia.log.1')
        backup.write_text('older line\n' * 30000)
        backup.chmod(0o644)
        self.assertEqual(self.run_script('backstop.sh', '--force').returncode, 0)
        self.assertTrue(log.read_text().startswith('recent line\n'))
        self.assertLessEqual(backup.stat().st_size, 262144)
        self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
        self.assertTrue(backup.read_text().startswith('older line\n'))

    def test_power_missing_and_clean_journals_do_not_call_pmset(self):
        result = self.run_script('backstop.sh', '--force')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(c[0] == 'pmset' for c in self.calls()))
        self.state(sleepDisabledByUs=False, lowPowerSetByUs=False, frozenPids=[], dockerFrozen=False)
        self.assertEqual(self.run_script('backstop.sh', '--force').returncode, 0)
        self.assertFalse(any(c[0] == 'pmset' for c in self.calls()))

    def test_power_original_preferences_are_restored_and_cleared(self):
        self.state(sleepDisabledByUs=False, lowPowerSetByUs=False, originalSleepDisabled=True,
                   originalBatteryLowPowerMode=True, frozenPids=[], dockerFrozen=False)
        result = self.run_script('backstop.sh', '--force')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(['pmset', '-a', 'disablesleep', '1'], self.calls())
        self.assertIn(['pmset', '-b', 'lowpowermode', '1'], self.calls())
        self.assertNotIn('originalSleepDisabled', self.journal())
        self.assertNotIn('originalBatteryLowPowerMode', self.journal())

    def test_power_unknown_schema_types_preserve_journal_without_side_effects(self):
        for key, value in [('sleepDisabledByUs', 'true'), ('originalSleepDisabled', 1),
                           ('originalBatteryLowPowerMode', []), ('lowPowerSetByUs', None)]:
            self.state(**{key: value})
            before = (self.support/'state.json').read_bytes()
            self.assertNotEqual(self.run_script('backstop.sh', '--force').returncode, 0)
            self.assertEqual((self.support/'state.json').read_bytes(), before)
        self.assertFalse(any(c[0] == 'pmset' for c in self.calls()))

    def recover_with_log_timeout(self, native_complete=True):
        process = subprocess.Popen(['/bin/bash', str(self.repo/'scripts/backstop.sh'), '--force'],
                                   env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   text=True, start_new_session=True)
        try:
            stdout, stderr = process.communicate(timeout=10)
        except subprocess.TimeoutExpired:
            # Only this test's freshly created process group, including its blocked
            # logging child. Never leave a red FIFO case holding the fixture lease.
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate(timeout=5)
            self.fail('Unsafe recovery path blocked recovery for 10 seconds')
        self.assertEqual(process.returncode, 0 if native_complete else 1, stdout + stderr)
        self.assertFalse(self.journal()['sleepDisabledByUs'])
        self.assertEqual(self.journal()['frozenPids'], [] if native_complete else [42])
        return stdout + stderr

    def test_fifo_helper_paths_fall_back_to_power_without_blocking(self):
        for name in ['InsomniaRecovery', 'InsomniaRecovery.protocol']:
            with self.subTest(name=name):
                self.install_helper()
                self.state()
                path = self.support/name
                path.unlink()
                os.mkfifo(path, 0o600)
                before = path.lstat()
                try:
                    self.recover_with_log_timeout(native_complete=False)
                    self.assertEqual(path.lstat().st_mode, before.st_mode)
                    self.assertEqual(path.lstat().st_ino, before.st_ino)
                    self.assertFalse(any(c[0] == 'native' for c in self.calls()))
                finally:
                    path.unlink()


    def test_symlink_helper_paths_never_execute_even_with_matching_hash(self):
        for name in ['InsomniaRecovery', 'InsomniaRecovery.protocol']:
            with self.subTest(name=name):
                self.install_helper()
                self.state()
                path = self.support/name
                outside = self.root/('outside-' + name)
                path.rename(outside)
                before = outside.stat()
                content = outside.read_bytes()
                path.symlink_to(outside)
                self.recover_with_log_timeout(native_complete=False)
                self.assertTrue(path.is_symlink())
                self.assertEqual(outside.read_bytes(), content)
                self.assertEqual(outside.stat().st_mode, before.st_mode)
                self.assertEqual(outside.stat().st_mtime_ns, before.st_mtime_ns)
                self.assertFalse(any(c[0] == 'native' for c in self.calls()))
                path.unlink()

    def test_oversized_protocol_marker_is_not_read_or_executed(self):
        self.state()
        (self.support/'InsomniaRecovery.protocol').write_text('x' * 1024)
        cat_shim = self.shims/'protocol-cat'
        cat_shim.write_text(SHIM)
        cat_shim.chmod(0o700)
        script = self.repo/'scripts/backstop.sh'
        script.write_text(script.read_text().replace('/bin/cat', str(cat_shim)))
        self.recover_with_log_timeout(native_complete=False)
        self.assertFalse(any(c[0] in ['protocol-cat', 'native'] for c in self.calls()))

    def test_custom_root_owned_by_another_uid_is_rejected_before_lock(self):
        self.state()
        before = (self.support/'state.json').read_bytes()
        result = self.run_script('backstop.sh', '--force', ROOT_USER='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.support/'state.json').read_bytes(), before)
        self.assertFalse((self.support/'recovery.lock').exists())
        self.assertFalse(any(c[0] in ['lockf', 'native', 'pmset'] for c in self.calls()))

    def test_shared_custom_root_is_rejected_before_chmod_lock_or_journal_mutation(self):
        self.state()
        self.support.chmod(0o755)
        before = self.support.stat()
        state = (self.support/'state.json').read_bytes()
        session = (self.support/'session.json').read_bytes()
        result = self.run_script('backstop.sh', '--force')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.support.stat().st_mode, before.st_mode)
        self.assertEqual(self.support.stat().st_mtime_ns, before.st_mtime_ns)
        self.assertEqual((self.support/'state.json').read_bytes(), state)
        self.assertEqual((self.support/'session.json').read_bytes(), session)
        self.assertFalse((self.support/'recovery.lock').exists())
        self.assertFalse(any(c[0] in ['lockf', 'native', 'pmset'] for c in self.calls()))

    def test_symlink_custom_root_is_rejected_without_touching_target(self):
        outside = self.root/'private-outside-root'
        outside.mkdir(mode=0o700)
        link = self.root/'custom-link'
        link.symlink_to(outside, target_is_directory=True)
        before = outside.stat()
        result = self.run_script('backstop.sh', '--force', INSOMNIA_HOME=str(link))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(list(outside.iterdir()), [])
        self.assertEqual(outside.stat().st_mode, before.st_mode)
        self.assertEqual(outside.stat().st_mtime_ns, before.st_mtime_ns)
        self.assertFalse(any(c[0] == 'lockf' for c in self.calls()))

    def test_new_custom_root_is_created_private(self):
        custom = self.root/'new-root'
        result = self.run_script('backstop.sh', '--force', INSOMNIA_HOME=str(custom))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(custom.stat().st_mode & 0o777, 0o700)
        self.assertTrue((custom/'recovery.lock').exists())

    def test_fifo_log_is_skipped_without_blocking_or_chmod(self):
        self.state()
        log = self.support/'Logs/insomnia.log'
        log.parent.mkdir()
        os.mkfifo(log, 0o644)
        before = log.lstat()
        self.recover_with_log_timeout()
        self.assertEqual(log.lstat().st_mode, before.st_mode)
        self.assertEqual(log.lstat().st_ino, before.st_ino)

    def test_nonregular_archive_is_preserved_when_rotation_would_replace_it(self):
        self.state()
        log = self.support/'Logs/insomnia.log'
        log.parent.mkdir()
        log.write_text('legacy line\n' * 30000)
        archive = log.with_name('insomnia.log.1')
        os.mkfifo(archive, 0o644)
        before = archive.lstat()
        self.recover_with_log_timeout()
        self.assertEqual(archive.lstat().st_mode, before.st_mode)
        self.assertEqual(archive.lstat().st_ino, before.st_ino)
        self.assertEqual(log.read_text(), 'legacy line\n' * 30000)

    def test_dangling_symlink_log_does_not_create_outside_target(self):
        self.state()
        outside = self.root/'must-not-be-created'
        log = self.support/'Logs/insomnia.log'
        log.parent.mkdir()
        log.symlink_to(outside)
        self.recover_with_log_timeout()
        self.assertTrue(log.is_symlink())
        self.assertFalse(outside.exists())

    def test_symlink_log_and_archive_never_touch_outside_target(self):
        outside = self.root/'outside-secret'
        outside.write_text('private target must remain untouched\n')
        outside.chmod(0o644)
        before = outside.stat()
        log_dir = self.support/'Logs'
        log_dir.mkdir()
        for name in ['insomnia.log', 'insomnia.log.1']:
            with self.subTest(name=name):
                self.state()
                path = log_dir/name
                path.symlink_to(outside)
                output = self.recover_with_log_timeout()
                self.assertTrue(path.is_symlink())
                self.assertEqual(outside.read_text(), 'private target must remain untouched\n')
                self.assertEqual(outside.stat().st_mode, before.st_mode)
                self.assertEqual(outside.stat().st_mtime_ns, before.st_mtime_ns)
                self.assertNotIn('private target', output)
                path.unlink()

    def test_symlink_log_directory_never_creates_or_chmods_outside_logs(self):
        self.state()
        outside = self.root/'outside-directory'
        outside.mkdir(mode=0o755)
        before = outside.stat()
        (self.support/'Logs').symlink_to(outside, target_is_directory=True)
        self.recover_with_log_timeout()
        self.assertEqual(list(outside.iterdir()), [])
        self.assertEqual(outside.stat().st_mode, before.st_mode)
        self.assertEqual(outside.stat().st_mtime_ns, before.st_mtime_ns)

    def test_broken_log_does_not_block_restore(self):
        self.state()
        (self.support/'Logs/insomnia.log').mkdir(parents=True)
        result = self.run_script('backstop.sh', '--force')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.journal()['sleepDisabledByUs'])
        self.assertEqual(self.journal()['frozenPids'], [])

    def test_failed_restore_invalidates_session_and_retains_entries(self):
        self.state()
        result = self.run_script('backstop.sh', '--force', PMSET_FAIL='1', FAIL_PID='42')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.support/'session.json').exists())
        self.assertTrue(self.journal()['sleepDisabledByUs'])
        self.assertEqual(self.journal()['frozenPids'], [42])
        self.assertTrue(self.journal()['dockerFrozen'])

    def test_invalid_pid_array_never_signals_any_entry(self):
        for pids in [[0, 42], [-42], ['42'], [1.5], [2147483648], {'pid':42}, 0, '42']:
            with self.subTest(pids=pids):
                self.state(frozenPids=pids)
                result = self.run_script('backstop.sh', '--force')
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.journal()['frozenPids'], pids)
        self.assertFalse(any(c[0] == 'kill' for c in self.calls()))

    def test_journal_failure_is_failure_and_preserves_original(self):
        self.state()
        before = (self.support/'state.json').read_bytes()
        result = self.run_script('backstop.sh', '--force', WRITE_FAIL='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((self.support/'state.json').read_bytes(), before)
        self.assertFalse((self.support/'session.json').exists())

    def test_power_journal_edit_failures_after_successful_pmset_preserve_original(self):
        for operation in ['-replace:sleepDisabledByUs', '-remove:originalSleepDisabled']:
            with self.subTest(operation=operation):
                self.state(originalSleepDisabled=True, originalBatteryLowPowerMode=False)
                before = (self.support/'state.json').read_bytes()
                calls_before = len(self.calls())
                result = self.run_script('backstop.sh', '--force', POWER_EDIT_FAIL=operation)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(['pmset', '-a', 'disablesleep', '1'], self.calls()[calls_before:])
                self.assertEqual((self.support/'state.json').read_bytes(), before)
                self.assertFalse((self.support/'session.json').exists())
                self.assertNotIn('recovery complete', (self.support/'Logs/insomnia.log').read_text())

    def test_shared_flock_guards_decision_and_preserves_new_session(self):
        self.state()
        lock = self.support/'recovery.lock'
        with lock.open('w') as held:
            fcntl.flock(held, fcntl.LOCK_EX)
            process = subprocess.Popen(['/bin/bash', str(self.repo/'scripts/backstop.sh')],
                                       env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            self.addCleanup(lambda: process.kill() if process.poll() is None else None)
            deadline = time.monotonic()+5
            while not (self.root/'lock-entered').exists() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue((self.root/'lock-entered').exists())
            self.assertFalse(any(c[0] == 'pmset' for c in self.calls()))
            (self.support/'session.json').write_text('{"endsAt":"2099-01-01T00:00:00Z"}')
            fcntl.flock(held, fcntl.LOCK_UN)
            _, stderr = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 0, stderr)
        self.assertTrue((self.support/'session.json').exists())
        self.assertTrue(lock.exists())
        self.assertFalse(any(c[0] == 'pmset' for c in self.calls()))

    def test_partial_pid_restore_keeps_only_failed_entries(self):
        self.state(frozenPids=[42, 43])
        result = self.run_script('backstop.sh', '--force', FAIL_PID='43')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.journal()['frozenPids'], [43])

    def test_exited_pid_does_not_block_recovery(self):
        self.state()
        result = self.run_script('backstop.sh', '--force', FAIL_PID='42', EXITED_PID='42')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.journal()['frozenPids'], [])

    def test_production_system_executables_exist(self):
        for source in SCRIPTS.glob('*.sh'):
            for path in re.findall(r'/(?:usr/)?s?bin/[A-Za-z0-9_-]+', source.read_text()):
                self.assertTrue(os.access(path, os.X_OK), f'{source.name}: {path}')

    def test_audio_is_retained_and_blocks_teardown(self):
        self.state(savedMuted=False, savedOutputVolume=0.6)
        result = self.run_script('backstop.sh', '--force')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.journal()['savedMuted'], False)
        self.assertEqual(self.journal()['savedOutputVolume'], 0.6)

if __name__ == '__main__': unittest.main()
