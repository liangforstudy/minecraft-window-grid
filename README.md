# minecraft-window-grid

Tiles every running Minecraft window into a neat grid on your main screen, for watching several
clients (bots, alt accounts, test instances) at once on Windows.

| Windows open | Layout |
|---|---|
| 1–4 | quarters (2×2) |
| 5–6 | 3×2 |
| 7–9 | 3×3 |
| more | the grid keeps growing (4×3, 4×4, ...) |

## Features

- **Same instance, same slot.** Every Minecraft window has the same title, so windows are found by
  their Java process instead. Each process is matched to its [Prism Launcher](https://prismlauncher.org/)
  instance from its command line, and slots are filled in instance order (or the order you give).
- **Display scaling just works.** The script runs per-monitor DPI aware, so 125% or 150% scaling
  doesn't shrink or offset the grid. Monitor positions are read from Windows, not hard-coded.
- **Frames meet edge to edge.** Windows' invisible resize borders are compensated for.
- **Stays above the taskbar** by default, and leaves a second screen free.
- **One file, nothing to install.** A `.cmd` that runs the PowerShell inside it; double-click it.

## Usage

Start your Minecraft instances, then double-click `tile-windows.cmd`, or run it from a terminal:

```bat
tile-windows.cmd                          :: tile
tile-windows.cmd -List                    :: only show the monitors and windows found
tile-windows.cmd -CoverTaskbar            :: use the whole screen; the bottom row goes under the taskbar
tile-windows.cmd -SecondScreen            :: 4 quarters on the main screen, the 5th maximized on the second
tile-windows.cmd -Order 'Bot 2','Bot 3'   :: put these instances first (Prism display names)
```

| Option | Default | |
|---|---|---|
| `-List` | | show what was found, move nothing |
| `-CoverTaskbar` | off | tile over the whole main screen, not just the work area |
| `-SecondScreen` | off | first 4 windows in quarters, the 5th maximized on the second monitor |
| `-Order <names>` | | these instances take the first slots, in this order |
| `-ProcessName <names>` | `javaw`, `java` | the processes to look for |
| `-WindowClass <class>` | `GLFW30` | the game window's class (LWJGL/GLFW); falls back to the process's biggest window |

Windows beyond the last slot are left where they are, with a warning.

## Requirements

- Windows 10 (1703) or later, with Windows PowerShell 5.1 (built in)
- Minecraft Java Edition. Prism Launcher is only needed for the instance names and stable slot
  order; other launchers' windows are still tiled, labelled by process id.

## License

[MIT](LICENSE)
