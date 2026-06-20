# LibreOffice Supported File Extensions for PDF Conversion

> **Note:** This document applies to LibreOffice 7.x and later. Filter support may vary in earlier versions.

According to official LibreOffice documentation—specifically the **"File Conversion Filter Names"** specification in the LibreOffice Help system—the command-line conversion feature handles documents by passing them through registered **Input Filters** (how LibreOffice reads a file) and **Output Filters** (how LibreOffice writes a file, like `writer_pdf_Export` or `calc_pdf_Export`).

The rule for headless command-line conversion is structurally defined by LibreOffice's architecture: **If a file extension mapping is tied to an internal LibreOffice component (Writer, Calc, Impress, Draw), that format can be converted into a PDF.**

The support status for the extensions listed previously, directly mapping them to the official LibreOffice architectural document filter registry, includes:

### 1. Word Processing Documents (Writer Module)

**Official Output Filter:** `writer_pdf_Export`

* **Microsoft Word Formats (`.docx`, `.doc`, `.docm`, `.dotx`, `.dotm`):** Fully supported. The documentation lists specific filters like `"Office Open XML Text"` for `.docx` and `"MS Word 97"` for legacy `.doc`/`.wps`.
* **OpenDocument Formats (`.odt`, `.ott`, `.fodt`, `.sxw`):** Fully supported. `.odt` maps to the core `"writer8"` filter, and legacy formats map to `"StarOffice XML (Writer)"`.
* **Web & Markup (`.html`, `.htm`, `.xhtml`):** Fully supported via `"HTML (StarWriter)"`.
* **Standard Text (`.rtf`, `.txt`):** Fully supported. Rich Text maps to `"Rich Text Format"`, and plain text maps to the `"Text"` filter.
* **Alternative (`.wpd`, `.wps`, `.pages`, `.abw`, `.lwp`):** Verified. Documentation lists explicit third-party import bridges, including `"WordPerfect"`, `"MS_Works"`, `"AbiWord"`, `"LotusWordPro"`, and `"Apple Pages"`.

### 2. Spreadsheets (Calc Module)

**Official Output Filter:** `calc_pdf_Export`

* **Microsoft Excel Formats (`.xlsx`, `.xls`, `.xlsm`, `.xlsb`, `.xltx`, `.xltm`):** Fully supported. Handled natively via Excel XML and legacy Excel filters registered under the Calc sub-system.
* **OpenDocument Spreadsheets (`.ods`, `.ots`, `.fods`, `.sxc`):** Fully supported. Maps natively to `"calc8"` filters.
* **Structured Data (`.csv`, `.tsv`):** Fully supported. Handled by the text-import engine of Calc, which constructs a grid structure before sending it to the PDF renderer.
* **Alternative (`.numbers`, `.dif`, `.wk1`, `.123`):** Verified. Imported via LibreOffice's `libetonyek` bridge (for Apple Numbers) and native legacy filters (for Lotus 1-2-3 and Data Interchange Format), routing directly into Calc's canvas.

### 3. Presentations (Impress Module)

**Official Output Filter:** `impress_pdf_Export`

* **Microsoft PowerPoint (`.pptx`, `.ppt`, `.pptm`, `.potx`, `.potm`, `.ppsx`, `.pps`):** Fully supported. Routed through the Office Open XML Presentation and MS PowerPoint 97 engines.
* **OpenDocument Presentations (`.odp`, `.otp`, `.fodp`, `.sxi`):** Natively supported via the core `"impress8"` engine.
* **Alternative (`.key`):** Verified. Apple Keynote files are read using LibreOffice's internal presentation import filters and converted using the page-per-slide model.

### 4. Vector Graphics & Diagrams (Draw Module)

**Official Output Filter:** `draw_pdf_Export`

* **Vector Formats (`.odg`, `.fodg`, `.sxd`, `.svg`, `.svgz`, `.wmf`, `.emf`, `.eps`, `.ai`):** Fully supported. Because Draw shares a common graphic engine with Impress, vector layouts are preserved in vector format when exported via `draw_pdf_Export`. **Note:** `.ai` files require an embedded PDF compatibility layer to be parsed; files without this layer will fail to convert.
* **Raster Images (`.png`, `.jpg`, `.jpeg`, `.gif`, `.bmp`, `.tiff`, `.psd`):** Fully supported. When passed via command line, LibreOffice opens raster extensions inside a blank Draw canvas sized to the image dimensions, then exports the canvas directly into a single-page PDF wrapper.
* **CAD Layouts (`.dxf`):** Supported via Draw’s AutoCAD Interchange Import Filter.

### Architectural Constraint to Remember

While LibreOffice's documentation guarantees that these formats can be parsed and passed to the PDF compiler, headless execution relies completely on **shared document libraries**. If you are building a headless environment (like a Linux server or Docker container), you must install the respective application packages (e.g., `libreoffice-writer`, `libreoffice-calc`, `libreoffice-impress`, `libreoffice-draw`) for these extensions to work. If you run a headless server with *only* `libreoffice-writer` installed, trying to convert an `.xlsx` or `.png` file will fail because the necessary conversion filters will be absent.
