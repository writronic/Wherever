# Archives

Open an archive from a search result and look inside it in a window of its own, without leaving Wherever.

## Formats

Wherever opens these:

- The zip family: `.zip`, `.jar`, `.apk`, `.aar` and `.cbz`.
- Tarballs: `.tar`, `.tar.gz` (`.tgz`), `.tar.bz2` (`.tbz`, `.tbz2`) and `.tar.xz` (`.txz`).
- RAR files (`.rar`, `.cbr`) without a password.
- Installer packages (`.pkg`) and disk images (`.dmg`).

It does not open split archives, 7z, ISO and other formats, or a lone `.gz`, `.bz2` or `.xz` file.

## Open an archive

Select an archive in the results and press ⌘↓, or right-click it and choose **Show Archive Contents**. **File** > **Show Archive Contents** works too. The archive opens in a new window. ⌘↓ also works in the launcher.

In the window, ↩ or ⌘↓ opens a folder, an item or a nested archive, and ⌘↑ goes up to the enclosing folder. Type in the search field to search the items. [Keys in the archive window](#keys-in-the-archive-window) lists every key.

Wherever leaves out items whose names or links point outside the archive, and device files. It counts them as skipped; hover over the count for the cause.

## Expand an archive

In an archive window, choose **File** > **Expand Archive…** to copy the whole archive to a folder. To copy only some items, select them, right-click and choose **Expand Selected Items…**. A progress sheet shows a **Stop** button. Stopping removes the items expanded so far.

## Edit a zip or tarball

You can change an archive, but you cannot create one. Only `.zip` files and tarballs can be edited. The window shows **Read only** for every other archive, for items inside a nested archive, and for a zip with old ZipCrypto encryption.

- **Delete**: select items and press ⌫, or right-click and choose **Delete**. An item that another item in the archive links to stays.
- **Add** or **Replace**: choose **File** > **Add Files…** and pick files or folders. If an item with the same name exists, Wherever asks whether to **Replace** it, **Keep Both**, or **Stop**. **Apply to All** gives the same answer for the rest. The archive never holds two items with one name.

Undo with ⌘Z and redo with ⇧⌘Z. The window shows **Edited** after a change and marks the close button.

- ⌘S (**Save**) writes the changes. Wherever builds a new copy first and replaces the original only after the copy is complete.
- ⇧⌘S (**Save As…**) saves the archive under a new name.
- Closing an edited window asks whether to save: **Save**, **Don’t Save**, or **Cancel**.

## Passwords

A password-protected zip or disk image asks for its password in the window: `Enter the password for “name”.` A wrong one shows `The password is incorrect. Try again.` Wherever never stores the password. A RAR with a password does not open.

## Keys in the archive window

| Keys | What it does |
|---|---|
| ↩ ⌘↓ | Open the item, the folder or the archive |
| ⌘↑ | Go to the enclosing folder |
| Space | Show or close Quick Look |
| ⌘↩ | Show the archive in Finder |
| ⌘C | Copy the path inside the archive |
| ⎋ | Clear the search text |
| ⌫ | Delete the selected items |
| ⌘S | Save the changes |
| ⇧⌘S | Save the archive under a new name |
| ⌘Z | Undo the last change |
| ⇧⌘Z | Redo the last change |

**Help** > **Keyboard Shortcuts** lists them too.

## Related

- [Results, inspector and status bar](results.md)
- [Keyboard shortcuts](keyboard-shortcuts.md)
- [The launcher](launcher.md)
