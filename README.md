# Mac Barcode Scanner

A native macOS app for reading barcodes from **photos** — JPEG, PNG, and HEIC — using **Apple Vision** on-device. Batch a folder of labels, overlay numbered lines on every code, and copy a structured CSV.

This is the Mac companion to the original browser tool:

**[Barcode Scanner on Pardo’s Tech](https://pardostech.com/BarcodeScanner/)**

The web version runs in the browser. This version is a local `.app` that uses Apple’s Vision framework (plus ImageIO for HEIC) so detection stays on your Mac — no upload, no camera webpage, no internet required.

## Why Apple Vision

Safari and other browsers are limited with dense labels, HEIC files, and batches of 20–200 images. Mac Barcode Scanner uses `VNDetectBarcodesRequest` on the real image pixels:

- **On-device** — Vision runs locally through the Vision framework
- **HEIC** — ImageIO reads HEIC without a manual convert-to-JPEG step
- **Passes** — full image, contrast-enhanced, grayscale, slight rotations, and tiled crops so small or skewed codes still get a hit
- **Symbologies** — Code 128, Code 39, Code 93, EAN-8, EAN-13, UPC-E, QR, PDF417, Aztec, Data Matrix, Codabar
- **Light OCR assist** — Vision text recognition can fill a missed serial-style code when the barcode itself is hard to lock

## Features

- Open many images or a folder (⌘O); add more while a batch is still scanning
- Numbered overlay lines that follow each barcode’s orientation — click a line to copy
- Repeating-group table for shipping-style labels (misc fields, then Pattern 1 / Pattern 2 / …)
- **Copy CSV** for the whole batch:

  ```text
  Filename,Misc1,Misc2,Pattern1,Pattern2,...
  LABEL_0001.HEIC,<misc>,<misc>,<group 1>,...
  LABEL_0001.HEIC,<misc>,<misc>,<group 2>,...
  LABEL_0002.HEIC,<value>
  ```

  One row per repeating group; filename and misc columns repeat. Images with no pattern get **one value per row**.

## Requirements

- macOS 13 or later
- Apple Silicon (the bundled `build.sh` targets `arm64-apple-macos13.0`)
- Xcode Command Line Tools (`swiftc`) if you build from source

## Install the `.app`

The release build is ad-hoc signed (not Developer ID / notarized). After you download or unzip it, macOS may show *“cannot be opened because the developer cannot be verified.”* Clear quarantine, copy to Applications, then open:

```bash
xattr -cr ~/Downloads/BarcodeScanner.app
cp -R ~/Downloads/BarcodeScanner.app /Applications/
open /Applications/BarcodeScanner.app
```

If Gatekeeper still blocks it: right-click the app → **Open**, or System Settings → **Privacy & Security** → **Open Anyway**.

## Build & run from source

```bash
./build.sh
open dist/BarcodeScanner.app
```

Optional CLI smoke test on a single file:

```bash
dist/BarcodeScanner.app/Contents/MacOS/BarcodeScanner --scan /path/to/photo.HEIC
```

## Privacy

Images are processed on your Mac. Nothing is sent to a server. Sample photos used while developing this app are not included in the repository.

## Related

- Original web app: [pardostech.com/BarcodeScanner](https://pardostech.com/BarcodeScanner/)
- More tools: [pardostech.com](https://pardostech.com/)
