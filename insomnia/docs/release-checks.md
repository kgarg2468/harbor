# Source preview release checks

The release work uses GPT-6 Astra in the Codex harness for implementation and
security/readiness decisions. Luna only watches and quotes CI/Greptile results.
This is a source-build preview, not a stable or notarized binary release.

## Automated evidence

The original 178-test suite passed, but six independent probes exposed nine
failed assertions. Fixes now include permanent regression tests for lifecycle
races, failed recovery, stale journals, safe process/audio ownership, power
preference preservation, browser arguments/scans, network cancellation,
configuration, privacy and command timeouts.

The first consolidated implementation passed 255 Swift tests on macOS 26.2.
Additional ownership/privacy branches have their own passing tests; the final
combined revision and full result must be recorded after those are integrated.
Script tests use real temporary files/locks and command shims, with no live sudo,
pmset, app termination or launchd mutation. Passing fakes do not prove macOS
permissions or hardware behavior.

Review is split into focused pull requests; the final integration must include
all dependency branches. Greptile findings are checked against source and tests.
The historical handoff-before-nudge finding was rejected because it records an
already-observed recovery; the superseded-browser-scan finding was reproduced
and fixed. A successful reviewer check alone does not mean every comment has
been resolved.

## Hardware acceptance still required

Record Mac model, macOS build, app revision, test date and sanitized result for
each row. “Not run” is not a pass.

| Scenario | Status | Acceptance |
| --- | --- | --- |
| Clean account install/uninstall | Not run | Build without existing grants; accept/deny sudo; verify loaded agent, exact grant and complete removal. |
| Timed closed-lid work on AC and battery | Historical normal-session evidence only | Verify actual task progress on a ventilated surface, reopen/end/quit and compare owned power settings. |
| Independent deadline recovery | Failure fixtures pass; live test not run | On a disposable session, terminate the GUI and inspect real recovery at the deadline. Test restart/login and absent privileges separately. |
| Initial closed lid and subsequent session | Fake regression tests | Real start/reconcile already closed, reopen, end and start again; countdown and actions remain correct. |
| Browser occlusion | Not run | Measure headed browser visibility/timer/work progress closed-lid with no external display, with and without flags; verify profiles/tabs and refused quit. Keep disabled until verified. |
| Hotspot and Location | Not run; no credentials supplied | Grant/deny/restricted Location; correct/wrong password; absent hotspot; actual association and resumed request; end during retry. |
| Docker Desktop | Fake local-daemon tests | Real idle/busy/error cases with alternative contexts/env; containers resume correctly. Default off. |
| Audio and device changes | Fake identity/failure tests | Mute/restore original volume and UID; switch/disconnect Bluetooth output; crash recovery and retry. Default off. |
| tmux | Fake cancellation tests | Dedicated disposable panes, known empty input, gap recovery and no later input after stop. Targets default empty. |
| Battery/thermal | Injected decision/failure tests | Verify safe real callbacks and original preferences; no deliberate critical-heat stress. |
| UI/accessibility/login | Source hooks and model tests | Keyboard, Escape/outside click, multiple displays/Spaces, VoiceOver, reduced motion, login registration/revocation. |

An active personal installation is separate from the source release. Its old
100/0 battery settings require correction through the running app or after it
is safely closed; source tests do not update that live manager. The new source
loads invalid saved floors as 40/10 with a visible notice.

## Before tagging a stable release

- Integrate the reviewed branches and rerun full Swift/release/script checks.
- Review all outstanding Greptile comments on the final head, including findings
  addressed by dependent branches rather than the original PR.
- Complete the core real-device/clean-account rows. Optional unverified features
  stay disabled and documented; do not advertise measured benefits without data.
- Test the exact source-build installer and uninstaller on a clean supported Mac.
- Recheck docs, metadata, MIT notice and the working private security-report route.
- Choose the release tag and notes. A stable tag or public binary is not created
  by this implementation task.

For a later binary release, add Developer ID signing, Hardened Runtime,
notarization/stapling and quarantine/Gatekeeper testing of the exact artifact.
See [Apple’s distribution documentation](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
