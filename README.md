# GridDock

A macOS menu-bar window manager. Drag windows into a grid, flip between pages of windows, and keep an eye on your Claude Code sessions, without leaving the keyboard or the mouse.

Requires macOS 14 or later and Accessibility access.

## Features

**Grids**
- Presets (2 × 1, 2 × 2, 3 × 2, 3 × 3, 4 × 2, Main + 2, Main + 4, Center + sides), custom C × R grids, and auto grids sized to however many windows are open.
- Drag a window and the grid appears; drop it on a cell to place it. Clicks on toolbars, tabs and menus never bring up the grid.
- Grid picker (⌃⌥G): press a cell's key to place the focused window, ⇧-click to span several cells.
- Empty cells get filled: a neighbour grows into a gap and shrinks back when another window is dropped there.

**Smart tiling** *(in testing)*
- Every drag or resize rearranges the whole layout, and a live preview shows the frame each window will get before you let go.
- Drop at a screen edge for a full-height column or full-width row, on the gap between two windows to slot in between, on the side of a window to split it, or in its middle to swap the two.
- Drag an edge to move the whole shared boundary (it clicks into ¼, ⅓, ½, ⅔, ¾). Push a neighbour far enough and your window takes the full height, while the neighbour moves in beside the window across from it.
- "Keep a shared grid" sizes columns so their edges line up into one grid.

**Pages**
- Several grids on one desktop: windows of hidden pages are parked off-screen.
- Switch with ⌃⌥← → or ⌥ + two-finger swipe; send a window to another page with ⌃⌥⇧← →.
- Focusing a parked window (⌘-Tab, Dock, notification) switches to its page. Pages survive a restart.

**Arranging**
- Tile all windows (⌃⌥T), arrange everything from every desktop (⌃⌥A), or arrange by project (⌃⌥P), with a page per project folder.
- Auto-arrange mode keeps new windows tiled, up to a set number per page.
- Saved project layouts: which app and window goes where, and Terminal windows that `cd` into a folder and start a command.
- Brings windows over from other desktops and out of fullscreen.

**Claude Code sessions**
- Installs Claude Code hooks that report each session's state.
- Coloured frames around Terminal windows: orange (pulsing) needs you, blue is working, green is done.
- Jump to the next session waiting for you (⌃⌥W).

**Rules**
- Dialogs, small windows, fixed-size windows and listed apps float on top and never take a cell. Edit `rules.json` to change the list.

## Keyboard shortcuts

| Shortcut | Action |
|---|---|
| ⌃⌥G | Grid picker |
| ⌃⌥1 – 9 | Put the focused window in cell 1 – 9 |
| ⌃⌥L | Next layout |
| ⌃⌥T | Tile all windows |
| ⌃⌥A / ⌃⌥P | Arrange everything / by project |
| ⌃⌥← → | Previous / next page |
| ⌃⌥⇧← → | Send window to the previous / next page |
| ⌃⌥N | New page |
| ⌃⌥W | Jump to the next waiting Claude session |
| ⌃⌥D | Overview |
| ⌃⌥H | Show all shortcuts |

## Build and install

```sh
./scripts/build.sh
cp -R build/GridDock.app /Applications/
open /Applications/GridDock.app
```

Then allow GridDock under **System Settings → Privacy & Security → Accessibility**.

`build.sh` signs the app with a code-signing certificate named **GridDock Local** if your login keychain has one, otherwise with a valid Apple Development certificate, otherwise ad-hoc. Use a stable certificate: an ad-hoc signature changes with every build, and macOS then drops the Accessibility permission. To create a self-signed one, make a certificate with `extendedKeyUsage = codeSigning` (for example with OpenSSL) and import it into the login keychain.

Run the tests with `swift test`.

## Good to know

- **macOS's own tiling:** turn off "Drag windows to screen edges to tile" and "Hold ⌥ key while dragging windows to tile" in System Settings → Desktop & Dock. Otherwise macOS and GridDock both try to place the window you drop.
- **Stage Manager:** GridDock arranges the windows of the stage you're looking at. "Arrange everything" asks you to turn Stage Manager off, because it hides other apps' windows.
- **Logs:** `~/Library/Logs/GridDock.log`.
