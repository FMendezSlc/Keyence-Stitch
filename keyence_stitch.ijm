// Stitch Keyence BZ-X1000 tiled captures in Fiji.
// Tile layout comes from each section's .gci; tile positions are refined on DAPI alone by
// phase correlation, then all channels are fused in a single pass at those positions.
//
// Directories (all independent; the input tree is only read, never written):
//   Input  : any folder above the sections (animal, slide, or one section). Every .gci found
//            below it defines one section; its folder must hold <name>_NNNNN_CHF.bz.ome.tif
//            (8-bit, 2 channels per tile). Overlay tiles, _StitchPreview.tif, Preview/ are ignored.
//   Output : <output>/<path relative to input>/<name>_composite.tif (all channels, calibrated;
//            for QuPath/ABBA/analysis) and <name>_RGB.png (channels flattened to colour, for
//            viewing in Preview, PowerPoint, etc.; not for quantification)
//            plus stitch_log_<timestamp>.txt at the output root.
//   Work   : <work>/<path relative to input>/<name>/ (unpacked .gci, DAPI and multichannel
//            tiles, tile configurations). Put it on a fast local disk; optionally deleted.
// Requires `tar` on the PATH to unpack the .gci (a zip archive): built into macOS and Windows 10+.

#@ File (label = "Input folder (searched recursively for .gci)", style = "directory") inRoot
#@ File (label = "Output folder", style = "directory") outRoot
#@ File (label = "Work folder (temporary tiles)", style = "directory") workRoot
#@ Integer (label = "DAPI channel in _CHF tiles (registration)", value = 1) dapiCh
#@ Integer (label = "Fallback overlap % (used only if the .gci stage step is implausible)", value = 30) overlap
#@ String (label = "Fusion", choices = {"Linear Blending", "Max. Intensity", "Average"}) fusion
#@ Boolean (label = "Skip sections whose composite already exists", value = true) skipDone
#@ Boolean (label = "Delete work files after each section", value = true) cleanup

inRoot   = asDir(inRoot);
outRoot  = asDir(outRoot);
workRoot = asDir(workRoot);
if (startsWith(outRoot, inRoot) || startsWith(workRoot, inRoot))
    exit("Output and work folders must be outside the input folder.");

common = " subpixel_accuracy regression_threshold=0.30" +
         " max/avg_displacement_threshold=2.50 absolute_displacement_threshold=3.50" +
         " computation_parameters=[Save computation time (but use more RAM)] image_output=[Fuse and display]";

print("\\Clear");
print("Input : " + inRoot);
print("Output: " + outRoot);
print("Work  : " + workRoot);

gciList = findGcis(inRoot);
if (gciList == "") exit("No .gci files found under " + inRoot);
gcis = split(gciList, "\n");
print(gcis.length + " section(s) found");
for (s = 0; s < gcis.length; s++) stitchSection(gcis[s]);

getDateAndTime(yr, mo, dw, dy, hr, mi, sc, ms);
stamp = "" + yr + IJ.pad(mo + 1, 2) + IJ.pad(dy, 2) + "-" + IJ.pad(hr, 2) + IJ.pad(mi, 2);
print("Done");
selectWindow("Log");
saveAs("Text", outRoot + "stitch_log_" + stamp + ".txt");


