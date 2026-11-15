# Results, inspector and status bar

Choose columns, sort and open results, then read the inspector and the status bar.

## Read the results

Each row is a file or folder. **Name** shows its icon and draws the letters that match your search in bold. The other columns:

- **Folder** holds the folder's path.
- **Size** shows a size such as `4.2 MB`. A folder shows `--`.
- **Modified**, **Created** and **Opened** show a date and time in your region's format, with seconds. **Opened** is the file system's last-access time, not your open history. **Created** and **Opened** show `--` when the file system gives no date.
- **Kind** names the type as macOS does.

An empty search lists every indexed file by name, A to Z.

## Choose columns

Right-click the column header, or press ⇧F10 with the results focused. The menu holds **Folder**, **Size**, **Modified**, **Created**, **Opened** and **Kind**, each checked when shown. **Name** always shows. Every window follows your choice.

The same menu holds **Keep Folders on Top**. It lists folders before files and keeps each group in its order. It starts off.

## Sort

Results start in best-match order. Click **Name**, **Folder** or **Kind** to sort A to Z. Click **Size**, **Modified**, **Created** or **Opened** to put the largest or newest first. A second click reverses it, and a third returns to best match. The sort stays when you type a new search.

## Open a result

Move with ↑ and ↓. Press ↩ or double-click to open the selected row, and ⌘↩ to show it in Finder. Space opens Quick Look, and Space again closes it. ⌘C copies the path. Drag a row into another app to copy the file.

Right-click a row for **Open**, **Show in Finder**, **Quick Look** and **Copy Path**. On an archive the menu also holds **Show Archive Contents** (⌘↓); see [Archives](archives.md). In the search field, ↩ and ⌘↩ act on the selected row, or on the first row when none is selected. [Keyboard shortcuts](keyboard-shortcuts.md) lists every key.

## Use the inspector

The inspector starts hidden. Choose **View** > **Show Inspector** (⌥⌘I), or turn on **Show inspector** under **Settings…** > **General** > **Appearance**. The menu item then reads **Hide Inspector**. The choice applies to every window and both modes. Dragging the divider shut also hides the inspector, and the menu item and the setting change to match.

For the selected row it shows a Quick Look preview, the name, the kind and the size. The **Quick Look** and **Show in Finder** buttons act on that row, and an archive also gets **Show Archive Contents**. Under **Information** it lists **Kind**, **Size** with the byte count, **Where**, **Created**, **Modified**, **Owner** and **Permissions**, which reads `Read & Write`, `Read only`, `Write only` or `No access`. Unknown values show `--`.

With no selection the pane says `No Selection`. With several rows selected it says how many, such as `3 items`. A file kept in iCloud shows `In iCloud` in place of a preview, because a preview would download it.

## Read the status bar

The bar sits under the results in both modes:

`Live updates on | Files: 1,234,567 ... Search: 12 results – 9 ms`

A filled dot marks `Ready` and `Live updates on`. Two vertical bars mark `Live updates paused`. An open ring marks every other state. The states run in this order:

- `Starting`, then `Loading the saved index` when one exists, or `Indexing the disk` when the startup disk needs a scan.
- `Finishing the index…` while it builds and saves the index.
- `Ready` once the index is loaded, and `Live updates on` once Wherever also watches the disk.

Click `Live updates on`, or choose **View** > **Pause Live Updates**, to pause the watching. The bar reads `Live updates paused`, new changes on disk stop reaching the results, and the processor rests. Searching, sorting and **Search Content** keep working on the index as it stands. The pause stays after you quit Wherever.

Click `Live updates paused`, or choose **View** > **Resume Live Updates**, to resume. Wherever then replays what changed while it was paused.

Only `Live updates on` and `Live updates paused` can be clicked. In every other state the bar is plain text. The launcher's footer shows the same words with no button.

If the index cannot be built, the bar reads `Wherever could not build the index. Choose Quit Wherever from the Wherever menu, then open Wherever again.`

Other lines appear beside the state:

- `Indexing Disk 1` while another disk is being indexed.
- `Could not read Disk 1` when a disk's folder would not open.
- `Live updates are off for Disk 1` when Wherever cannot watch a disk.
- `Files: N` counts the entries in the index.
- `Search: N results – T ms` shows the last search. `Search failed. Try again.` replaces it on a failure.

While **Search Content** runs, the bar adds `Read N of M files`, or `Stopped after N of M files` after **Stop**. `N files skipped` appears when **Search Content** skips files; hover over it for the causes. [Normal mode](normal-mode.md) explains **Search Content**.

By default, in the main windows, a plugged-in disk that is not indexed adds `Disk 1 is not indexed` with **Index**, or `2 disks are not indexed` with **Manage…**. [Disks and excluded paths](disks-and-locations.md) covers both.

## Related

- [Normal mode](normal-mode.md)
- [Archives](archives.md)
- [Disks and excluded paths](disks-and-locations.md)
- [Keyboard shortcuts](keyboard-shortcuts.md)
- [Troubleshooting and FAQ](troubleshooting.md)
