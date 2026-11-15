# The launcher

Press ⌃⇧F in any app to search file names in a small panel, open a file and land back where you were. The Keyboard Shortcuts window and the background opacity slider in Settings call it Wherever search.

## Open and close it

⌃⇧F opens the launcher on the screen where your mouse is, above other windows and full-screen apps. Your current app stays active. If Wherever has lost Full Disk Access, the shortcut shows the welcome window instead.

The launcher closes when you:

- press ⌃⇧F again, ⌘W, or ⎋ on an empty field;
- open a file or show it in Finder;
- click another window or app.

Closing empties the field. With no window open, closing the launcher also quits Wherever, so the next press waits while it loads. If Wherever is still scanning your disks or re-reading its index, it finishes that work first, with no window, then quits.

## Search

The list stays empty until you type, and shows `No results` when nothing matches. The panel searches file names only, in Simple and in Normal mode. It has no filter pills and no **Search Content**.

The operators in [Search syntax](search-syntax.md) work here, and **Hide Invisible Files** and **Typo-Tolerant Search** apply. The list shows up to 10 rows, each with Name and Folder and the matching letters in bold. A line below shows the index state, the file count and the result count.

## Keys

- ↑ ↓ move through the results. ↓ in the field enters the list.
- ↩ opens the selected file, or the first result when none is selected, and closes the launcher.
- ⌘↩ shows the selected file in Finder and closes the launcher.
- Space shows or closes the preview while the list has focus.
- ⌘C copies the path of the selected file. The launcher stays open.
- ⌘↓ opens the selected archive in its own window. See [Archives](archives.md).
- ⌘N shows all results in a Wherever window.
- ⎋ clears the search text, then closes the launcher.
- ⌘W closes the launcher.

## Preview a file

Press ↓ to enter the list, then Space. A Quick Look view opens beside the list and follows the selection. The preview sits inside the panel because the usual Quick Look window cannot open while the launcher keeps your other app in front.

## Continue in the main window

Once you type, the last row reads **Show all in Wherever**. Click it or press ⌘N. The launcher closes and the window opens with the same text.

## Change or remove the shortcut

1. Choose **Settings…** > **General**.
2. Under Shortcut, click the button beside **Launcher shortcut**. It shows your keys, or **Record Shortcut** when none is set. While you record, it reads `Press a shortcut…`.
3. Press the new keys. ⎋ cancels, and Delete removes the shortcut.

With no shortcut, a click on the menu bar icon still opens the launcher. The shortcut works with no window open, and even with Wherever closed. **Quit Wherever** in the menu bar icon's menu turns it off until Wherever opens again.

Wherever refuses some keys and says why:

- `Hold Control, Option or Command with the key.` The keys have no ⌃, ⌥ or ⌘.
- `macOS already uses this shortcut.` Space with ⌘, ⌥⌘, ⌃, ⌃⌥ or ⇧⌘.
- `Wherever already uses this shortcut.` ⌘N, ⌘W, ⌘Q, ⌘C, ⌘↩, ⌥⌘I, ⌘S, ⇧⌘S, the standard Hide, Minimize and Edit keys, ⌘ with the comma key, or ⇧⌘ with the period key. A saved shortcut that is now refused goes back to ⌃⇧F.
- `Use a letter, number or symbol key.` An arrow, function, Return or Tab key.
- `Wherever could not register this shortcut. Try another.` macOS rejected it.

## Related

- [Getting started](getting-started.md)
- [Search syntax](search-syntax.md)
- [Keyboard shortcuts](keyboard-shortcuts.md)
- [Settings](settings.md)