function stitchSection(gci) {
    secDir  = File.getDirectory(gci);
    name    = File.getNameWithoutExtension(gci);
    rel     = substring(secDir, lengthOf(inRoot));                 // "Slide_1/XY01/", or "" if input is the section
    relUp   = "";                                                  // parent of the section folder
    if (rel != "") {
        r = substring(rel, 0, lengthOf(rel) - 1);
        relUp = substring(r, 0, lastIndexOf(r, "/") + 1);
    }
    outDir  = outRoot + relUp;
    workDir = workRoot + rel + name + "/";
    composite = outDir + name + "_composite.tif";
    if (skipDone && File.exists(composite)) {
        if (!File.exists(outDir + name + "_RGB.png")) {         // composites from earlier runs
            open(composite);
            saveRGB(outDir + name);
            close("*");
            print(name + ": already stitched, RGB preview added");
        } else print(name + ": already stitched, skipped");
        return;
    }
    gciDir  = workDir + "gci/";
    dapiDir = workDir + "dapi/";
    allDir  = workDir + "all/";
    makeDirs(outDir);
    makeDirs(gciDir);
    makeDirs(dapiDir);
    makeDirs(allDir);

    // --- Tile grid from the .gci ----------------------------------------------------------
    exec("tar", "-xf", gci, "-C", gciDir);
    prop = gciDir + "GroupFileProperty/";
    listDir = prop + "ImageList/OmeFileList/";
    if (!File.exists(listDir + "properties.xml")) exit(name + ": could not unpack " + gci);

    nList = parseInt(tag(File.openAsString(listDir + "properties.xml"), "Count"));
    tiles = newArray(0); rows = newArray(0); cols = newArray(0);
    for (i = 0; i < nList; i++) {
        xml = File.openAsString(listDir + "Index" + i + "/properties.xml");
        fp = tag(xml, "FilePath");
        if (indexOf(fp, "_CHF") < 0) continue;                  // skip Overlay entries
        tiles = Array.concat(tiles, fp);
        rows  = Array.concat(rows, parseInt(tag(xml, "IndexRow")));
        cols  = Array.concat(cols, parseInt(tag(xml, "IndexColumn")));
    }
    n = tiles.length;
    if (n == 0) { print(name + ": no _CHF tiles listed in .gci, skipped"); return; }

    // EdgePoint0/1 = stage XY (nm) of the first and last grid positions
    joint = prop + "ImageJoint/";
    jointXml = File.openAsString(joint + "properties.xml");
    gridRows = parseInt(tag(jointXml, "Row"));
    gridCols = parseInt(tag(jointXml, "Column"));
    e0 = File.openAsString(joint + "EdgePoint0/properties.xml");
    e1 = File.openAsString(joint + "EdgePoint1/properties.xml");
    spanX = abs(parseFloat(tag(e1, "X")) - parseFloat(tag(e0, "X")));
    spanY = abs(parseFloat(tag(e1, "Y")) - parseFloat(tag(e0, "Y")));

    // --- Per tile: DAPI-only copy (registration) and all-channel copy (fusion), same name ---
    tileNames = newArray(n);
    setBatchMode(true);
    for (k = 0; k < n; k++) {
        if (!File.exists(secDir + tiles[k])) exit(name + ": missing tile " + tiles[k]);
        run("Bio-Formats Importer", "open=[" + secDir + tiles[k] + "] color_mode=Default view=Hyperstack stack_order=XYCZT");
        if (k == 0) {
            W = getWidth(); H = getHeight();
            getPixelSize(unit, pw, ph);
        }
        tileID = getImageID();
        tileNames[k] = replace(tiles[k], "\\.bz\\.ome\\.tif$", ".tif");
        saveChannel(dapiCh, dapiDir + tileNames[k]);
        selectImage(tileID);
        saveAs("Tiff", allDir + tileNames[k]);
        close("*");
    }
    setBatchMode(false);

    // --- Initial positions: grid index x stage step (px), refined on DAPI ----------------
    stepX = stageStep(spanX, gridCols, pw, W);
    stepY = stageStep(spanY, gridRows, ph, H);
    print(name + ": " + n + " tiles, grid " + gridRows + " x " + gridCols +
          ", overlap " + d2s(100 * (1 - stepX / W), 1) + "% x " + d2s(100 * (1 - stepY / H), 1) + "%");

    cfg = "dim = 2\n";
    for (k = 0; k < n; k++)
        cfg = cfg + tileNames[k] + "; ; (" + d2s(cols[k] * stepX, 2) + ", " + d2s(rows[k] * stepY, 2) + ")\n";
    File.saveString(cfg, dapiDir + "TileConfiguration.txt");

    // Pass 1: register on DAPI only; writes TileConfiguration.registered.txt, no fusion
    run("Grid/Collection stitching", "type=[Positions from file] order=[Defined by TileConfiguration]" +
        " directory=[" + dapiDir + "] layout_file=TileConfiguration.txt compute_overlap" +
        " fusion_method=[Do not fuse images (only write TileConfiguration)]" + common);

    // Pass 2: fuse all channels at once at the DAPI-registered positions
    File.copy(dapiDir + "TileConfiguration.registered.txt", allDir + "TileConfiguration.registered.txt");
    run("Grid/Collection stitching", "type=[Positions from file] order=[Defined by TileConfiguration]" +
        " directory=[" + allDir + "] layout_file=TileConfiguration.registered.txt" +
        " fusion_method=[" + fusion + "]" + common);
    getDimensions(fw, fh, nCh, nSl, nFr);
    print("  fused: " + fw + " x " + fh + " px, " + nCh + " channels");
    for (c = 1; c <= nCh; c++) {
        Stack.setChannel(c);
        if (c == dapiCh) run("Blue"); else run("Green");
        resetMinAndMax();
    }
    setVoxelSize(pw, ph, 1, unit);
    saveAs("Tiff", composite);
    saveRGB(outDir + name);
    close("*");

    if (cleanup) deleteTree(workDir);
    print("  -> " + outDir);
}


