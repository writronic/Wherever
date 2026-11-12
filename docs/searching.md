# Searching

Type in the search field and Wherever lists matching files as you type, best match first.

## Type to search

Click the field that reads `Search files` and type. The results update on every keystroke, and the rows on screen stay until the new ones are ready. A file must match every word you type. At least one word must be in its name; the other words can match a folder above it. [Search syntax](search-syntax.md) covers the signs and filters you can add.

A plain word must appear in the name with its letters side by side, in order. `hello` finds `hello.txt` and `say-hello.md`, but not `hell.txt` or `helper_tool.log`. Case does not matter. A name scores higher when the word is the whole name, starts it, or starts a word in it.

Press ↓ to move from the field to the first row. Press ↩ to open the selected row, or the first row when none is selected. Press ⌘↩ to show it in Finder. Both keys wait for the results of your latest text. Press ⎋ to clear the text. When the list has focus, a letter, digit, punctuation mark or symbol you type goes to the field, so typing `.pdf` searches `.pdf`.

## List every file

With the field empty, Wherever lists every indexed file by name, from A to Z. The launcher stays empty until you type. Click a column header to sort another way; see [Sort](results.md#sort).

## Find a name despite an accent

Accents work both ways. `ozet` finds `özet.pdf`, and `özet` also finds `ozet.txt`, after the names spelled as you typed. Turkish İ and ı read as i.

## With Typo-Tolerant Search on

**Typo-Tolerant Search** in **Settings…** > **General** is off by default. When it is on, Wherever runs a looser search, but only when no name holds your words side by side.

The looser search finds letters that sit apart, in order, and forgives typos. A word of 5 letters or more forgives one typo, and a word of 8 or more forgives two. `epxlorer` finds `explorer.txt`. When the best matches still do not hold your word well, one more search also forgives a wrong first letter: `xeport` finds `report.txt`. Wherever never changes a digit, so `rep0rt` does not find `report.txt`.

A name found only through a typo comes after every clean match. Once any name holds your word side by side, only those names show: `helo` finds `Phelonius.txt` and not `hello.txt`. A word with a sign never takes the looser search.

## Order of the results

Until you pick a column, Wherever sorts by best match. It puts matches in four groups, best first:

1. The word is the whole name, or the name without its extension.
2. The name starts with the word.
3. Any other clean match.
4. A match found only through a typo, with **Typo-Tolerant Search** on.

Inside a group, the folder a file is in moves it up or down a little. Files in Library, System, caches, `node_modules`, app bundles and dot folders rank lower. Files in Applications folders rank higher. Wherever still lists them all.

## Files you open rank higher

A file you open often moves up among equally good matches. It never moves into a better group, and only the first 256 matches get this lift. One open gives a small lift that halves every two weeks. Only **Open** counts, from ↩, a double-click or the row menu. **Show in Finder**, **Quick Look**, **Copy Path** and dragging do not count. A column sort ignores the lift.

The history stays on this Mac. **Clear Open History…** under **Settings…** > **General** erases it.

## Hidden files

Results include hidden files and system folders. Choose **View** > **Hide Invisible Files** (⇧⌘.) to leave them out. This one setting covers every window, Normal mode and the launcher.

## Results stay current

When files change, the list refreshes without retyping. A window you cannot see waits: one that is covered, minimized or on another Space, or one that opens covered. It refreshes once when it shows. A change that arrives during a running search waits for that search to end.

## Use more than one window

Press ⌘N (**New Window**) to open another window. Each window has its own text, results and sort. The mode, the inspector and **Hide Invisible Files** are shared.

## Related

- [Search syntax](search-syntax.md): operators and filters.
- [Normal mode](normal-mode.md): the form, the pills and Search Content.
- [Results, inspector and status bar](results.md): columns, sorting and the row menu.
- [The launcher](launcher.md): the small panel behind ⌃⇧F.
- [Keyboard shortcuts](keyboard-shortcuts.md): every key.
- [Settings](settings.md): the open history and the other controls.
