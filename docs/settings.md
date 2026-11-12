# Settings

Choose how Wherever starts and looks, which paths it skips, and how to back up or reset its settings.

Choose **Settings…** (⌘,) in the Wherever menu or in the menu bar icon's right-click menu. The window has **General**, **Locations** and **About** in a sidebar, and ⎋ closes it. Until you grant Full Disk Access, **Settings…** shows the welcome window instead.

## General

### Startup

**Open at Login** starts the menu bar icon and the launcher shortcut when you log in. Wherever itself stays closed. Its caption reads `Starts the menu bar icon and the launcher shortcut when you log in, as you set them below.` After login, Wherever opens the first time you press the shortcut or click the icon, and that first press waits while it loads. With the icon off and no shortcut set, nothing runs.

If macOS needs your approval, the pane says `Allow Wherever in Login Items in System Settings.` If the change fails, it says `Wherever could not change this. Check Login Items in System Settings.` Either way, **Open Login Items** opens Login Items in System Settings > General (Login Items & Extensions on macOS 15 and later). Wherever may be listed there under the developer's name.

⌘Q, **Quit** in the Dock icon's menu and closing the last window all quit Wherever. A small helper app, Wherever Helper, keeps the menu bar icon and the launcher shortcut running.

### Menu Bar

**Show Menu Bar Icon** is on by default. Its caption reads `Shows a Wherever icon in the menu bar. Click it to open the launcher, or right-click it for a menu. If it does not appear, open System Settings and look in the Menu Bar section.` On macOS 26 and later, that section lists Wherever Helper under Allow in the Menu Bar.

Until Wherever has Full Disk Access, a click on the icon opens the welcome window instead of the launcher. A right-click or a Control-click shows a menu: **Live Updates**, checked while live updates are on, then **Open Wherever**, **Settings…**, **Keyboard Shortcuts** and **Quit Wherever**.

