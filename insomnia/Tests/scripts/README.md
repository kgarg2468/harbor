# Hermetic shell recovery tests

Run on macOS with the system Python (no dependencies):

```sh
/usr/bin/python3 -m unittest discover -s insomnia/Tests/scripts -v
shellcheck insomnia/scripts/{backstop,install,uninstall}.sh
```

Tests execute temporary copies of the actual scripts. Absolute command paths in
those copies point to shims for sudo, pmset, signals, app quit/discovery, Swift,
codesign, installation and launchctl. No real power changes, privileges, process
signals, application operations or LaunchAgents are used. System plutil, BSD
lockf and filesystem operations operate only on temporary fixtures. The flock
test holds the real shared lock, publishes a newer session, then releases it and
checks that recovery rereads the session before performing any side effect.

Install/uninstall require the standard per-user Application Support, Logs and
LaunchAgents paths, and reject any nonempty INSOMNIA_HOME before side effects.
The app and standalone backstop still support relocated journals for testing;
installer scripts cannot purge a custom root. Failed
recovery invalidates the session under the shared lock, keeps outstanding state,
returns nonzero, and prevents uninstall teardown. The native helper restores identified process/audio ownership under that lease;
legacy bare PIDs and unidentified audio remain unresolved. Fixtures simulate the
native contract; Swift tests cover the actual implementation. Missing or unverified
helpers never run, but known-owned power preferences can still be restored.
Both instance.lock and recovery.lock inodes remain even with --purge.

Install stages the same built binary as InsomniaRecovery (0700). Its private
InsomniaRecovery.protocol sidecar contains `insomnia-maintenance-v1 <SHA-256>`.
The signed bundle's InsomniaMaintenanceProtocol plist marker gates maintenance
arguments. Uninstall runs login-item cleanup from that actual bundle; only
--purge requests service-wide hotspot Keychain deletion. A legacy bundle without
this protocol blocks teardown and explains the manual Login Items/upgrade path.
Failed replacement rolls the app, helper, sidecar, script and plist back under
the shared lease. A crash during replacement can leave a hash mismatch, which
fails closed; rerunning the current installer repairs the generation.

Shell logs rotate at 256 KiB, retain a bounded whole-line .1 tail, and set private
modes before appending. All logging failures are best effort.
These tests do not certify real macOS permissions, launchd or hardware behavior.

Install and uninstall share `/private/tmp/com.kgarg.insomnia-install.lock`, an
exclusive directory guard held through sudoers mutations. A killed installer
can leave it behind. Inspect running installers and the guard's ownership before
having its owner remove an abandoned, empty guard; scripts never steal one.
