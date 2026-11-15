# Disks and excluded paths

Choose which disks Wherever indexes and which paths it leaves out.

## What Wherever indexes at first

Wherever indexes your startup disk. Other local disks, such as a USB or Thunderbolt drive, start in the **Excluded Paths** list and stay out of the results until you switch them on. Network drives are not indexed or listed. Mounted disk images, such as an open `.dmg`, are not indexed or listed either. To search inside one, type its folder in the **Search folder** box or browse to it.

## Index another disk

You can start indexing a disk in four ways:

1. In **Settings…** > **Locations**, select the disk's row in **Excluded Paths** and click **Remove excluded path** (the minus button).
2. In [Normal mode](normal-mode.md), open the **Search folder** menu. A disk that is not indexed reads `Disk 1 (Not indexed)`. Pick it, and Wherever asks `Index “Disk 1”?`. Either answer, **Index** or **Cancel**, makes the disk your Search folder.
3. In the status bar, click **Index** at the end of `Disk 1 is not indexed`. It asks the same question. Two or more waiting disks share one line, such as `2 disks are not indexed`, and its **Manage…** button opens **Settings…** > **Locations**.
4. In a notification, click **Index**. This needs the **Ask with a Notification** answer below.

Indexing reads every file name on the disk, and a large disk can take several minutes. Meanwhile the status bar shows `Indexing Disk 1`.

A disk with no volume UUID can't be indexed. Its row reads `Can’t be indexed: this disk has no UUID`, and its menu entry reads `Disk 1 (Can’t be indexed)`.

To stop indexing a disk, click **Add excluded path** (the plus button), choose the disk's folder, such as `/Volumes/Disk 1`, and click **Exclude**. The disk goes back in the list as a disk row.

## Choose what happens when you connect a disk

In **Settings…** > **Locations**, the menu **When a disk that isn’t indexed is connected** has four answers:

| Answer | What happens |
|---|---|
| **Ask in the Status Bar** | The default. The status bar line from step 3 appears, also for disks connected before Wherever opened. |
| **Ask with a Notification** | A notification titled `Index “Disk 1”?` offers **Index** and **Not Now**. |
| **Index Automatically** | Wherever indexes the disk at once. |
| **Do Nothing** | Nothing happens. Use step 1 or 2. |

**Ask with a Notification** and **Index Automatically** also work while Wherever is closed, as long as the menu bar icon or the launcher shortcut is on. When you connect a disk, Wherever starts without a window, acts, and quits by itself. After a notification, Wherever stays open until you answer or dismiss it, or until the disk is disconnected. If the icon and the shortcut are both off, or you chose **Quit Wherever** in the icon's menu, these answers work only while Wherever is open.

Wherever asks macOS for permission to notify only while **Ask with a Notification** is chosen. If notifications are off, `Notifications for Wherever are turned off. Allow them in System Settings > Notifications.` appears under the menu, and the status bar asks instead.

No answer offers a disk that a folder row in **Excluded Paths** covers. See the next section.

## Exclude a path

The **Excluded Paths** list is Wherever's only skip rule. Its footer reads `Wherever skips these paths and everything inside them. Search Content still reads one, or a folder inside it, when you choose it as the Search folder.` The skip applies to file names and to Search Content. Hidden files and system folders are searched.

Disks that are not indexed come first in the list, then the folders. A second footer line reads `Other disks start in this list. Remove a disk to index it.`

The list starts with nine folder rows: `~/Library/CloudStorage`, `~/Library/Biome`, `~/Library/Caches`, `~/Library/Logs`, `~/Library/Metadata`, `/Library/Caches`, `/System/Library/Caches`, `/private/var` and `/private/tmp`. Remove any of them to search there. **Reset** under [Reset Settings](settings.md#reset-settings) puts them back and returns every other disk to the list.

To add a path, click **Add excluded path**, choose the folder and click **Exclude**. A folder on another disk is stored with that disk's identity, so renaming the disk keeps the row.

A folder row that holds a disk, such as `/Volumes`, keeps that disk out. If you add `/Volumes` while Disk 1 is indexed, Wherever asks `Exclude “/Volumes”?` and says `Wherever won’t index Disk 1 while this path is in the list.` Click **Exclude**, and the row wins. The disk stays switched on and comes back when you remove the row. A disk that is not indexed can't be switched on while such a row covers it. Its row reads `Remove “/Volumes” to index this disk`, and the minus button stays off for it.

Two more notes a row can show:

- `This path isn’t valid`: the row is not a full path.
- `The disk isn’t connected`: the row is a folder on a disk that is not plugged in.

If a change to the list fails, the pane says `Wherever could not change the locations. Try again.`

When your Search folder lies on a disk you did not index, Search Content reads it from the disk and ignores the list. [Normal mode](normal-mode.md) covers Search Content.

## Live updates

Wherever watches every indexed disk with macOS file events, so results follow changes with no rescan. The status bar reads `Live updates on` once the startup disk is watched. A switched-on disk stays switched on while unplugged, and Wherever picks it up when it returns.

Two status bar lines flag a disk problem:

| Line | Why | What to do |
|---|---|---|
| `Could not read Disk 1` | The disk's top folder would not open, or its crawl failed, so Wherever built nothing. | Check that the disk is mounted and readable, then eject and reconnect it. |
| `Live updates are off for Disk 1` | The watcher did not start or stopped. Changes show after the next crawl. | Choose **Quit Wherever** from the Wherever menu, then open Wherever again. |

## Related

- [Getting started](getting-started.md)
- [Normal mode](normal-mode.md)
- [Settings](settings.md)
- [Your data on this Mac](privacy-and-data.md)
- [Troubleshooting and FAQ](troubleshooting.md)
