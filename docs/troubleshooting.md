# Troubleshooting and FAQ

Find a message Wherever shows, learn what caused it and fix it.

## What does this message mean?

| Message | Why | What to do |
|---|---|---|
| `Wherever could not build the index. Choose Quit Wherever from the Wherever menu, then open Wherever again.` | The index failed. Nothing more happens until the next launch. | Do as the message says. If it repeats, read [the log](#how-do-i-see-the-log). |
| `Search failed. Try again.` | A search call failed. | Type again. The line clears when a search answers. |
| `Could not read Disk 1`, `Live updates are off for Disk 1` | A disk would not open, or Wherever cannot watch it. | See [Live updates](disks-and-locations.md#live-updates). |
| `Disk 1 is not indexed`, `2 disks are not indexed` | A plugged-in disk is on the ignored list. | Click **Index** or **Manage…**, as [Disks and excluded paths](disks-and-locations.md) describes. |
| A line in the welcome window | The grant is off or the check failed. | See [If the welcome gets stuck](getting-started.md#if-the-welcome-gets-stuck). |
| `Wherever could not change this. Check Login Items in System Settings.` | macOS refused to add or remove the login item. | Click **Open Login Items** to open System Settings > General > Login Items (Login Items & Extensions on macOS 15 and later), and switch Wherever by hand. The entry may be listed under the developer's name. |
| `Allow Wherever in Login Items in System Settings.` | macOS waits for your approval. | Click **Open Login Items**, as in the row above, and allow Wherever. |
| `Wherever could not clear the open history.` | Wherever could not delete the history file. | Click **Clear Open History…** again. |
| `Wherever could not reset. Try again.` | The helper that reopens Wherever did not start, so nothing changed. | Click **Reset** again. |
| `Wherever could not export the settings.` | Wherever could not write the file. | Choose another folder. |
| `Wherever could not read this settings file.` | The file is not a settings file, is over 1,000,000 bytes or holds a bad value. | Export a fresh file from a working copy. |
| `This file is from a newer version of Wherever. Update Wherever, then try again.` | A newer Wherever wrote the file. | Install the newer version, then import again. |
| `Wherever could not reopen. The settings are saved and take effect when you quit and reopen Wherever.` | The import saved, but the restart failed. | Quit and reopen Wherever. |
| `Wherever could not change the locations. Try again.` | The disk or path change failed. | Try again. |
| `This path isn’t valid` | An **Excluded Paths** row is not an absolute path. | Remove the row. |
| `The disk isn’t connected` | An **Excluded Paths** row lies on a disk that is not mounted. | Reconnect the disk or remove the row. |
| `Notifications for Wherever are turned off. Allow them in System Settings > Notifications.` | You chose **Ask with a Notification**, but macOS blocks notifications. The status bar asks instead. | Allow notifications, or choose another answer. |
| A shortcut refusal | The keys clash or lack a modifier. | See [Change or remove the shortcut](launcher.md#change-or-remove-the-shortcut). |
| `Wherever could not install the command-line tool.`, `Another program already uses ~/.local/bin/wherever. Remove it, then try again.`, `Move Wherever to the Applications folder, then try again.` | The `wherever` command could not be installed. | See [Install the command](command-line.md#install-the-command). |

## Why does the menu bar icon stay after ⌘Q?

A small helper keeps the icon and the launcher shortcut, so they stay after you quit Wherever. To end the helper too, right-click the menu bar icon and choose **Quit Wherever**.

## Why is Wherever still running with no window?

Wherever may be scanning your disks or re-reading its index when the launcher or the last window closes. It finishes that work first, then quits by itself.

To stop it at once, right-click the menu bar icon and choose **Quit Wherever**. This also removes the icon and the shortcut until you open Wherever again. A first scan then starts over at the next launch. With the icon off, open Wherever from Finder and turn on **Show Menu Bar Icon** in **Settings…** > **General** first.

A quit also saves the index when the saved copy is more than 12 hours old or more than 50,000 changes behind. The next start then has less to catch up on, but that quit can take a few seconds longer.

## Why is a file missing from the results?

Check these in order:

1. The status bar reads `Indexing the disk`. Results appear during the scan, and files it has not reached are missing.
2. The file sits under a path in **Settings…** > **Locations** > **Excluded Paths**. Nine rows are there at first, among them `~/Library/Caches` and `/private/var`.
3. **Hide Invisible Files** is on and the file is hidden.
4. Full Disk Access is off. Until you grant it, only the welcome window opens.
5. The status bar reads `Live updates paused`. New and renamed files stay out of the results until you click it or choose **View** > **Resume Live Updates**.

## Why does the wherever command fail?

The `wherever` command prints one line that starts with `wherever: ` and exits with status 2. [The command-line tool](command-line.md#exit-status-and-messages) lists every message. Three are common:

- `cannot reach Wherever. Open Wherever, and install the command-line tool in Settings > General if it is off.` Open Wherever and finish the welcome. Under **Settings…** > **General** > **Command-Line Tool**, the button should read **Uninstall**.
- `Wherever is still indexing this Mac, N items so far. Try again in a moment.` The first scan of the startup disk is running. Wait until the status bar reads `Live updates on` or `Live updates paused`.
- `run wherever as yourself, not as root.` Run it without `sudo`.

If Terminal says `command not found: wherever`:

1. Check the **Command-Line Tool** row in Settings, and click **Install** if the link is missing.
2. Open a new Terminal window. A window that was open before the install keeps its old `PATH`.

Install adds `~/.local/bin` to `PATH` in `~/.zshenv`, which only zsh reads. In bash or fish, add it yourself. In Shortcuts, Automator, launchd or cron, call `$HOME/.local/bin/wherever` by its full path.

## Why is my external disk not in the results?

Wherever indexes the startup disk only. Another local disk waits on the ignored list until you switch it on, as [Disks and excluded paths](disks-and-locations.md) describes. Network drives are not indexed or listed.

## Why does Search Content skip files?

The status bar counts `N files skipped`, and its tooltip names two causes:

- `N files not downloaded` are iCloud placeholders. Wherever never downloads them.
- `N files in unsupported formats` are Pages, Numbers, Keynote and epub files.

Download the placeholders in Finder, then click **Search Content** again.

## Why is my PDF text not found?

Search Content reads a PDF's text layer, and a scanned PDF has none. The PDF reader also drops Chinese and Japanese text, and it can garble some PDFs made with Adobe tools. Simple mode searches names only, so switch to **Normal** for [Search Content](normal-mode.md#search-inside-files).

## Why does Wherever not update itself?

A fresh install checks only when you ask. Choose **Check for Updates…** from the app menu.

To check on its own, open **Settings…** > **General** > **Software Updates** and turn on **Automatically check for updates**. Wherever then checks about once a day. Nothing installs until you say so.

## Where is the menu bar icon?

Open **Settings…** > **General** > **Menu Bar** and turn on **Show Menu Bar Icon**. A Command-drag out of the menu bar turns the icon off, and it stays off.

If the switch is on and you still see no icon, macOS may be hiding it. macOS 26 and later can hide menu bar items: open System Settings, choose Menu Bar and turn on Wherever Helper under Allow in the Menu Bar.

With the icon off and no window open, Wherever has no Dock icon and no menu. Open Wherever again from Finder, and a window opens with its Dock icon and menus.

## How do I see the log?

Wherever writes to the unified log under its bundle identifier. In Terminal:

```sh
log show --last 10m --predicate 'subsystem == "com.writronic.wherever"'
```

Some entries hide their detail as `<private>`.

## Related

- [Getting started](getting-started.md)
- [Disks and excluded paths](disks-and-locations.md)
- [Normal mode](normal-mode.md)
- [The launcher](launcher.md)
- [The command-line tool](command-line.md)
- [Settings](settings.md)
- [Your data on this Mac](privacy-and-data.md)
