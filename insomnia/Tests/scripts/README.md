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
returns nonzero, and prevents uninstall teardown. Audio recovery remains the
app's responsibility: outstanding saved audio values prevent shell uninstall.
The lock inode is retained even with --purge to keep existing waiters coordinated.
These tests do not certify real macOS permissions, launchd or hardware behavior.

Install and uninstall share `/private/tmp/com.kgarg.insomnia-install.lock`, an
exclusive directory guard held through sudoers mutations. A killed installer
can leave it behind. Inspect running installers and the guard's ownership before
having its owner remove an abandoned, empty guard; scripts never steal one.
