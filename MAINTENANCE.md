# Maintenance

The imported baseline is source version 0.18.4, commit `825924c8019945bb0b620702f8a274a249e9c8f6`. ProperWM's independent root snapshot is `3dab8e2b88687ce7d758a221f51f69a268bc2f40`.

The original source remains in repository history. Removed features can be restored from that snapshot, including their models, services, views, resources, project references, and tests. Restoration requires an explicit scope decision; copying a view alone may omit dependencies or bring back unwanted behavior.

For future source-project fixes:

1. Compare with the recorded baseline and identify the bug and affected retained subsystem.
2. Transfer the smallest applicable fix and its regression test.
3. Adapt it to ProperWM's window-only model and fixed behavior.
4. Check for reintroduced launchers, file operations, Dock writes, settings, author services, and product branding.
5. Run CI and relevant Mac acceptance scenarios.
6. Record the source commit, rationale, adaptations, and verification in the ProperWM commit message.

Track source changes manually when requested; there is no automatic merge or background update service. GitHub's standard Source code archives for each release tag and this repository history provide the corresponding source for distributed binaries.

Keep commits focused and explain what changed, why it was needed, what behavior was preserved, and how it was verified. Code changes follow SOLID, KISS, and DRY.

## Platform and toolchain policy

The deployment minimum is macOS 26 on Apple Silicon. Keep its compatibility without adding a dedicated macOS 26 test matrix or special behavior. Tests run on the newest hosted macOS family available in GitHub Actions, currently `xcode-27`; its patch version follows GitHub's image updates. A newer Apple release can precede availability in hosted runners. Move the label forward when GitHub provides a newer family.

Select the newest installed stable Xcode, resolving application symlinks before excluding beta and release-candidate bundles. Compile all targets in Swift 6 language mode. Node.js and Python are resolved to the newest stable releases for each CI run; their actual versions, Xcode, Swift, and macOS are recorded in the build log.

Official GitHub Actions are pinned to full release commit SHAs. Dependabot checks them daily and opens update pull requests; merge those updates after CI passes. Keep the source, release workflow, and packaging free of third-party runtime packages. The system frameworks are supplied by macOS and the selected Xcode SDK.

## Artifact storage

Build and test artifacts expire after seven days. Artifact maintenance runs after CI or Release completes and when its policy changes. It tests the deletion policy before using Actions write permission.

For each managed name (`ProperWM`, `test-results`, and legacy `xcodebuild-test-log`), keep the three newest completed artifacts and the newest successful result. Also keep artifacts from active runs, the triggering run, unknown runs, and unrelated artifact names. The maintenance workflow reads trusted `master` code and does not run for fork or pull-request completion events.

Only GitHub Actions artifacts are deleted. Published release assets, tags, source, workflow runs, and their logs are not deletion targets.
