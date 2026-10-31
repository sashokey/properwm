# ProperWM

ProperWM is a lightweight window manager for macOS, focused on open windows without unnecessary extras.

It brings your open windows together in a compact taskbar, making it easier to keep track of your work and move between tasks. It is designed for everyday multitasking, helping you find the window you need when several applications or displays are in use.

Requires macOS 26 or later. Supports Apple Silicon Macs.

## Installation

Download the app ZIP from [Releases](https://github.com/sashokey/properwm/releases), move `ProperWM.app` to `/Applications`, and open it. Grant **Accessibility** permission when prompted so the app can manage windows.

The app is currently ad-hoc signed and not notarized. macOS may require **Privacy & Security → Open Anyway** on first launch.

## Usage notes

- **Restore a hidden menu bar icon:** open ProperWM again from **Applications** while it is already running. Hiding the icon is remembered across app and Mac restarts; reopening the running app makes it visible again.
- **Access the menu without the icon:** right-click an empty area of the taskbar to open ProperWM's menu, including **Quit**.
- **Bring a window forward while dragging a file:** pause over its taskbar button without releasing the file. A minimized window will be restored. For a combined group, pause over the button, then over the desired window in the list. Finish by dropping the file into the application's window.
- **Reorder application groups:** dragging a window button moves all taskbar buttons for that app together. Windows within a group keep their order. Press **Esc**, or release outside the taskbar, to cancel the move.

## License

Licensed under [GPL-3.0-or-later](LICENSE). Required legal notices are in [NOTICE](NOTICE).
