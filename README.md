# Keyence BZ-X1000 Stitcher for Fiji

`keyence_stitch.ijm` is a Fiji macro that stitches tiled captures from the Keyence BZ-X1000 into
one calibrated multichannel image per section. It reads the tile layout that the Keyence software
saves in each section's `.gci` file, refines the tile positions on the DAPI channel, and fuses all
channels at those positions in a single pass, so the channels stay registered to each other.

It processes a whole animal, slide or single section in one run, never writes into the raw data
folders, and can be re-run safely: finished sections are skipped.

---

## Requirements

| Component | Version | Why |
| --- | --- | --- |
| **Fiji** (not plain ImageJ) | ImageJ 1.54 or later inside Fiji; tested with 1.54p | Script parameters (`#@`), Bio-Formats and the Stitching plugin all ship with Fiji |
| Bio-Formats | Bundled with Fiji | Reads the Keyence `.bz.ome.tif` tiles |
| Grid/Collection Stitching (Preibisch et al.) | Bundled with Fiji | Registration and fusion |
| `tar` on the system path | Built into macOS and Windows 10 or later | Unpacks the `.gci` file, which is a zip archive |
| Keyence data | BZ-X1000 Viewer, multipoint/stitching capture | Raw `.bz.ome.tif` tiles plus the `.gci` file, as saved by the Viewer |

**Why plain ImageJ does not work:** ImageJ 1.x on its own has no SciJava script parameters (the
input dialog), no Bio-Formats and no Stitching plugin. Fiji includes all three.

**Linux:** GNU `tar` cannot read zip archives. The macro runs on Linux only if `tar` on the path is
`bsdtar` (package `libarchive-tools`). It has been tested on macOS (Apple Silicon).

**Memory:** a 5 × 5-tile section at 10× fuses to about 7,000 × 5,200 px × 2 channels. Give Fiji at
least 8 GB under `Edit › Options › Memory & Threads`.

Keep Fiji current with `Help › Update…`. No extra update sites are needed.

---

## Input: what the macro expects

The Keyence Viewer writes one folder per captured section (one XY position):

```text
Slide_1/
  XY01/
    RtTg_XY01.gci                        ← tile layout and stage positions (zip archive)
    RtTg_XY01_00001_CHF.bz.ome.tif       ← tile 1, all channels (used)
    RtTg_XY01_00001_Overlay.bz.ome.tif   ← display overlay (ignored)
    …
    RtTg_XY01_StitchPreview.tif          ← Keyence preview (ignored)
    Preview/                             ← display previews (ignored)
  XY02/
    …
```

- Every `.gci` found anywhere below the input folder defines one section, so the input can be an
  animal folder, a slide folder or a single section folder.
- Tiles must be the `_CHF.bz.ome.tif` files: 8-bit, one file per tile holding all channels.
- Channel 1 is assumed to be DAPI (it is used for registration and coloured blue). Every other
  channel is coloured green. The macro was built for DAPI + one fluorophore.
- Single focal plane only; Z-stacks are not supported.

---

## Installation

1. Save `keyence_stitch.ijm` anywhere, or, to get a menu entry, copy it into
   `Fiji.app/scripts/Plugins/Keyence/` as `Keyence_Stitch.ijm` (the underscore is required) and
   restart Fiji. On macOS, right-click `Fiji.app` › *Show Package Contents* to reach that folder.
2. It then appears under **Plugins › Keyence › Keyence Stitch**.

---

## Running it

1. Open the macro (drag it onto the Fiji toolbar, or use the menu entry above) and click **Run**.
2. Fill in the dialog:

| Field | What to enter |
| --- | --- |
| Input folder | Animal, slide or section folder (read only; never written to) |
| Output folder | Where results go; must be **outside** the input folder |
| Work folder | Temporary tiles; use a fast **local** disk, not the external drive; must be outside the input folder |
| DAPI channel | `1` for the standard DAPI + GFP acquisition |
| Fallback overlap % | Used only if the `.gci` stage positions look wrong; `30` matches the usual capture setting |
| Fusion | `Linear Blending` (default) smooths seams; keep it unless you have a reason not to |
| Skip sections whose composite already exists | On: re-runs only process new sections |
| Delete work files after each section | On: frees disk space as it goes |

