# The command-line tool

Search from Terminal with the `wherever` command.

The command asks the running Wherever app for results, so it finds what the search window finds. It reads no files itself, so Terminal needs no Full Disk Access.

## Install the command

Click **Install** in one of two places. Both install the command right away:

- The welcome window: the **Command-Line Tool** box on the **Choose Your Mode** page.
- **Settings… > General > Command-Line Tool**.

Before you install, the caption reads `Search from the command line with the wherever command.`

Install makes `~/.local/bin/wherever` a link to the `wherever` program inside `Wherever.app/Contents/Helpers`. It creates the `~/.local/bin` folder if it is missing. The link keeps working after Wherever updates itself. Install asks for no password, because both files live in your home folder.

So that Terminal finds the command, Install also adds these three lines once to the end of `~/.zshenv`, the file every zsh reads:

```sh
# >>> wherever >>>
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
# <<< wherever <<<
```

The line adds `~/.local/bin` to `PATH` only when it is not there yet. zsh is the shell macOS uses. In bash or fish, add `~/.local/bin` to `PATH` yourself. In Shortcuts, Automator, launchd or cron, call `$HOME/.local/bin/wherever` by its full path, because launchd and cron do not read `~`.

When the command works, the caption reads `Installed at ~/.local/bin/wherever. Open a new Terminal window to use it.` and the button reads **Uninstall**. A Terminal window that was open before the install keeps its old `PATH`, so open a new one.

Install refuses in two cases and changes nothing:

| Message | Why | What to do |
|---|---|---|
| `Move Wherever to the Applications folder, then try again.` | Wherever runs from the disk image or from a copy macOS moved aside. | Drag Wherever to Applications and open it from there. |
| `Another program already uses ~/.local/bin/wherever. Remove it, then try again.` | A file there is not Wherever's link. Wherever never replaces it. | Remove or rename that file yourself, then click **Install**. |

Any other failure reads `Wherever could not install the command-line tool.` The welcome window shows these messages in red in the **Command-Line Tool** box, and the window keeps its size.

If the caption reads `The wherever command is missing. Install it again.`, the link was deleted or points to another copy of Wherever. Click **Install** to repair it, or **Uninstall** to stop answering the command.

## Uninstall the command

Click **Uninstall** under **Settings… > General > Command-Line Tool**. Wherever removes the link and the three lines it added to `~/.zshenv`, and stops answering the command. It asks for no password. **Reset** in **Settings… > General** removes both too.

Wherever removes `~/.local/bin/wherever` only when it is a link to a copy of Wherever. It removes the lines from `~/.zshenv` only when all three are still as Wherever wrote them. If you edited them, it leaves the file alone. A failure reads `Wherever could not uninstall the command-line tool.`

## Search

```sh
wherever [options] <query...>
```

The words after the options are one query, in Wherever's [search syntax](search-syntax.md). You need at least one word.

```sh
wherever invoice ext:pdf
wherever --in ~/Documents report
wherever -s size -n 10 type:video
wherever 'size:>1gb' modified:7d
wherever -0 ext:log | xargs -0 ls -l
```

Quote what the shell would change first:

- A word with a space: `wherever "annual report"` searches for the two words together, space included.
- A sign the shell reads: `*`, `!`, `$`, `^`, `>` and `<`. Write `wherever '*.pdf'`, `wherever 'report$'`, `wherever '!draft' ext:txt` or `wherever 'size:>10mb'`. Without the quotes, zsh stops with `no matches found` or writes to a file named `10mb`.

| Option | Effect |
|---|---|
| `-n N`, `--limit N` | Show at most N rows. `0` shows all. The default is 100 on a terminal and all when piped. |
| `-s KEY`, `--sort KEY` | Sort by `best` (the default), `name`, `folder`, `size`, `modified`, `created`, `opened` or `kind`. |
| `-r`, `--reverse` | Reverse the order. |
| `--in DIR` | Only under the folder DIR. A relative DIR starts at the current folder; `~` and `~/` start at your home folder. |
| `-0`, `--null` | End each path with a NUL byte instead of a new line. |
| `-j`, `--json` | Print one JSON object per line. |
| `-h`, `--help` | Show the help. |
| `-V`, `--version` | Show the version, for example `wherever 0.1.0`. |

Both `--limit 10` and `--limit=10` work. `--` ends the options, so `wherever -- -draft` searches for `-draft`.

`best` lists the best match first, as the search window does before you click a column. Every other key sorts like a first click on that column header: `name`, `folder` and `kind` from A to Z, and `size`, `modified`, `created` and `opened` largest or newest first. `-r` turns the order around. **Keep Folders on Top** does not apply.

## Output

