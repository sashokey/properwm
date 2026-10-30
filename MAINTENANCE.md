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