3. Do not click on image windows while it runs. The macro works on whichever image is active.
4. Progress is printed in the Log window, which is saved to the output folder at the end.

**Test on one section first.** Point the input at a single `XY` folder, open the result, and
compare it with Keyence's `_StitchPreview.tif` before running a whole animal.

---

## Output

The output folder mirrors the input tree. For input `ID9750 (RtTg)` containing `Slide_1/XY01`:

```text
<output>/
  Slide_1/
    RtTg_XY01_composite.tif   ← 2-channel composite, calibrated in µm (for analysis)
    RtTg_XY01_RGB.png         ← flattened colour image (for viewing and slides)
  stitch_log_20261016-1139.txt
```

| File | Use it for | Do not use it for |
| --- | --- | --- |
| `_composite.tif` | Fiji, QuPath, ABBA, any measurement | Preview, PowerPoint: they show only channel 1, in the wrong colour |
| `_RGB.png` | Viewing, slides, figures drafts | Quantification: channels are merged and contrast is baked in |

Open the composite in Fiji with **File › Open**. The Bio-Formats importer with default settings
may ignore the saved channel colours (the data are unaffected).

---

## How it works

1. **Find sections.** Every `.gci` below the input folder is one section.
2. **Read the layout.** The `.gci` is unpacked into the work folder. It lists each tile with its
   grid row and column, plus the stage coordinates of the first and last grid positions.
3. **Prepare tiles.** Each `_CHF` tile is opened with Bio-Formats and saved twice: DAPI only, and
   all channels, under the same name.
4. **Initial positions.** Tile position = grid index × stage step, with the step converted from
   stage nanometres to pixels using the tile's pixel size. Tiles skipped by Keyence's Auto
   Navigation are handled automatically, because positions come from grid indices, not a full grid.
5. **Register on DAPI.** Grid/Collection Stitching refines the positions by phase correlation
   between overlapping DAPI tiles and a global optimization (no image is built at this stage).
6. **Fuse.** The multichannel tiles are fused once at the DAPI-registered positions, so all channels
   share one canvas.
7. **Save.** Channel colours and pixel size are set, the composite and the RGB PNG are written, and
   the work files are deleted.

---

## Checking the results

In the saved log, each section reports its tile count, grid and computed overlap, e.g.

```text
RtTg_XY01: 25 tiles, grid 5 x 5, overlap 30.2% x 29.6%
  fused: 6977 x 5236 px, 2 channels
```

- An overlap far from the capture setting, or a "stage step implausible" line, means the fallback
  overlap was used for that section: inspect it.
- A tile count lower than expected means files are missing from the section folder.
- Look for seams or doubled cells at tile borders in sparse regions.

---

## Troubleshooting

| Message or symptom | Cause | Fix |
| --- | --- | --- |
| `Unrecognized command: "Grid/Collection stitching"` | Plain ImageJ, or outdated Fiji | Use Fiji; run `Help › Update…` |
| `could not unpack …gci` | `tar` not found or cannot read zip | macOS/Windows: check `tar --version` in a terminal; Linux: install `bsdtar` |
| `missing tile …` | A tile listed in the `.gci` is not in the folder | Re-copy the section from the acquisition computer |
| `No .gci files found` | Wrong input folder, or files not from the BZ-X1000 Viewer | Point the input at the folder above the `XY` folders |
| `Output and work folders must be outside the input folder` | Output or work folder chosen inside the data | Choose folders elsewhere |
| Both channels green in Fiji | Opened with Bio-Formats default colour mode | Open with **File › Open** |
| Only one green channel in Preview/PowerPoint | Multichannel TIFF limitation | Use the `_RGB.png` |
| A section was not re-processed | Its composite already exists and skipping is on | Delete that composite, or turn skipping off |
| Run stopped mid-way | Any error above | Delete that section's folder in the work folder, then re-run; finished sections are skipped |

---

## Citation

If you use the stitched images in a publication, cite the stitching plugin:

Preibisch S, Saalfeld S, Tomancak P (2009). Globally optimal stitching of tiled 3D microscopic
image acquisitions. *Bioinformatics* 25(11):1463–1465.

And Fiji: Schindelin J, et al. (2012). Fiji: an open-source platform for biological-image analysis.
*Nature Methods* 9(7):676–682.

Created with Claude