On a terminal, each path takes one line, and the matching letters are bold, as in the Name column. Bold is off when `NO_COLOR` is set to a non-empty value or `TERM` is `dumb`. A control character in a name shows as `?`. When the limit cuts the list, a last line on standard error reads `… and N more. Use --limit 0 to see all.`

Piped into another program, the output is every path, one per line, with no bold and no changes. A file name can hold a new line, so use `-0` with `xargs -0` when you pass paths on.

`--json` prints one object per line with the keys `path`, `name`, `folder`, `kind`, `size`, `modified`, `created` and `opened`. `kind` is `file`, `folder` or `link`. The three dates are Unix time in seconds. You can't use `-0` and `--json` together.

The command reads the whole answer before it prints, so a pager such as `less` never keeps Wherever waiting.

## What it finds

The command searches the same index as the search window:

- The same **Excluded Paths**, and the disks you indexed.
- The same matching, **Typo-Tolerant Search** included, and the same rank for files you open often.
- File and folder names only. It has no Search Content.
- Everything, invisible files included, even while **Hide Invisible Files** is on in the app. Add `hidden:no` to leave them out.

When Wherever is not running, the command starts it in the background, with no window and no Dock icon. It waits up to 10 seconds for Wherever, then prints the results. If the first scan is still running, it waits up to 15 seconds in all. Wherever keeps running until the scan ends and for 10 seconds after the last answer. Then it quits by itself if no window is open.

A copy of the command outside `Wherever.app` never starts Wherever. The command's messages are in English.

## Exit status and messages

The exit status works as `grep`'s does:

- `0`: one or more paths.
- `1`: nothing matches.
- `2`: an error. One line on standard error starts with `wherever: `.

| Message after `wherever: ` | Why | What to do |
|---|---|---|
| `cannot reach Wherever. Open Wherever, and install the command-line tool in Settings > General if it is off.` | Wherever did not start in 10 seconds, it does not have Full Disk Access yet, or the command-line tool is off. | Open Wherever. Check that **Settings… > General > Command-Line Tool** shows **Uninstall**. |
| `Wherever is still indexing this Mac, N items so far. Try again in a moment.` | The first scan of the startup disk is still running. | Wait until the status bar reads `Live updates on` or `Live updates paused`. |
| `Wherever is answering 8 other requests. Try again.` | Eight other searches from the command are still running. | Try again. |
| `run wherever as yourself, not as root.` | You ran the command with `sudo` or as root. | Run it without `sudo`. |
| `give a name to look for, for example: wherever report.pdf. Run wherever --help to see the options.` | The query is empty. An empty query would list every file. | Add a word. |
| `unknown option -x. Run wherever --help to see the options.` | An option is misspelled. Other option mistakes end the same way. | Check the option table above. |
| `the answer from Wherever was cut short. Try again.` | Wherever stopped during the answer, for example because it quit. | Try again. |
| `the search failed`, `Wherever is quitting` | The search stopped inside Wherever, or Wherever is quitting. | Try again. Open Wherever if it quit. |
| `Wherever sent an answer this tool cannot read. Update Wherever and try again.`, `the command-line tool does not match this version of Wherever` | The command and the app come from different versions. | Run `~/.local/bin/wherever`, the copy inside the Wherever you run, not a copy from elsewhere. |
| `cannot reach Wherever, because its socket path … is longer than the 103 bytes macOS allows. Report this path to Wherever's developers.` | macOS returned an unusually long cache folder path. Your home folder's length does not affect the socket. | Include the reported path when you report the problem. |

A warning can come with the results. It starts with `wherever: ` too, and the exit status stays `0` or `1`:

- `Wherever is updating the startup disk index, so results may still change`
- `the startup disk could not be indexed, so its files are missing`
- `/Volumes/Disk 1 is still being indexed, so some of its files may be missing`

If a folder is not indexed or is in Excluded Paths, a warning says that nothing under it was searched and points to Settings > Locations. When Wherever sends two warnings at once, a `; ` joins them. A missing `--in` folder reads `there is no folder <path>.`

## Privacy

The command talks to Wherever over a socket file, `<per-user cache folder>/com.writronic.wherever/wherever.sock`. The per-user cache folder is a private folder that macOS gives your account, usually under `/var/folders/…/C/`. Wherever makes the socket only while the command-line tool is on, and removes it when you click **Uninstall**. Nothing goes over the network.

Only your user account can connect, and Wherever refuses any other account. Any program you run as yourself can ask for file names, as the command does, and those names include the folders Full Disk Access opens. [Your data on this Mac](privacy-and-data.md) and the [privacy policy](../PRIVACY.md) list everything Wherever stores.

## Related

- [Search syntax](search-syntax.md)
- [Settings](settings.md)
- [Getting started](getting-started.md)
- [Troubleshooting and FAQ](troubleshooting.md)