If you Command-drag the icon out of the menu bar, this switch turns off and stays off until you turn it on again. With the icon off, open Wherever from Finder to reach the switch. See [Where is the menu bar icon?](troubleshooting.md#where-is-the-menu-bar-icon).

### Shortcut

The button beside **Launcher shortcut** shows the key that opens the launcher, ⌃⇧F at first. Its caption reads `Press it in any app to search your files.` Click the button, then press new keys. ⎋ cancels and Delete removes the shortcut. With no shortcut, the button reads **Record Shortcut**. [The launcher](launcher.md) lists the keys it refuses, ⌘S and ⇧⌘S among them.

### Command-Line Tool

**Install** puts the `wherever` command in `~/.local/bin` and adds that folder to `PATH` in `~/.zshenv`, so you can search from Terminal. It asks for no password. The caption reads `Search from the command line with the wherever command.` until you install it. [The command-line tool](command-line.md) covers the button, its captions and every message.

### Search

**Typo-Tolerant Search** is off by default. Its help line reads `When no name holds your letters side by side, also shows close matches, such as names with a typo.` When on, it works in Simple mode, in Normal mode's **Contains** and in the launcher. Open windows follow at once. See [Searching](searching.md).

### Appearance

**Appearance** offers **System**, **Light** and **Dark**. **System** follows macOS and is the default.

**Color theme** shows four tiles: **System Native**, **Ink and Glass**, **Warm Paper** and **Midnight Teal**. **System Native** is the default. Click a tile or its name to pick it. A theme changes colors only. Every window follows a new appearance or theme at once.

**Text size** sets the size of the text in Wherever's windows, from 11 to 18 points. It starts at 13. Menus and alerts keep the size macOS uses.

**Wherever search background opacity** sets how much of the launcher's background covers what lies behind it, from 0% to 100%. It starts at 30%. With Reduce transparency on in System Settings > Accessibility, the slider is disabled and the caption reads `Wherever search stays solid while Reduce transparency is on in System Settings > Accessibility.`

**Show inspector** turns the inspector on or off, like **View** > **Show Inspector** (⌥⌘I). It starts off. See [Results](results.md).

### Language

**Language** offers **System Default** and the 11 languages Wherever speaks, each in its own script: English, Türkçe, Deutsch, Français, Español, Русский, Nederlands, 日本語, 简体中文, العربية and Polski. **System Default** follows the language order in macOS.

A new language takes effect when Wherever reopens. Wherever asks `Restart Wherever?`. **Restart Now** quits and reopens it. **Later** keeps the caption `The language change will take effect after restarting Wherever.` until you quit. If Wherever cannot reopen, it says `Wherever could not reopen. The settings are saved and take effect when you quit and reopen Wherever.`

### Open History

The row reads `Files you open often rank higher in results.` Wherever keeps that history on this Mac. **Clear Open History…** asks `Clear open history?`, and **Clear** forgets which files you opened. If that fails, the pane says `Wherever could not clear the open history.`

### Software Updates

The group holds one switch, **Automatically check for updates**, off by default. While it is on, Wherever checks about once a day and asks before it installs anything. The check also runs while Wherever is closed, as long as the menu bar icon or the launcher shortcut is on and you did not choose **Quit Wherever** in the icon's menu. Wherever then starts without a window, checks, and quits by itself unless an update is waiting for you.

To check now, choose **Check for Updates…** in the Wherever menu. While the switch is off, that is the only way Wherever checks.

### Import and Export

The group has two cards: **Import Settings**, then **Export Settings**.

**Export…** saves your settings as a JSON file, `Wherever Settings.json` unless you rename it. The file holds:

- **Appearance**, **Color theme**, **Text size**, the launcher's background opacity and **Language**
- Simple or Normal mode, **Show inspector**, **Hide invisible files**, the result columns and **Keep Folders on Top**
- **Show Menu Bar Icon**
- the keyboard shortcut
- **Excluded Paths**, the disks you indexed and the answer for new disks
- **Typo-Tolerant Search** and **Automatically check for updates**

It leaves out the index, the open history, window positions, the welcome state, the **Open at Login** choice, the command-line tool choice and the live updates pause. If the save fails, the pane says `Wherever could not export the settings.`

**Import…** reads a file that **Export…** wrote. Wherever checks every value first and writes nothing if one is wrong. Then it asks `Import settings?` with the line `Wherever replaces your current settings with the ones in the file, then quits and reopens.` **Import** writes the file's values, then quits and reopens. A setting the file leaves out keeps its current value.

- A file from a newer Wherever shows `This file is from a newer version of Wherever. Update Wherever, then try again.`
- A file Wherever can't use shows `Wherever could not read this settings file.`
- If Wherever cannot reopen, it says `Wherever could not reopen. The settings are saved and take effect when you quit and reopen Wherever.`

### Reset Settings

The **Reset Settings** group holds one row, `Reset all settings, saved indexes and open history (cannot be undone)`, with a red **Reset** button at its end. It asks `Reset All Settings?`. On **Reset**, Wherever deletes your settings, saved indexes and open history and turns off **Open at Login**. It also removes the command-line tool: the `~/.local/bin/wherever` link and the `PATH` lines it added to `~/.zshenv`. Then it quits and reopens, and **Language** is back to **System Default**. You can't undo a reset, so export first. If the reset fails, the pane says `Wherever could not reset. Try again.`

Reset leaves Full Disk Access, the notification permission and exported files alone. [Your data on this Mac](privacy-and-data.md) lists what Wherever stores.

## Locations

The pane holds the menu **When a disk that isn’t indexed is connected** and the **Excluded Paths** list. The menu offers **Ask in the Status Bar** (the default), **Ask with a Notification**, **Index Automatically** and **Do Nothing**. The list holds every path Wherever skips, and the disks it does not index.

- **Add excluded path**, the plus button, opens a folder panel.
- **Remove excluded path**, the minus button, removes the selected row. Removing a disk's row indexes that disk.

[Disks and excluded paths](disks-and-locations.md) explains each answer, the nine rows the list starts with, the notes a row can show and every message the pane shows.

## About

**About** shows the version, the motto `Wherever it is, find it.`, **Made with ❤️**, a **Visit Website** button, which opens `https://writronic.com`, and a **Donate** button, which opens `https://writronic.com/donate`. **About Wherever** in the Wherever menu shows the same in its own window, even before you grant Full Disk Access.

## Related

- [Getting started](getting-started.md)
- [Disks and excluded paths](disks-and-locations.md)
- [Keyboard shortcuts](keyboard-shortcuts.md)
- [The command-line tool](command-line.md)
- [Your data on this Mac](privacy-and-data.md)
- [Troubleshooting and FAQ](troubleshooting.md)
