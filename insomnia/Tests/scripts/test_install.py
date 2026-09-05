import plistlib
import unittest
from test_recovery import Fixture

class InstallTests(Fixture):
    def setUp(self):
        super().setUp()
        self.support = self.home/'Library/Application Support/Insomnia'
        self.support.mkdir(parents=True)
        self.env['INSOMNIA_HOME'] = ''

    def inject_shim(self, name, code):
        path = self.shims/name
        source = path.read_text()
        path.write_text(source.replace("if name == 'sudo':", code + "\nif name == 'sudo':", 1))

    def installed_files(self):
        app = self.home/'Applications/Insomnia.app'
        app.mkdir(parents=True)
        (app/'sentinel').write_text('existing')
        helper = self.support/'backstop.sh'
        helper.write_text('existing helper')
        plist = self.home/'Library/LaunchAgents/com.insomnia.backstop.plist'
        plist.parent.mkdir(parents=True)
        plist.write_bytes(plistlib.dumps({'Label': 'com.insomnia.backstop'}))
        commands = ['-a disablesleep 1', '-a disablesleep 0', '-b lowpowermode 1', '-b lowpowermode 0']
        grant = self.root/'sudoers'
        grant.write_text(''.join(
            f'alice ALL=(root) NOPASSWD: {self.shims}/pmset {command}\n' for command in commands))
        return app, helper, plist, grant

    def test_app_reopened_during_build_blocks_commit(self):
        app, helper, plist, grant = self.installed_files()
        original = [p.read_bytes() for p in [helper, plist, grant]]
        self.inject_shim('swift', "(root/'built').touch()")
        self.inject_shim('pgrep', "if (root/'built').exists(): sys.exit(0)")
        result = self.run_script('install.sh')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((app/'sentinel').exists())
        self.assertEqual([p.read_bytes() for p in [helper, plist, grant]], original)
        self.assertFalse(any(c[0] in ['install', 'pmset', 'launchctl'] for c in self.calls()))

    def test_failed_bootout_keeps_still_loaded_job_files(self):
        app, helper, plist, grant = self.installed_files()
        self.inject_shim('launchctl', "if args[0] == 'bootout': sys.exit(5)\nif args[0] == 'print': sys.exit(0)")
        result = self.run_script('uninstall.sh', '--purge')
        self.assertNotEqual(result.returncode, 0)
        for path in [app/'sentinel', helper, plist, grant]:
            self.assertTrue(path.exists(), str(path))
        self.assertIn(['launchctl', 'print', 'gui/501/com.insomnia.backstop'], self.calls())

    def test_unload_lookup_error_does_not_count_as_absent(self):
        app, helper, plist, grant = self.installed_files()
        self.inject_shim('launchctl', "if args[0] == 'bootout': sys.exit(5)\nif args[0] == 'print': sys.exit(1)")
        result = self.run_script('uninstall.sh')
        self.assertNotEqual(result.returncode, 0)
        for path in [app/'sentinel', helper, plist, grant]:
            self.assertTrue(path.exists(), str(path))

    def test_failed_bootout_of_absent_job_allows_uninstall(self):
        app, helper, plist, grant = self.installed_files()
        self.inject_shim('launchctl', "if args[0] == 'bootout': sys.exit(5)\nif args[0] == 'print': sys.exit(113)")
        result = self.run_script('uninstall.sh')
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        for path in [app, helper, plist, grant]:
            self.assertFalse(path.exists(), str(path))
        self.assertIn(['launchctl', 'print', 'gui/501/com.insomnia.backstop'], self.calls())

    def test_commit_and_teardown_hold_one_recovery_lease(self):
        check = """import fcntl
lock = pathlib.Path(os.environ['HOME'])/'Library/Application Support/Insomnia/recovery.lock'
with lock.open('a') as held:
    try: fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError: pass
    else: sys.exit(91)
"""
        for name in ['install', 'pmset', 'launchctl']:
            self.inject_shim(name, check)
        result = self.run_script('install.sh')
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        result = self.run_script('uninstall.sh')
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertEqual(sum(c[0] == 'lockf' for c in self.calls()), 2,
                         'backstop must reuse the installer lease, not reacquire it')
        self.assertTrue((self.support/'recovery.lock').exists())

    def test_override_rejected_before_side_effects(self):
        custom = self.home/'custom-root'
        custom.mkdir()
        for script in ['install.sh', 'uninstall.sh']:
            result = self.run_script(script, INSOMNIA_HOME=str(custom))
            self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c[0] in ['sudo', 'swift', 'pmset', 'launchctl'] for c in self.calls()))
        self.assertEqual(list(custom.iterdir()), [])

    def test_duplicate_commands_do_not_establish_grant_ownership(self):
        grant = self.root/'sudoers'
        original = f'alice ALL=(root) NOPASSWD: {self.shims}/pmset -a disablesleep 0\n' * 4
        for script in ['install.sh', 'uninstall.sh']:
            grant.write_text(original)
            result = self.run_script(script)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(grant.read_text(), original)
        self.assertFalse(any(c[0] in ['swift', 'pmset', 'launchctl'] for c in self.calls()))

    def test_restore_failure_prevents_uninstall_teardown(self):
        self.state()
        (self.support/'backstop.sh').write_text((self.repo/'scripts/backstop.sh').read_text())
        result = self.run_script('uninstall.sh', '--purge', PMSET_FAIL='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.support/'session.json').exists())
        self.assertTrue((self.support/'backstop.sh').exists())
        self.assertFalse(any(c[0] == 'launchctl' for c in self.calls()))

    def test_running_app_blocks_install_and_uninstall(self):
        for script in ['install.sh', 'uninstall.sh']:
            result = self.run_script(script, RUNNING='1')
            self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(c[0] in ['pmset', 'launchctl'] for c in self.calls()))

    def test_other_account_cannot_enter_occupied_installer_guard(self):
        guard = self.root/'installer.lock'
        guard.mkdir()
        (guard/'owner').write_text('alice')
        for script in ['install.sh', 'uninstall.sh']:
            result = self.run_script(script, ACCOUNT_NAME='bob')
            self.assertNotEqual(result.returncode, 0)
        self.assertEqual((guard/'owner').read_text(), 'alice')
        self.assertFalse(any(c[0] == 'sudo' for c in self.calls()))

    def test_root_and_foreign_owner_rejected(self):
        for script in ['install.sh', 'uninstall.sh']:
            self.assertNotEqual(self.run_script(script, ROOT_USER='1').returncode, 0)
        grant = self.root/'sudoers'
        grant.write_text('bob ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0\n')
        for script in ['install.sh', 'uninstall.sh']:
            self.assertNotEqual(self.run_script(script).returncode, 0)
        self.assertTrue(grant.read_text().startswith('bob '))

    def test_install_identity_paths_and_modes(self):
        result = self.run_script('install.sh')
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertIn('alice ALL=', (self.root/'sudoers').read_text())
        plist = plistlib.loads((self.home/'Library/LaunchAgents/com.insomnia.backstop.plist').read_bytes())
        self.assertEqual(plist['ProgramArguments'][1], str(self.support/'backstop.sh'))
        self.assertNotIn('EnvironmentVariables', plist)
        self.assertEqual(self.support.stat().st_mode & 0o777, 0o700)
        self.assertEqual(plist['KeepAlive'], {'SuccessfulExit': False})
        self.assertEqual(plist['ThrottleInterval'], 60)

    def test_same_account_legacy_grant_migrates(self):
        commands = ['-a disablesleep 1', '-a disablesleep 0', '-b lowpowermode 1', '-b lowpowermode 0']
        (self.root/'sudoers').write_text(''.join(
            f'alice ALL=(root) NOPASSWD: {self.shims}/pmset {command}\n' for command in commands))
        result = self.run_script('install.sh')
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertIn('# Insomnia owner UID: 501', (self.root/'sudoers').read_text())

    def test_empty_journal_restore_failure_blocks_install(self):
        result = self.run_script('install.sh', PMSET_FAIL='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(self.journal()['sleepDisabledByUs'])
        self.assertFalse(any(c[0] == 'launchctl' for c in self.calls()))

    def test_verification_failure_keeps_existing_bundle(self):
        app = self.home/'Applications/Insomnia.app'
        app.mkdir(parents=True)
        (app/'sentinel').write_text('existing')
        result = self.run_script('install.sh', VERIFY_FAIL='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((app/'sentinel').exists())

if __name__ == '__main__': unittest.main()
