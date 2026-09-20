# Cell borders: experimental Ghostty protocol

Paint independently colored lines on the edges and center of terminal cells, including empty
cells. Text keeps its own foreground and background. Borders add decoration without consuming
character positions and scale with the terminal's cell geometry.

This is a proof of concept adapted from Joshka's Rio experiment, not a registered or interoperable
standard. The aim is to try compact panels, text fields, tables, buttons, and quadrant outlines.
The commands, storage, and behavior may change after experimentation.

## Wire format

Commands use DCS (`ESC P … ESC \`). The header has version parameter `1`, intermediate byte `+`,
and final byte `b`. The payload starts with the literal namespace `ghostty-border;`.
Both the header and namespace must match. This identifier is provisional; valid DCS framing does
not constitute an allocation or guarantee that every other terminal will ignore the sequence.

```text
ESC P 1 + b ghostty-border;set;MASK;WIDTH;RRGGBB;PLACEMENT;LAYER;ROWS;COLS ESC \
ESC P 1 + b ghostty-border;clear;MASK;ROWS;COLS ESC \
ESC P 1 + b ghostty-border;q ESC \
```

Spaces above separate notation only. No whitespace appears in the actual command. Use the
7-bit introducer and ST terminator shown here.

The query reply is `ESC P 1 + b ghostty-border;ok ESC \`. Set and clear have no reply. Query while
an input handler is active; use ordinary text/Unicode borders if no reply arrives. A timeout
means support was not established, which may also mean an intermediary filtered the command.
The interactive demo queries by default; `--no-query` skips detection for manual experiments.

| Field | Values |
| --- | --- |
| `MASK` | Bitwise OR of segment bits, decimal `1..4095`. See masks below. |
| `WIDTH` | Decimal `1..32`, in 1/256 of cell width, rounded to at least one device pixel. |
| `RRGGBB` | Exactly six hexadecimal digits; opaque RGB independent of text colors. |
| `PLACEMENT` | `0`: inside the cell; `1`: centered on the outer edge. |
| `LAYER` | `0`: below text; `1`: above text. Both are above cell backgrounds. |
| `ROWS`, `COLS` | Decimal `1..65535`; cursor-anchored rectangle clipped to the active screen. |

Set replaces selected segments on **every cell** in the rectangle. It does not draw just the
rectangle's perimeter. Use four one-cell-thick strips for a panel outline; the demo's `outline`
helper does this. Clear removes only selected segments. Neither command moves the cursor nor
changes text or the current SGR attributes. Coordinates start at the cursor's physical cell;
scrolling margins do not further clip the painted rectangle.

Each segment retains its own width, color, placement, and layer. Numeric fields have no signs.
Unknown versions/namespaces and malformed commands are ignored. Payloads over 256 bytes are
ignored. A valid command is parsed before painting begins; allocation or style-table exhaustion
can leave a rectangle partially painted.

## Full sides first

The common cases use these masks. The Python helpers expose the names, so applications need
not assemble the half-edge bits manually.

| Name | Decimal mask | Meaning |
| --- | --- | --- |
| `TOP` | 3 | Complete top edge |
| `RIGHT` | 12 | Complete right edge |
| `BOTTOM` | 48 | Complete bottom edge |
| `LEFT` | 192 | Complete left edge |
| `OUTLINE` | 255 | All four outer edges |
| `HORIZONTAL` | 768 | Complete horizontal centerline |
| `VERTICAL` | 3072 | Complete vertical centerline |
| `ALL` | 4095 | All segments; useful for clearing |

For example, add a teal top edge across 20 cells starting at row 4, column 8:

```python
print("\x1b[4;8H\x1bP1+bghostty-border;set;3;16;80c5b7;0;1;1;20\x1b\\", end="")
```

The demo helpers provide equivalent calls and combine masks with `|`:

```python
border(4, 8, TOP, color="80c5b7", cols=20)
border(4, 8, TOP | BOTTOM, color="80c5b7", cols=20)
outline(4, 8, rows=3, cols=20, color="80c5b7")
```

## Half edges and center arms

Twelve primitive segments cover a cell divided into quadrants. Full edges and centerlines are
combinations of two primitives, not separate slots. Setting `TOP`, then setting `TOP_LEFT`,
changes only the left half on the second operation. Clearing `TOP` removes both halves.

```text
                 TOP_LEFT       TOP_RIGHT
              +--------------+--------------+
     LEFT_TOP |              |              | RIGHT_TOP
              |            V_TOP            |
              +--- H_LEFT ---+--- H_RIGHT ---+
              |          V_BOTTOM           |
  LEFT_BOTTOM |              |              | RIGHT_BOTTOM
              +--------------+--------------+
                BOTTOM_LEFT    BOTTOM_RIGHT
```

| Segment | Bit | Decimal mask |
| --- | --- | --- |
| `TOP_LEFT` | 0 | 1 |
| `TOP_RIGHT` | 1 | 2 |
| `RIGHT_TOP` | 2 | 4 |
| `RIGHT_BOTTOM` | 3 | 8 |
| `BOTTOM_LEFT` | 4 | 16 |
| `BOTTOM_RIGHT` | 5 | 32 |
| `LEFT_TOP` | 6 | 64 |
| `LEFT_BOTTOM` | 7 | 128 |
| `H_LEFT` | 8 | 256 |
| `H_RIGHT` | 9 | 512 |
| `V_TOP` | 10 | 1024 |
| `V_BOTTOM` | 11 | 2048 |

To outline the filled upper-left quadrant of `▘`, select
`TOP_LEFT | LEFT_TOP | H_LEFT | V_TOP` (mask `1345`). The other quadrants use the corresponding
outer halves and center arms. This prototype does not subdivide into sextants or octants.

## Geometry and layering

Both horizontal and vertical thickness use cell width, so equal widths have equal pixel thickness
regardless of the cell's aspect ratio. Small widths may round to the same one-pixel result.
Cell centers are rounded to integer pixels. Half segments overlap around their meeting point to
avoid holes at corners; joints are rectangular. On odd pixel widths a centered stroke can be
asymmetric by one pixel. Center arms stay centered regardless of `PLACEMENT`.

Centered outer edges may extend into neighboring cells; the viewport clips overflow. Rendering
orders all below-text borders before text, then all above-text borders after text, across rows.
Within each border layer, rows run top-to-bottom, cells left-to-right, and segments in bit order;
later strokes cover earlier ones. Shared edges are not merged. Prefer one owning cell for a shared
edge unless overlap is intentional. Non-block cursors render above borders; block cursors precede
text and above-text borders. Kitty image layers retain their existing relative placement.

## Lifetime and prototype boundaries

Borders belong to physical cells, including the two cells occupied by a wide character. Normal
cell overwrite and erasure clear borders, including writing a space. Paint text first, then
borders. Incremental TUI backends must repaint borders on cells whose text they overwrite even
when the desired border style did not change. SGR reset alone leaves painted borders unchanged.

Borders follow ordinary cell moves and scrolling. Alternate screens keep separate cell contents.
Font changes recalculate pixel geometry. Grid resizing follows cell reflow; it does not preserve
the shape of a panel or re-layout the application. Blank cells with borders count as nonempty for
reflow. Copying text does not add border characters.

The prototype keeps up to 65,535 unique combinations of segment styles per terminal. IDs are
interned and retained until the terminal is destroyed, even after clearing borders. Exhaustion
stops further new styles. This is a bounded shortcut, not a proposed production storage design.

Saved terminal snapshots and text/style serialization do not preserve borders. The public C API
does not expose border geometry. Selection, concealment, inverse, and faint text attributes do
not recolor or hide borders. Advanced editing, replay, multiplexer interoperability, accessibility,
and pathological resize cases have not received a full compatibility audit. There is no arbitrary
z-index, alpha, rounded corner, dash pattern, sticky border pen, or extensible subdivision scheme.

## Try it

On macOS, build the native app from this workspace:

```sh
zig build -Doptimize=ReleaseFast -Dxcframework-target=native
```

Open the resulting app bundle in `zig-out/Ghostty.app`, then run the script inside it:

```sh
python3 scripts/cell-borders.py
```

The demo expects at least 88 columns by 42 rows. Controls:

- `b`: toggle borders for comparison.
- `p`: inside versus centered placement; `w` changes width.
- `c`: RGB brightness and independently colored button edges.
- `h`: quadrant/half-block buttons.
- `j`: offset header/content/status dividers and T-junctions.
- `e`: half outer edges outlining each quadrant.
- `l`: incremental text field and popup experiment.
- `q` or Escape: quit the gallery.

In the live view, type to edit, Backspace to delete, Tab to toggle border repainting, and Ctrl+P
to show/hide a popup. Escape returns to the gallery; Ctrl+C exits. Disabling repainting deliberately
shows borders disappearing when text overwrites them. The demo restores screen and terminal input
settings on exit.

Use `--placement`, `--colors`, `--blocks`, `--junctions`, `--halves`, or `--live` to start directly
in a view. To emit a frame without input or alternate-screen handling:

```sh
python3 scripts/cell-borders.py --halves --emit > /tmp/cell-borders.ansi
cat /tmp/cell-borders.ansi
```

The same script accepts `--protocol rio` for the original APC-based Rio prototype. It translates
the full-edge and center-arm masks, allowing scene comparisons. Half outer edges require Ghostty.
Only select Rio mode inside the matching experimental Rio build; the protocols are not compatible.

## Prior art

[DECterm ruled lines](https://ftp.zx.net.nz/rom/V4.0D_D1/DOCS/HTML/AQ0R4CTE/DOCU_006.HTM)
provide cell-boundary drawing without text characters. Their perimeter operation and mixed
lifetime differ: erasing text preserves lines, while line insertion/deletion moves them.
[C-Kermit for Windows](https://github.com/davidrg/ckwin/pull/500) implements this precedent.

[Rio's proof of concept](https://github.com/raphamorim/rio/pull/1947) supplied the starting model
and gallery. This experiment changes the framing to DCS, splits outer edges as well as centerlines,
and gives the two border layers consistent ordering across rows. These are experimental choices,
not a claim of novelty or an agreed terminal standard.
