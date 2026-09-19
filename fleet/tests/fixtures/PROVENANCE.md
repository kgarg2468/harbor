# Pair command fixtures

`pair_helpers.bash` constructs disposable command shims for the slice 5d tests.
It is test scaffolding, not captured vendor output. The simulated vendor checks
for a prepared journal entry, emits stand-in output, and copies an existing Serve
fixture. Its hang mode ignores TERM to exercise bounded KILL escalation.

Runtime, descriptor, and Serve response bodies come from the existing fixtures
in `t3/server-runtime/`, `t3/environment/`, and `tailscale/serve-status/`; their
existing provenance applies. No new populated Serve output was measured here.
The tests' additional 8443 Funnel listener is constructed, not measured.