// Stage step between adjacent tiles in pixels; falls back to the overlap setting if the
// .gci span is missing or implies an overlap outside 0-60 %.
function stageStep(spanNm, nTiles, pixelUm, sizePx) {
    fallback = sizePx * (1 - overlap / 100);
    if (nTiles < 2 || spanNm <= 0) return fallback;
    step = spanNm / 1000 / pixelUm / (nTiles - 1);
    if (step < 0.4 * sizePx || step > sizePx) {
        print("  stage step " + d2s(step, 1) + " px implausible for " + sizePx + " px tiles; using " + overlap + "% overlap");
        return fallback;
    }
    return step;
}

// Flatten the active composite to RGB with its channel colours and display ranges.
// ImageJ's multichannel TIFF stores channels as grayscale pages with a single palette, so
// non-ImageJ viewers show only page 1 in the last-set colour.
function saveRGB(base) {
    run("RGB Color");                                         // opens a new RGB image
    saveAs("PNG", base + "_RGB.png");
}

function saveChannel(c, outPath) {
    run("Duplicate...", "title=ch duplicate channels=" + c);
    saveAs("Tiff", outPath);
    close();
}

// Newline-separated paths of all .gci files below dir (Preview/ folders are not searched).
// Returns a string: an empty array returned from a recursive call is read as 0 by Array.concat.
function findGcis(dir) {
    found = "";
    files = getFileList(dir);
    for (i = 0; i < files.length; i++) {
        if (endsWith(files[i], "/")) {
            if (files[i] != "Preview/") found = found + findGcis(dir + files[i]);
        } else if (endsWith(files[i], ".gci")) found = found + dir + files[i] + "\n";
    }
    return found;
}

// Normalized directory path: forward slashes, trailing slash
function asDir(path) {
    path = replace(path, "\\\\", "/");
    if (!endsWith(path, "/")) path = path + "/";
    return path;
}

function makeDirs(dir) {
    if (File.isDirectory(dir)) return;
    makeDirs(File.getParent(dir));
    File.makeDirectory(dir);
}

// Text content of the first <name ...>...</name> element
function tag(xml, name) {
    i = indexOf(xml, "<" + name + " ");
    if (i < 0) i = indexOf(xml, "<" + name + ">");
    if (i < 0) return "";
    i = indexOf(xml, ">", i) + 1;
    return substring(xml, i, indexOf(xml, "</" + name + ">", i));
}

function deleteTree(dir) {
    files = getFileList(dir);
    for (i = 0; i < files.length; i++) {
        if (endsWith(files[i], "/")) deleteTree(dir + files[i]);
        else ok = File.delete(dir + files[i]);
    }
    ok = File.delete(dir);
}
