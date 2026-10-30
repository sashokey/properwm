# ProperWM

A macOS taskbar for open windows. Requires macOS 12 or newer; universal builds support Apple Silicon and Intel.

- Switch to, restore, minimize, and close windows.
- Reorder window buttons by dragging them.
- Show a separate taskbar on each display, with that display's windows.
- Show application names on hover.
- Keep maximized windows above the taskbar.
- Predict fullscreen transitions to prevent taskbar flicker.

The taskbar uses the fixed **Always** mode, while retaining fullscreen hiding.
Its menu contains only **Open at Login** and **Taskbar Size**. Accessibility permission is requested when needed. The app follows the system appearance.

## Builds and releases

Builds run exclusively in GitHub Actions. **CI** runs the tests with coverage, checks localization and deployment compatibility, and packages a universal Release app. A successful run provides the **ProperWM** artifact containing the app ZIP, matching source ZIP, and SHA-256 checksums. Test logs, coverage, and the result bundle are in **test-results**.

For a release, open **Actions → Release → Run workflow**, enter a new version in `X.Y.Z` form, and choose **Mark as a pre-release** and **Keep as a draft**. The workflow tests and rebuilds that exact commit before creating `vX.Y.Z` and uploading the verified packages. Existing version tags are never replaced. Clear **Keep as a draft** to publish after all steps succeed.

Packages are ad-hoc signed and are not notarized. No paid signing account or external publishing service is required. Install `ProperWM.app` in `/Applications` before granting Accessibility permission or enabling **Open at Login**. macOS may require **Privacy & Security → Open Anyway** on first launch.

There are no third-party runtime packages. CI uses the newest installed Xcode 26 and pins official GitHub Actions to reviewed release commits.

## Verification and maintenance

[TESTING.md](TESTING.md) describes automated coverage and the Mac acceptance checks. [MAINTENANCE.md](MAINTENANCE.md) records the source baseline and how to restore removed code or transfer future fixes without reintroducing features.

## License

GPL-3.0-or-later. Required copyright, modification, and trademark notices are in [NOTICE](NOTICE); the complete license is in [LICENSE](LICENSE).
