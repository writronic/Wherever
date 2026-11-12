# Search syntax

Type words, signs and filters in the search field to narrow the results to the files you mean.

A file must match every word and every filter you type. At least one word must be in its name; the other words can match a folder above it. **Help** > **Keyboard Shortcuts** shows the same examples under Search operators.

## Where the syntax works

- Simple mode and the launcher read your text as you type it.
- In Normal mode, **Contains** in the File name menu reads it too. **Matches**, **Begins with**, **Ends with**, **Wildcard** and **Regex** take everything you type as one pattern, so a filter typed there matches as plain letters. **Extension** splits your text on commas, semicolons and spaces and ignores signs.
- The [`wherever` command](command-line.md) reads its words as Simple mode does. Quote a word with a space or a sign the shell reads, such as `wherever '*.pdf'` or `wherever 'size:>10mb'`.
- Normal mode's pills add their own filters to your text. A **Size** or **Modified** pill replaces a typed `size:` or `modified:`, and **Search folder** replaces a typed `in:`.

## Match words

| Type | Finds |
|---|---|
| `report` | Names that hold the word, its letters side by side |
| `'report` | Names that hold these exact letters, and never a typo |
| `^report` | Names that begin with the word |
| `report$` | Names that end with the word |
| `^report$` | Names that are exactly the word, extension included |
| `!draft` | Leaves out names that hold the word |
| `"annual report"` | The words together, space included |
| `cardinal*.dmg` | Whole names that match a word with `*` (any letters) or `?` (one letter); type `'` first to find a real `*` or `?` |
| `projects/report` | Names inside a folder whose name matches the first word |

Inside quotes, `""` is one literal quote. A word that starts with `~/` is a path under your home folder.

`'report` finds the same names as `report`. It gives no extra rank to a whole name and never takes the typo search below. A quoted phrase needs its space: `"annual report"` does not find `annual_report.txt`.

## Filter by kind, place, size and date

| Type | Finds |
|---|---|
| `ext:pdf,docx` | Files with one of these extensions; a comma or semicolon separates them and a leading dot is optional |
| `*.{jpg,png}` | The same, in short form; `*.pdf` takes one extension |
| `!*.log` | Leaves out files with this extension |
| `type:image` | Images; also video, audio, doc, code, archive, font and app |
| `kind:folder` | Folders only; also file and link |
| `in:~/Documents` | Only inside this folder; `~` is your home folder |
| `size:>10mb` | Size in kb, mb, gb or tb; also `<1mb` and `1mb..100mb` |
| `modified:<7d` | Changed within s, m (minutes), h, d, w, mo or y; also `1w..1mo` |
| `mtime:2w` | The same as `modified:` |
| `hidden:no` | Leaves out invisible files |

A comma list works in `type:` too. Only `*.ext` and `*.{a,b}` are extension shortcuts. Any other word with `*` or `?` is a whole-name wildcard, as in the Match words table.

Sizes use decimal units, so 1 mb is 1,000,000 bytes. `k`, `m`, `g` and `t` work alone too. `>` and `<` include the value. A size with a unit and no sign means at least that size. A bare number is an exact count of bytes.

A bare age such as `2w` means within the last 2 weeks. `<7d` means within the last 7 days, and `>7d` means older than that. A number with no unit counts days.

`hidden:no` leaves out:

- items with Finder's hidden flag
- names that start with a dot
- everything inside a folder of either kind
- the startup disk's System and Library folders
- your own Library folder

System/Applications and what it holds stay. **Hide Invisible Files** in the View menu and **Hide invisible files** in Normal mode set the same filter.

## Match patterns

| Type | Finds |
|---|---|
| `re:^IMG_\d+` | Names that match a regular expression |
| `glob:report-??.pdf` | Whole names that match a pattern of `*`, `?` and `[ ]` |
| `begins:annual` | Names that begin with this text |
| `ends:2026` | Names that end with this text |
| `whole:README.md` | Names that are exactly this text |

`re:` ignores case and matches anywhere in the name, unless you add `^` or `$`. `glob:` ignores case and must match the whole name; `[!abc]` leaves out those letters. Put a value with spaces or signs in quotes. With several `re:` or `glob:` patterns, a name must match all of them.

## Typos and accents

- By default, a plain word needs its letters side by side and forgives no typo.
- With **Typo-Tolerant Search** on (**Settings…** > **General**), Wherever searches again when no name holds your words side by side. This search allows letters apart and typos: a plain word of 5 letters or more forgives one typo, and a word of 8 or more forgives two. Words with a sign and filter values never take it. The filters you typed still hold, so `hello ext:pdf` can list `hallo.pdf` when no PDF holds `hello`.
- A name found only through a typo ranks below every clean match. When that search does not find every word well, Wherever searches once more and also forgives a wrong first letter.
- Case does not matter.
- A query without accents finds accented names, and an accented query finds plain names. The spelling you typed ranks first. This holds for words, `ext:`, `glob:` and `re:`, but not inside a `[ ]` class.
- Past eight words, Wherever drops the earliest ones. Words with `!` do not count.

## When a filter is not finished

Wherever ignores a half-typed filter such as `size:` or `size:>`, so typing never shows an error. A finished filter with a bad value matches nothing, for example `kind:x`, `hidden:yes` or a broken regular expression. A key Wherever does not know, such as `c:foo`, is searched as a word.

## What is not supported

No operator searches the text inside files. `text:` and `anytext:` are searched as words in names. To find text inside files, use **Search Content** in [Normal mode](normal-mode.md).

## Related

- [Searching](searching.md)
- [Normal mode](normal-mode.md)
- [The command-line tool](command-line.md)
- [Keyboard shortcuts](keyboard-shortcuts.md)
