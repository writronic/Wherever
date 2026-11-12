# Privacy Policy

**Last Updated:** November 2026

Wherever is a free, open-source macOS app that finds files on your Mac by name and, in Normal mode, by the words inside them. **Wherever does not collect, store, or transmit any personal data.** The full source code is at [github.com/writronic/Wherever](https://github.com/writronic/Wherever), so you can check these claims.

---

## Data Collection

Wherever does **not** collect personal information, usage analytics, telemetry, crash reports, device identifiers, location data or the contents of your files. No analytics, advertising, or tracking SDKs are included.

---

## Local Data

Wherever keeps these on your Mac, and [Your data on this Mac](docs/privacy-and-data.md) lists every file:

- File indexes: names, folders, sizes and dates, in `~/Library/Application Support/com.writronic.wherever/`
- Open history, which ranks the files you open often higher, in the same folder
- Your settings, in the `com.writronic.wherever` preferences domain
- Copies of archive items you preview, open or drag out, in `~/Library/Caches/com.writronic.wherever/Archives/`: previews are deleted when the archive's window closes, the rest when Wherever next starts
- Archive passwords stay in memory and are never written to disk or logs
- With the command-line tool on: the `~/.local/bin/wherever` link and `PATH` lines in `~/.zshenv`
- With the command-line tool on, any program you run as yourself can ask Wherever for file names, including folders behind Full Disk Access

---

## Network Activity

Wherever includes [Sparkle](https://sparkle-project.org) for optional update checks:

- **Automatically check for updates** in Settings, General is off until you turn it on
- A check connects to `raw.githubusercontent.com`
- A check names Wherever and its version, and sends no system profiling data
- Installing an update downloads it from GitHub Releases

Beyond these, Wherever makes **zero network requests**.

---

## Data Deletion

- **Clear Open History…** in Settings, General deletes the open history
- **Reset** in Settings, General deletes all settings, indexes and open history
- **Uninstall** under Command-Line Tool in Settings, General removes the link, the `~/.zshenv` lines and the socket
- [Remove everything](docs/privacy-and-data.md#remove-everything) lists each folder to delete by hand

---

## Contact

- **GitHub Issues:** [github.com/writronic/Wherever/issues](https://github.com/writronic/Wherever/issues)
