# Your data on this Mac

See what Wherever stores on your Mac, what **Clear Open History…** and **Reset** remove, and how to delete everything.

## What Wherever stores

Wherever keeps its files in `~/Library/Application Support/com.writronic.wherever/`.

| File | What it holds |
|---|---|
| `wherever.index` | The names, folders, sizes, dates and kinds of the files on your startup disk. It holds no file contents. |
| `volume-<id>.index` | The same list for one other disk, one file per disk you switch on. |
| `wherever.opens` | The full path of each file you open, one line per path, with a score and the time of the last open. The score halves every 14 days, and the file keeps at most 4096 paths. |

Time Machine skips the data folder, so your backups hold no index and no open history. Wherever can rebuild the indexes. It deletes the saved index of a disk you switched off once that file has gone 30 days without a change. A disk you switched on keeps its file.

Two more files live outside the data folder, in `com.writronic.wherever` inside your per-user cache folder. macOS supplies this private folder through `confstr(_CS_DARWIN_USER_CACHE_DIR)`, usually under `/var/folders/…/C/`. Wherever sets its subfolder to mode 0700.

- `wherever.sock` is the socket the `wherever` command connects to. Its mode is 0600, so only your user account can open it. The socket exists only while the command-line tool is on. After Wherever quits, nothing answers on it, and the next `wherever` command starts Wherever again in the background.
- `helper.lock` is an empty file the menu bar helper keeps, so that only one copy of the helper runs.

Wherever copies archive items you preview, open or drag out to `~/Library/Caches/com.writronic.wherever/Archives/`. It deletes the preview copies when the archive's window closes, and the rest when Wherever next starts.

Your settings live in the `com.writronic.wherever` preferences domain:

- **Appearance**, **Color theme**, **Text size**, the launcher's background opacity and **Language**
- Simple or Normal mode, **Show inspector**, **Hide invisible files**, result columns and **Keep Folders on Top**
- the launcher shortcut
- **Excluded Paths**, the disks you switched on and your answer for a new disk
- **Typo-Tolerant Search**, **Automatically check for updates** and whether the command-line tool is on
- **Show Menu Bar Icon** and the live updates pause
- whether you finished the welcome

macOS adds window positions to the same domain. Sparkle, the update library, adds the time of its last check.

The menu bar helper keeps an ID that tells which copy of the helper runs, the time it last woke Wherever, and whether the launcher shortcut failed to register. They live in the `com.writronic.wherever.helper` preferences domain, and macOS adds the menu bar icon's position there.

Wherever writes status and error lines to the macOS log on this Mac. They never leave it.

Wherever reads a file's contents in three cases:

- **Search Content**, only while you press it
- A Quick Look preview, from Space, the inspector or the launcher
- Opening an archive

It writes no copy of the words of any file anywhere.

If you install the [command-line tool](command-line.md), `~/.local/bin/wherever` is a link to the command inside Wherever.app. `~/.zshenv` then holds three lines between `# >>> wherever >>>` and `# <<< wherever <<<` that add `~/.local/bin` to `PATH`. **Uninstall** in **Settings…** > **General** removes both.

macOS keeps two records of its own:

- System Settings > General > Login Items (Login Items & Extensions on macOS 15 and later) lists Wherever after you turn on **Open at Login**, sometimes under the developer's name.
- Notifications lists Wherever once it has asked. It asks only while **Ask with a Notification** is your answer to **When a disk that isn’t indexed is connected**.

None of this leaves your Mac. Wherever goes online only to look for an update: when you choose **Check for Updates…**, and about once a day while **Automatically check for updates** is on. [PRIVACY.md](../PRIVACY.md) lists what that request carries.

## Clear the open history

1. Choose **Settings…** > **General**.
2. Click **Clear Open History…**, then **Clear**.

Wherever deletes `wherever.opens`, and results stop ranking the files you opened. The indexes and your settings stay.

## Move or reset your settings

**Export…**, on the **Export Settings** card in **Settings…** > **General**, writes your settings and your Excluded Paths to a file you choose. The file leaves out the index, the open history, window positions, the welcome state, the **Open at Login** choice, the command-line tool choice and the live updates pause. [Settings](settings.md#import-and-export) lists every value it holds.

**Import…**, on the **Import Settings** card, replaces your current settings with the file's, then quits and reopens Wherever.

**Reset**, in the **Reset Settings** group, deletes all settings, saved indexes and open history. It turns off **Open at Login** and the command-line tool, and removes the `~/.local/bin/wherever` link and the `PATH` lines in `~/.zshenv`. Then it quits and reopens Wherever. You can't undo it.

After a reset, **Language** returns to **System Default**. The welcome window returns, because Wherever no longer knows you finished it, and the next start scans your startup disk again. Reset leaves the Full Disk Access entry, the notification permission and any settings file you exported.

## Remove everything

1. Choose **Settings…** > **General**, turn off **Open at Login**, and click **Uninstall** under **Command-Line Tool** if it shows. Deleting the app removes neither the `~/.local/bin/wherever` link nor the `PATH` lines in `~/.zshenv`, and Homebrew's `--zap` cannot remove the lines.
2. Right-click the menu bar icon and choose **Quit Wherever**. This also ends the helper. With **Show Menu Bar Icon** off, turn it on in **Settings…** > **General** first, because the menu lives on the icon.
3. Delete the app. Without Homebrew, drag Wherever from Applications to the Trash. With Homebrew, run `brew uninstall --cask --zap wherever`. It also removes the link and the first five items in step 4.
4. Delete these. After `--zap`, only the last one is left:
   - `~/Library/Application Support/com.writronic.wherever`
   - `~/Library/Preferences/com.writronic.wherever.plist`
   - `~/Library/Preferences/com.writronic.wherever.helper.plist`
   - `~/Library/Caches/com.writronic.wherever`
   - `~/Library/HTTPStorages/com.writronic.wherever`
   - `com.writronic.wherever` in the per-user cache folder, which holds the socket and `helper.lock`
5. In System Settings, remove Wherever from Privacy & Security > Full Disk Access, and from Notifications if it is listed.

## Related

- [Settings](settings.md)
- [Disks and excluded paths](disks-and-locations.md)
- [Troubleshooting and FAQ](troubleshooting.md)
- [Privacy policy](../PRIVACY.md)
