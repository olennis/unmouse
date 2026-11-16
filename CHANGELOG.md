# Changelog

## Unreleased

- New global shortcut ``⌥` `` (changeable in Settings with `⌘S`) opens the window switcher on the next display, or moves it to the next display when it is already open.
- With multiple displays, the window switcher shows only the windows on the display you are working on. Press `` ` `` (or `` ⇧` ``) while it is open to move to the next (or previous) display.
- Fixed a crash when turning the menu bar icon on or off in Settings, which quit Unmouse and stopped its shortcuts (such as ⌥Tab) from working.
- Settings → General has a “Show icon in menu bar” option. When the icon is hidden, Unmouse keeps running and its shortcuts still work; launch Unmouse again from Spotlight to open Settings.
- Unmouse now follows macOS language preferences, with English and Korean interfaces and English as the fallback. Per-app language settings take effect after relaunch.
- Menus, status messages, settings, tooltips, and accessibility text use the selected language.
- Built apps keep their translations when moved or installed on another Mac.
- The README is available in English and explains language selection.
