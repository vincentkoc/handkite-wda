<!--
Copyright (c) 2026 Vincent Koc. BSD-3-Clause, see LICENSE in this directory.
-->

# Handkite fork of WebDriverAgent

This branch is a fork of [Appium WebDriverAgent](https://github.com/appium/appium-ios/tree/main/packages/webdriveragent),
which is itself derived from Facebook's WebDriverAgent. Handkite uses it as its
iOS XCTest runner.

- Upstream: `appium/appium-ios`, package `packages/webdriveragent`
- Base tag: `appium-webdriveragent@17.0.6`
- Branch: `handkite/appium-webdriveragent-17.0.6`

Everything outside `packages/webdriveragent` is upstream monorepo content and is
not modified.

## Patches

Each patch is one commit on top of the base tag, so it can be dropped,
reordered, or sent upstream on its own.

1. `fix(wda): report initial lock state and fail closed when unavailable`
   - `XCUIDevice+FBHelpers.m`: read the lock state as soon as the
     `com.apple.springboard.lockstate` notification is registered, guard the
     cached state with a mutex, and mark it invalid when registration or
     `notify_get_state` fails.
   - `XCUIDevice+FBHelpers.h`: add `fb_observedScreenLockState`, which returns
     `nil` when the state is unknown.
   - `FBCustomCommands.m`: `GET /wda/locked` returns an unknown error with the
     message `lock_state_unavailable` instead of reporting `false`.
2. `build(wda): rename runner product to HandkiteRunner`
   - iOS runner target only: `PRODUCT_NAME = HandkiteRunner` and the
     placeholder `HANDKITE_RUNNER_BUNDLE_ID = com.example.HandkiteRunner`.
     Only the runner target uses this setting for its product bundle identifier.
     Builders must override `HANDKITE_RUNNER_BUNDLE_ID` with an identifier they own.
     Do not override `PRODUCT_BUNDLE_IDENTIFIER` globally: that also renames the
     dependent WebDriverAgentLib framework.
   - The shared scheme `WebDriverAgentRunner` is renamed to `HandkiteRunner`.
   - Products: `HandkiteRunner.xctest` inside `HandkiteRunner-Runner.app`,
     whose bundle identifier is `<PRODUCT_BUNDLE_IDENTIFIER>.xctrunner`.
   - Target names, `FB*` classes, files, and the tvOS/watchOS runners are
     unchanged. The upstream Node tooling in `lib/` and `Scripts/` still
     expects `WebDriverAgentRunner` names for iOS and is not used by Handkite.
3. `docs: describe the Handkite fork` (this file).
4. `fix(wda): scope custom bundle identifiers to the runner` adds the
   dedicated override above; the library bundle identifier stays unchanged.

## Scoped membership producer (candidate)

`GET /session/:sessionId/appium/settings` advertises
`handkiteScopedSnapshotVersion: 1`. The read-only
`POST /session/:sessionId/wda/scopedSnapshot` route accepts a matching session,
app, display selection, predicate, 128-member limit, correlation nonce and
remaining deadline (at most 5 seconds). A caller may also require a particular
native recipient to remain hittable and focused. The nonce only correlates a
response; it is not a UI generation or authority renewal.

The normal WDA route queue serializes the request with input and settings
handlers. It does not freeze the application. The producer therefore uses two
fresh native snapshots: the first supplies complete cheap XML, unfiltered
predicate membership and bounded rich rows; the second re-enumerates the same
unfiltered native UID population after the screenshot and final recipient,
app/PID, lock and display checks. A changed, duplicate, incomplete or oversized
population refuses. Snapshot depth/child limits and unknown native visibility
also refuse. Both selected and effective display identities must agree.

Direct accessibility bindings and cache IDs are primed before the terminal
traversal. No snapshot or live attribute read follows it. The response includes
the source, rows, frame and both complete matching UID sets. No global response
profile is changed, so there is no settings-restoration interval or host-side
second membership request. An input caller must still retain its original
freshness/deadline checks and normal dispatch guards; this endpoint sends no
input. Refusals contain fixed reasons, never source text or element labels.

Application identity uses the native `bundleID` and positive process ID at the
initial and both terminal reads. XCTest's `identifier` is a display or
accessibility name and must never substitute for a bundle ID. The earlier
candidate compared it with the host's bundle ID, which could refuse before the
first membership snapshot. Foundation fixtures exercise the same production
identity helper with a display-identifier getter that throws, replacement
bundles and changed PIDs. This fixes the source contract; it does not recover
the unsaved native error from the previous live refusal or qualify latency.

This is an unqualified candidate. The local offline check is:

```sh
python3 packages/webdriveragent/Scripts/check-scoped-snapshot.py
```

It syntax-checks both modified Objective-C commands against the installed
simulator SDK and runs the actual Foundation-only traversal/terminal-order
helpers. It does not build a full runner, start XCTest or prove device latency.

## Syncing with upstream

```sh
git fetch upstream --tags
git rebase --onto 'appium-webdriveragent@<new-version>' \
  'appium-webdriveragent@17.0.6' handkite/appium-webdriveragent-17.0.6
git branch -m handkite/appium-webdriveragent-<new-version>
```

Then update the base tag above, rebuild, and re-run any lock state checks.
Conflicts are expected only in the files listed under Patches. `main` mirrors
upstream and is never modified.

## License

WebDriverAgent is licensed under the BSD 3-Clause license in
[`LICENSE`](LICENSE). The monorepo's `LICENSE` and `NOTICE.txt` at the
repository root are kept unchanged. Upstream copyright headers in modified
files are preserved as they are.

## Building

No signed runner is distributed. Build and sign your own runner with your own
Apple development team and a bundle identifier you control, for example:

```sh
xcodebuild build-for-testing \
  -project packages/webdriveragent/WebDriverAgent.xcodeproj \
  -scheme HandkiteRunner \
  -destination generic/platform=iOS \
  DEVELOPMENT_TEAM=<team> CODE_SIGN_STYLE=Automatic \
  HANDKITE_RUNNER_BUNDLE_ID=<your.bundle.id>
```
