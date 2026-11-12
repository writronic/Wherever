# Getting started

Install Wherever, turn on Full Disk Access and run your first search.

## Install Wherever

Download the DMG from the [latest release](https://github.com/writronic/Wherever/releases/latest), open it and drag Wherever to Applications. Or use [Homebrew](https://brew.sh):

```sh
brew install --cask writronic/tap/wherever
```

Wherever needs macOS 13 Ventura or later.

## Turn on Full Disk Access

Wherever lists a protected folder only if macOS lets it read that folder. Until you grant Full Disk Access, the first launch opens only the welcome window. The search window and the engine do not start.

1. Click **Open System Settings**. It opens Privacy & Security, Full Disk Access.
2. Turn on Wherever. macOS asks for an administrator's name and password. On a Mac your organization issued, ask your administrator.
3. Switch back to Wherever. It checks every two seconds. When it sees the grant, the line under the button turns green and reads `Full Disk Access is on. Wherever is ready to start.` The button now reads **Next**.
4. Click **Next**. Three more pages follow.

The window keeps one size, and **Back** and **Next** stay in the same place on every page. At the top, `Step 2 of 4` sits over four dots that show where you are. Click a dot to return to a page you have seen, or to go on to the next page. Return presses **Next**, or **Let's Go!** on the last page.

| Page | What you choose |
|---|---|
| **Choose Your Mode** | **Simple** or **Normal**. Click anywhere on a card. You can change it later in the View menu. In the **Command-Line Tool** box, **Install** adds the `wherever` command for Terminal. It asks for no password. See [The command-line tool](command-line.md). |
| **Set Up Wherever** | **Launcher shortcut** on or off, **Show Menu Bar Icon** on or off, and a **Color theme**. You can change these later in Settings. |
| **You’re All Set** | A green check under the logo says the setup is done. Click **Let's Go!** |

Wherever starts indexing as soon as it has Full Disk Access. Only **Let's Go!** saves your choices and opens the search window. **Install** is the one button that acts at once. The welcome never closes by itself. If you close it before **Let's Go!**, the next launch starts again at the first page.

After the grant, Wherever checks Full Disk Access every 30 seconds and each time you switch back to it. If the access goes off before **Let's Go!**, the welcome returns to the first page and reads `Full Disk Access is still off. In System Settings > Privacy & Security > Full Disk Access, turn on this copy of Wherever.` If it goes off while you search, Wherever asks you to save any edited archive. Then it quits and reopens on the welcome.

After **Let's Go!**, the four pages do not show again. A later welcome shows the first page alone, with no steps, dots or **Back**. When it sees the grant, the button reads **Let's Go!**. Click it to open the search window. Your mode, theme, launcher and menu bar icon stay as you set them.

## If the welcome gets stuck

| Line | Why | What to do |
|---|---|---|
| `Under Privacy & Security, Full Disk Access, turn on Wherever.` | The grant is off. | Click **Open System Settings** and turn Wherever on. |
| `Full Disk Access is still off. In System Settings > Privacy & Security > Full Disk Access, turn on this copy of Wherever.` | The check still says no. | Turn on the entry for the Wherever you opened. |
| `Wherever could not check Full Disk Access. It will try again. If this continues, quit and reopen Wherever.` | The check failed. | Wait for the retry. |
| `System Settings could not open. Open it from the Apple menu, then choose Privacy & Security > Full Disk Access.` | The pane did not open. | Open System Settings from the Apple menu, choose Privacy & Security > Full Disk Access, and turn on Wherever. |
| `Quit and reopen Wherever so it can search every folder.` | This running copy cannot use the grant yet. | Click **Quit Wherever**, then reopen Wherever. |
| `Wherever could not start its search. Quit and reopen Wherever, then try again.` | The engine did not start. | Click **Quit Wherever**, then reopen Wherever. |

## Run your first search

Type in the `Search files` field. Results change as you type. With the field empty, Wherever lists every indexed file from A to Z.

On the first launch Wherever scans your startup disk, and the status bar reads `Indexing the disk`. Results appear during the scan, so an early search can miss files the scan has not reached yet. When the status bar reads `Live updates on`, the index is complete and stays current. Only the startup disk is indexed at first. [Disks and excluded paths](disks-and-locations.md) covers other disks.

| Keys | Action |
|---|---|
| ↑ ↓ | Move through the results |
| ↩ | Open the selected file |
| ⌘↩ | Show the selected file in Finder |
| Space | Show or close Quick Look |
| ⌘C | Copy the path of the selected file |
| ⎋ | Clear the search text, then the filters |

[Keyboard shortcuts](keyboard-shortcuts.md) lists every key. For operators such as `ext:` and `size:`, see [Search syntax](search-syntax.md). For the form with filter pills and **Search Content**, choose **View** > **Normal**. **View** > **Simple** takes you back.

## Close the window

Closing the last window quits Wherever. So does closing the [launcher](launcher.md) when no window is open. The menu bar icon stays while **Show Menu Bar Icon** is on, and ⌃⇧F still opens the launcher, a small panel that searches file names. The first press after a quit waits while Wherever loads. To bring a window back, right-click the menu bar icon and choose **Open Wherever**, or open Wherever from Finder.

⌘Q quits Wherever too. The menu bar icon and the launcher shortcut stay. Live updates pause while Wherever is closed and catch up when it opens. **Quit Wherever** in the menu bar icon's menu also ends the icon and the shortcut, until Wherever opens again.

## Related

- [Search syntax](search-syntax.md)
- [Normal mode](normal-mode.md)
- [Disks and excluded paths](disks-and-locations.md)
- [The launcher](launcher.md)
- [The command-line tool](command-line.md)
- [Settings](settings.md)
- [Keyboard shortcuts](keyboard-shortcuts.md)
- [Troubleshooting and FAQ](troubleshooting.md)
