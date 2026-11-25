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

5. `perf(wda): prefetch native visibility for rich inventories` requests native
   visibility once per rich multi-element response. Unique matching snapshot IDs
   supply values only at the existing getter's direct-fetch step; cached values,
   descendant checks and per-element fallback retain precedence. Prefetched
   values are cleared after serialization, including exceptions. No depth,
   timeout or cross-request cache setting is changed.

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
