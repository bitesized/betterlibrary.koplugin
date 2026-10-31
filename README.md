# Better library

A KOReader plugin that adds a file browser display mode with large covers
that still shows the title, author, reading progress and the other details
the detailed list gives you. There are four layouts to choose from.

## Using it

In the file browser: **top menu → file browser tab → Display mode →
Large covers with details.** Pick the layout under **Display mode → Large
cover layout**:

* **A · Big list** -- three books a page, a large cover on the left and the
  title, author, series, file details, progress and when you last read it on
  the right.
* **B · Two-up cards** -- a 2 × 2 grid of covers with the title, author and
  progress underneath each.
* **C · Captioned mosaic** -- a 3 × 2 grid of covers, captioned with the
  title, author, page count and progress.
* **D · Feature list** -- two books a page, with the start of each book's
  description, a progress bar, the pages left and when you last read it.

In A, B and C, a small **(i)** button next to the title opens the book's
full description, with a button to start or continue reading. Turn it off
with **Large cover layout → Show info button**. (D shows the description
already, so it has no button.)

Picking any of the other display modes switches large covers off again.

## Requirements and limitations

* The **Cover browser** plugin must be enabled: this mode uses its database
  of book information and covers, and its menu. If it is disabled, this
  plugin does nothing.
* Only the file browser gets the large covers. History and Collections keep
  whatever mode you set for them in Cover browser.
* While large covers are on, Cover browser itself is in classic mode
  underneath, so "Use this mode everywhere" would set History and Collections
  to classic.

## Installing

Download the zip from the [latest
release](https://github.com/bitesized/betterlibrary.koplugin/releases/latest)
and unpack it into KOReader's `plugins/` folder (on a Kobo,
`.adds/koreader/plugins/`), then restart KOReader.

The directory **must** be named `betterlibrary.koplugin`: KOReader only
looks at directories whose name ends in `.koplugin`, and silently ignores
everything else. The release zip already has the name right. GitHub's own
"Download ZIP" button does not -- it gives you `betterlibrary.koplugin-main`,
which KOReader will not load until you rename it.

## How it works

The mode is saved as the plugin's own settings (`betterlibrary_enabled`,
`betterlibrary_layout` and `betterlibrary_info_button`), with Cover
browser's file browser mode set to classic. The plugin wraps Cover browser's
`setupFileManagerDisplayMode` and, when large covers are on, points
`FileChooser` at Cover browser's `CoverMenu` for the item updating and
background extraction, and at its own `_recalculateDimen` and
`_updateItemsBuildUI` (in `largecovermenu.lua`) for the layout. The menu
entries are added by wrapping Cover browser's `addToMainMenu`.
