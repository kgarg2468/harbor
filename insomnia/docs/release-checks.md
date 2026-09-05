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

The integrated Insomnia source at `43b42c5` passed 332 Swift tests on macOS 26.2
and 56 isolated script tests. Release builds and ad-hoc bundle verification pass.
A redacted secret scan covered 195 commits with no findings. Final-head CI and
Greptile results are tracked in the integration PR before merge.
Script tests use real temporary files/locks and command shims, with no live sudo,
pmset, app termination or launchd mutation. Passing fakes do not prove macOS
permissions or hardware behavior.

Review is split into focused pull requests; the final integration must include
all dependency branches. Greptile findings are checked against source and tests.
The historical handoff-before-nudge finding was rejected because it records an
already-observed recovery; the superseded-browser-scan finding was reproduced
and fixed. A successful reviewer check alone does not mean every comment has
been resolved. The shell power-edit warning and installer EXIT-trap warning
were also rejected after direct regressions confirmed nonzero failure and
parent-shell cleanup. Accepted findings received fixes and permanent tests.

## Original audit items

| Item | Result in the source preview |
| --- | --- |
| Hotspot never configured | Still opt-in; missing credentials are not a source defect. Added cancellation and WPA2/WPA3-only password association. Real Location/association checks remain open. |
| Floors 100/0 | Invalid saved pairs load as 40/10 with a notice; Settings rejects unsafe pairs and applies changes immediately. The active old installation is separate. |
| Preset chips deleted | Presets now appear in the menu for starting/extending sessions. |
| Obsolete popover docs | README/spec now describe the current panel, status menu and Settings; file layout refreshed. |
| Untested optional features | Browser/Docker default off, audio remains off, tmux targets empty. Hardware evidence is recorded below instead of assuming a pass. |
| Docker denylist | The explicit Docker rule bypass was reachable; the real defect was selecting an unintended daemon. It now targets the local Desktop socket explicitly. |
| Debug/deprecated UI calls | Removed launch frame logging and updated app activation. |
| Incorrect sleep status and races | Confirmed power state, serialized lifecycle operations, coordinated journals, cancellation and latest-scan checks. |
| Untracked mockup | Remains in the separate personal checkout; excluded from these release branches. |
| CI missing | The repository already had CI. Added the missing macOS Insomnia build/test/script/bundle checks. |
| Public distribution metadata | MIT already present; source version is 0.2.0, original icon included, build/install/security docs updated. |
| Privileged install/uninstall | Explicit four-command grant, account ownership checks, guarded staged replacement, native recovery and verified maintenance. Clean-account acceptance remains open. |

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

An active personal installation is separate from the source release. Its saved
100/0 battery settings were corrected to 40/10 after its session ended and
recovery state was clean; a private backup was retained. The old running GUI
requires a restart to load that edit. Source tests do not update its in-memory
settings. The new source loads invalid saved floors as 40/10 with a visible notice.

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
