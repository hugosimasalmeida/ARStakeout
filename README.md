# ARStakeout

AR verification tool for GNSS / manual land surveys. Companion to the Android
**GNSS Survey** app, built for iPhone 15 Pro (ARKit + LiDAR).

## What the app does

After you survey a polygon — whether by RTK or entirely by hand with a tape and
compass — ARStakeout lets you walk the plot and **see your surveyed corners as
virtual stakes** overlaid on the camera view, so you can confirm the geometry
against the physical marks on the ground.

It anchors itself using **two corners of your own survey**, so the check is of
the *relative geometry* (your tape measurements and bearings) and works even if
the polygon has several metres of absolute position error. No GPS, no internet —
everything runs locally, usable under tree canopy.

### Key features

- **Import KML** exported by the Android GNSS Survey app.
- **Two-point anchoring:** stand on corner 1 → "Anchor"; walk to corner 2 →
  "Align". This fixes position and rotation without relying on the compass.
- **Scale check:** on aligning, it compares the distance walked (measured by
  ARKit) against the map distance between the two corners and shows the
  difference — an instant consistency check of your tape work.
- **Colored stakes by proximity:** green < 0.3 m, yellow 0.3–1 m, red > 1 m.
- **Arrow + distance** to the nearest corner, always on screen.
- **Re-anchor** at each confirmed corner to cancel the AR drift that builds up
  as you walk (~0.5–1% of distance).
- **Log deviations** per corner and export them as **CSV** to attach to a report
  or import back into the Android app's comparison layer.

### Field workflow

1. Android (GNSS Survey) exports a KML → send it to the iPhone (e-mail / Drive).
2. Open ARStakeout → import the KML.
3. Stand on a known corner → **Anchor** → pick its name.
4. Walk to a second known corner → **Align** → read the scale check.
5. Follow the arrow to each corner; compare the virtual stake with the physical
   mark. The distance shown is that corner's deviation. Tap **Log** to record it.
6. Tap **Re-anchor** at each confirmed corner before moving on.
7. Export the deviations CSV when done.

### Limitations

- On steep slopes the stakes assume the anchor's height, so they may appear
  buried or floating; the horizontal distance shown is still correct.
- Low light degrades tracking — walk slowly and re-anchor more often.
- This verifies *relative* geometry. To fix absolute position, capture one RTK
  point at any corner later and translate the whole polygon in the office.

---

## Building the app (no Xcode, no paid account needed)

If you can't run a modern Xcode locally, the app is built free on GitHub's cloud
Macs and installed with Sideloadly using a normal free Apple ID. Full
step-by-step instructions are in the separate guide
**"Guia_App_AR_iPhone"** / **"README_OptionA"**. In short:

1. Put these files in a public GitHub repo (keep the folder structure):
   `project.yml`, `Sources/ARStakeout.swift`, `.github/workflows/build.yml`.
2. The **Actions** tab builds an `ARStakeout.ipa` automatically (5–10 min).
3. Download it from the run's **Artifacts**, then install with Sideloadly.

You do **not** need the paid Apple Developer Program. With a free Apple ID the
app is valid 7 days and re-signs in one minute over Wi-Fi.
