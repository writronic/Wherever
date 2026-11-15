# Normal mode

Use Normal mode to pick a folder, choose how a name must match, filter results and search inside files.

## Switch between Simple and Normal

Choose **View** > **Normal**. Open windows change at once, and Wherever opens in your last mode.

Normal replaces Simple's search band with a three-row form and a filter bar. Choose **View** > **Simple** to go back. Simple drops the Search folder, the match menus, the content terms and the filters. It keeps your search text and **Hide Invisible Files**, and it stops a running Search Content.

## Search by name

The form has three rows: **Search folder:**, **File name:** and **File content:**. The first two search as you type. Only **Search Content** reads inside files.

**Search folder:** sets where to look, and **File name:** sets which files. Search Content does not read the files inside a folder whose name matches File name. To read a folder's files, put the folder in Search folder.

| Search folder | File name | File content | What you get |
|---|---|---|---|
| empty | empty | terms, then click | Every file on every indexed disk that holds the terms |
| empty | text | terms, then click | Only the files with that name that hold the terms |
| a folder | empty | terms, then click | Every file in that folder that holds the terms |
| a folder | text | terms, then click | Only the files with that name in that folder that hold the terms |
| any | text | empty | The name list, as you type |

The **File name match** menu sets how your text must match a name:

- **Contains** works like Simple mode's field, and the operators in [Search syntax](search-syntax.md) work in it.
- **Matches** needs the whole name, extension included, to equal your text.
- **Begins with** and **Ends with** match the start or the end of a name.
- **Extension** takes extensions separated by commas, semicolons or spaces.
- **Wildcard** reads `*`, `?` and `[ ]` as a pattern for the whole name.
- **Regex** reads a regular expression. One that does not parse matches nothing.

Only **Contains** finds typos, and only with **Typo-Tolerant Search** on. **Matches**, **Begins with**, **Ends with**, **Wildcard** and **Regex** take your text as one phrase, so a typed `!` or quote is part of the pattern.

## Choose a folder or disk

Leave **Search folder:** empty to search every indexed disk. Or type a path that starts with `/` or `~/`, or drag a folder from Finder onto the box. A missing path, a relative path or a file matches nothing. If one of those is in the box when you click **Search Content**, the status bar shows `Folder not found` beside the count.

Click the chevron, or press ↓ or ↑ in the box, to open the disk menu. It lists **Every indexed disk**, the startup disk and each indexed disk. Other disks follow, marked `(Not indexed)`, or `(Can’t be indexed)` when the disk has no volume ID. **Browse…** at the end opens a folder panel at the current Search folder. Click **Choose** to make the folder you pick the Search folder, or **Cancel** to keep the old one.

Pick a `(Not indexed)` disk, or drop or browse to a folder on one, and Wherever asks `Index “Disk 1”?` Click **Index** to switch the disk on or **Cancel** to leave it off. Either way it becomes the Search folder. Wherever does not ask about a disk it cannot index or one under an **Excluded Paths** row. [Disks and excluded paths](disks-and-locations.md) covers both.

## Search inside files

Type a term in **File content:** and press Return to make it a token. A comma does not split a term. The **File content match** menu offers **Find any term**, the default, and **Find all terms**. **Find all terms** needs each term somewhere in the file. The terms do not have to share a line.

To start, click **Search Content**. You can also press Return when every term in the field is a token. Text you typed but did not turn into a token counts as a term too. The button is off while the row is empty.

Your File name text and its match mode, the Search folder, the filters and **Hide invisible files** decide which files Wherever reads. With File name empty, it reads every file in scope.

Wherever keeps no text index, so each search opens the files again. It reads a file when its first bytes are text, whatever its extension. It also reads:

- PDF and RTF.
- Word: doc, docx, docm, dot, dotx, dotm.
- Excel: xls, xlsx, xlsm, xlt, xltx, xltm.
- PowerPoint: ppt, pptx, pptm, pot, potx, pps, ppsx, ppsm.
- OpenDocument text, sheets, slides and templates: odt, ods, odp, ott, ots, otp.
- Mail: eml, emlx and mbox.

A scanned PDF has no text layer. Terms ignore case and accents both ways and match as plain letters, without typo tolerance.

Results appear as files match. While Wherever reads, the button reads **Stop** and the status bar shows `Read N of M files`. **Stop** keeps what it found and shows `Stopped after N of M files`.

If no index holds the Search folder, such as a disk that is not indexed or a path under an **Excluded Paths** row, Wherever lists the folder from disk and reads every file in it, excluded paths included.

When Wherever passes files over, the status bar shows `N files skipped`. Hover over it for the causes: `N files not downloaded` (iCloud placeholders, which Wherever never downloads) and `N files in unsupported formats` (Pages, Numbers, Keynote, epub).

The results do not refresh. A file that changes later keeps the result it had, and new terms find nothing until you click **Search Content** again. Clear the terms to go back to the name search.

After a search, a change in the other boxes does one of two things:

- The results narrow at once, and nothing is read, when the Search folder is the same and File name and the filters were empty at the search or have not changed.
- Otherwise Wherever reads again 0.4 seconds after your last change, with the terms as they are now. The old rows stay until the new results come, and **Stop** cancels a read that is waiting.

## Narrow results with filters

The bar under the form has four pull-down pills and a checkbox:

- **Kind** picks one value: **Files**, **Folders**, **Links**, or a type such as **Images**, **Documents**, **Code** or **Apps**.
- **Extension** opens a field for extensions, such as `pdf, docx`.
- **Size** offers ranges from **Under 1 MB** to **Over 1 GB**.
- **Modified** offers periods from **Last 24 hours** to **Last 12 months**.

A pill in use shows its choice, as in `Kind: Images`. The pills narrow each other: **Documents** with the extension `pdf` lists PDFs only. A Kind pill or Search folder you set wins over a `kind:` or `in:` you type. The Extension pill and a type in Kind add to a typed `ext:` or `type:`.

**Hide invisible files** drops hidden files and system folders. It is off by default and shares one setting with **View** > **Hide Invisible Files** (⇧⌘.).

## Related

- [Search syntax](search-syntax.md): operators for Contains.
- [Disks and excluded paths](disks-and-locations.md): index a disk, skip paths.
- [Troubleshooting and FAQ](troubleshooting.md): why Search Content skips files.
