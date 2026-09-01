# Mac Barcode Scanner v1.0

First public release of the native Mac app. Barcodes are read from photos with **Apple Vision** on-device — not in a browser.

Companion to the original web tool: [pardostech.com/BarcodeScanner](https://pardostech.com/BarcodeScanner/)

## Install

Download **BarcodeScanner.app** (or the zip) from this release. The app is ad-hoc signed, not Developer ID / notarized, so macOS will quarantine a browser download.

```bash
xattr -cr ~/Downloads/BarcodeScanner.app
cp -R ~/Downloads/BarcodeScanner.app /Applications/
open /Applications/BarcodeScanner.app
```

If Gatekeeper still blocks it: right-click the app → **Open**, or System Settings → **Privacy & Security** → **Open Anyway**.

## What’s in v1.0

- Apple Vision barcode detection (`VNDetectBarcodesRequest`) on JPEG, PNG, and HEIC
- Multi-pass scan: full image, enhanced, grayscale, slight rotations, tiled crops
- Batch open (images or a folder), numbered overlay lines, click-to-copy
- Repeating-group table for shipping-style labels
- Copy CSV: one row per pattern group; unmatched images get one value per row
- All processing stays on your Mac

**Requires** macOS 13+ on Apple Silicon.

## Asset

Attach: `BarcodeScanner.app` (zipped)

Suggested GitHub tag: `v1.0`
