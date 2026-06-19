/**
 * md2pdf_compiler.js
 * -----------------------------------------------------------------------------
 * Custom Node.js compiler to render Markdown files to PDF using Puppeteer.
 * Designed to mirror the rendering quality, styling, and behavior of the
 * VS Code Markdown PDF extension.
 * -----------------------------------------------------------------------------
 *
 * OBJECTIVES:
 *   - Parse Markdown text structures (headings, lists, tables, links, images, blockquotes).
 *   - Render embedded code syntax highlighting via Highlight.js.
 *   - Execute Mermaid diagram rendering into vector SVG objects in a headless browser context.
 *   - Support mathematical expression layouts (LaTeX) through Katex.
 *   - Enable custom page headers/footers, styling templates, and page layout dimensions.
 *   - Provide error-isolated execution with absolute resource safety (cleanup of temporary files).
 *
 * CORE COMPONENTS:
 *   1. Argument Parser: Extracts source files, config paths, target paths, and formatting settings.
 *   2. Markdown-It Engine: Parsed AST builder initialized with Breaks, Highlight hooks, Container rules,
 *      PlantUML, Katex math parser, and Emojis.
 *   3. Styling Engine: Combines standard Markdown styling, VS Code Print style adjustments, Highlight.js theme,
 *      custom user CSS, and page break/Mermaid responsiveness patches.
 *   4. HTML Aggregator: Generates valid HTML5 wrappers with local/remote Mermaid JS initialization.
 *   5. Puppeteer Runner: Initiates Chromium browser, waits for fonts and scripts, and exports PDF layout.
 *   6. Cleanup System: Attaches event listeners for SIGINT, SIGTERM, and general exits to delete temporary files.
 *
 * FUNCTIONALITY & DATA FLOW:
 *   [CLI arguments passed]
 *            |
 *            v
 *     (Args Parsing) -> Config JSON read -> Browser Executable verified
 *            |
 *            v
 *    [Read Markdown] -> Strip BOM & YAML header -> Extract Document Title
 *            |
 *            v
 *    [Render HTML] -> Compile Markdown to HTML body -> Aggregate CSS styles -> Inject Mermaid hooks
 *            |
 *            v
 *   [Write tmp.html next to source] (allows resolving relative image assets correctly)
 *            |
 *            v
 *    [Boot Puppeteer] -> Load tmp.html -> Wait for network idle, fonts loading, and Mermaid renders
 *            |
 *            v
 *     [Print PDF] -> Save to target path -> Trigger cleanup hooks -> Terminate process
 *
 * TEST STRATEGY:
 *   1. Basic Compilation: Run manual conversion on a typical document:
 *      node md2pdf_compiler.js --config-file config.json --source doc.md --target doc.pdf
 *   2. Format Parameter Validation: Verify stdout outputs:
 *      - Under `--format text`: Prints "[INFO] ..." and "[OK] ..." lines.
 *      - Under `--format json`: Prints JSON-lines: '{"level":"info","msg":"..."}' to stdout/stderr.
 *   3. Offline/Fallback Rendering: Delete or rename 'css/mermaid.min.js' to force remote
 *      unpkg CDN resolving, and test offline rendering by disabling network connection.
 *   4. Mermaid Delay Settle Testing: Use various 'settle_delay' configurations in config.json
 *      to test complex, large diagrams layout settle timings.
 *   5. Clean-up verification: Interrupt processing via SIGINT (Ctrl+C) during PDF generation,
 *      then verify that temporary `.tmp.html` files are deleted automatically.
 */

// Load the Node.js native filesystem module for reading and writing files.
const fs = require("node:fs");
// Load the Node.js native path module for handling file and directory paths.
const path = require("node:path");

// 1. Resolve local dependencies

// Load the markdown-it package for converting Markdown syntax to HTML.
const MarkdownIt = require("markdown-it");
// Load the full emoji plugin for parsing emoji codes like :smile:.
const markdownItEmoji = require("markdown-it-emoji").full;
// Load the container plugin for parsing custom styled blocks (e.g. alerts).
const markdownItContainer = require("markdown-it-container");
// Load the plantuml plugin for rendering UML diagrams.
const markdownItPlantuml = require("markdown-it-plantuml");
// Load the Katex plugin for formatting math LaTeX syntax.
const markdownItKatex = require("@vscode/markdown-it-katex").default;
// Load highlight.js for syntax highlighting block code segments.
const hljs = require("highlight.js");
// Load puppeteer-core to control a headless Chrome/Chromium browser instance.
const puppeteer = require("puppeteer-core");

// Helper to escape HTML in fallback fence rendering
// Converts dangerous characters to safe HTML entities to prevent rendering issues or code injections.
//
// Parameters:
//   unsafe - The raw unsafe string content.
//
// Returns:
//   A sanitized string safe to include in HTML.
const escapeHtml = (unsafe) => {
	return unsafe
		.replace(/&/g, "&amp;")
		.replace(/</g, "&lt;")
		.replace(/>/g, "&gt;")
		.replace(/"/g, "&quot;")
		.replace(/'/g, "&#039;");
};

// 2. Parse command line arguments
// Slice process.argv to remove the node executable path and compiler script path.
const args = process.argv.slice(2);
// Initialize the config file path variable.
let configFile = "";
// Initialize the source markdown file path variable.
let sourceFile = "";
// Initialize the destination PDF file path variable.
let targetFile = "";
// Initialize the output streams format variable, defaulting to 'text'.
let format = "text";

// Loop through all parsed command line options.
for (let i = 0; i < args.length; i++) {
	if (args[i] === "--config-file" || args[i] === "-c") {
		// Advance index and retrieve the config JSON path.
		configFile = args[++i];
	} else if (args[i] === "--source" || args[i] === "-s") {
		// Advance index and retrieve the source markdown file path.
		sourceFile = args[++i];
	} else if (args[i] === "--target" || args[i] === "-t") {
		// Advance index and retrieve the target output PDF path.
		targetFile = args[++i];
	} else if (args[i] === "--format") {
		// Advance index and retrieve the requested logging format ('json' or 'text').
		format = args[++i];
	}
}

// Ensure all required parameters are provided before proceeding.
if (!configFile || !sourceFile || !targetFile) {
	if (format === "json") {
		// Output structured error on stderr.
		console.error(
			JSON.stringify({
				level: "error",
				msg: "Usage: node md2pdf_compiler.js --config-file <config.json> --source <source.md> --target <target.pdf>",
			}),
		);
	} else {
		// Output standard plain text error on stderr.
		console.error(
			"Usage: node md2pdf_compiler.js --config-file <config.json> --source <source.md> --target <target.pdf>",
		);
	}
	// Exit process with error code 1.
	process.exit(1);
}

// 3. Load configurations and run pre-flight validation checks
// Read the JSON config file into a string buffer.
let configContent = fs.readFileSync(configFile, "utf8");
// Check for and strip the UTF-8 Byte Order Mark (BOM) if present.
if (configContent.startsWith("\uFEFF")) {
	configContent = configContent.slice(1);
}
// Parse the configuration string into a JSON object.
const config = JSON.parse(configContent);

// Validate that the launch options config specifies a browser executable path.
if (!config.launch_options?.executablePath) {
	console.error(
		"[ERROR] Config validation failed: 'launch_options.executablePath' is not defined.",
	);
	process.exit(1);
}
// Assert that the specified browser executable exists on disk.
if (!fs.existsSync(config.launch_options.executablePath)) {
	console.error(
		`[ERROR] Configured browser executable not found at: ${config.launch_options.executablePath}`,
	);
	process.exit(1);
}

// 4. Initialize markdown-it with the same options and plugins as VSCode
// Read line-breaks config parameter, defaulting to false if undefined.
const breaks =
	config.markdown_options && config.markdown_options.breaks !== undefined
		? config.markdown_options.breaks
		: false;
// Create new MarkdownIt parser engine instance.
const md = new MarkdownIt({
	html: true, // Enable HTML tags translation in source
	breaks: breaks, // Enforce soft line breaks option
	// Custom highlighting hook function for code block styling
	highlight: (str, lang) => {
		// Check if the language tag matches Mermaid diagrams.
		if (lang?.match(/\bmermaid\b/i)) {
			// Return a raw div wrapper; Puppeteer page scripts will render these to SVG objects.
			return `<div class="mermaid">${str}</div>`;
		}
		// Check if the language is defined and supported by highlight.js.
		if (lang && hljs.getLanguage(lang)) {
			try {
				// Highlight code structure using highlight.js.
				const highlighted = hljs.highlight(str, {
					language: lang,
					ignoreIllegals: true,
				}).value;
				// Return syntax highlighted HTML markup.
				return `<pre class="hljs"><code><div>${highlighted}</div></code></pre>`;
			} catch {}
		}
		// Fallback for plaintext or unsupported languages (escapes HTML syntax to prevent injections).
		return `<pre class="hljs"><code><div>${escapeHtml(str)}</div></code></pre>`;
	},
});

// Bind plugins to MarkdownIt instance
md.use(markdownItEmoji); // Parse emoji mappings (e.g. :smile:)
md.use(markdownItContainer); // Custom container blocks parsing support
md.use(markdownItPlantuml); // PlantUML diagram parsing support
md.use(markdownItKatex, {
	// LaTeX math formatting support
	enableBareBlocks: true, // Render standalone math equations
	enableMathBlockInHtml: false,
});

// 5. Read input Markdown content
// Load the Markdown source file content into memory.
let mdContent = fs.readFileSync(sourceFile, "utf8");

// Strip UTF-8 Byte Order Mark (BOM) if present (ensures H1 at start of file parses correctly)
if (mdContent.startsWith("\uFEFF")) {
	mdContent = mdContent.slice(1);
}

// Strip YAML front-matter if present and extract title
// Initialize body content reference.
let markdownBody = mdContent;
// Initialize document title tracker.
let docTitle = "";
// Check if the file starts with the YAML metadata boundary indicator.
if (mdContent.startsWith("---")) {
	// Split markdown content using the boundary separator.
	const parts = mdContent.split("---");
	// Ensure we have a matching YAML header section.
	if (parts.length >= 3) {
		// Extract the front-matter content block.
		const frontMatter = parts[1];
		// Match the title field value within the front-matter text.
		const match = frontMatter.match(
			/(?:^|\n)title\s*:\s*(["']?)(.*?)\1\s*(?:\n|$)/,
		);
		if (match) {
			// Extract title and strip quote marks.
			docTitle = match[2].trim();
		}
		// Extract Markdown body content below front-matter headers.
		markdownBody = parts.slice(2).join("---");
	}
}

// Fallback to the base filename (including extension) if no YAML title is found
if (!docTitle) {
	docTitle = path.basename(sourceFile);
} else {
	// Strip standard markdown formatting from title
	// Strip standard markdown formatting characters from title string.
	docTitle = docTitle.replace(/[*_`~]/g, "").trim();
}

// Render Markdown to HTML body
// Render Markdown to HTML body using the configured MarkdownIt parser.
const htmlBody = md.render(markdownBody);

// 6. Gather stylesheets from local css directory
// Resolve absolute path of compiler css folder directory.
const cssDir = path.join(__dirname, "css");
// Read default markdown typography stylesheet.
const markdownCss = fs.readFileSync(path.join(cssDir, "markdown.css"), "utf8");
// Read print pagination media layouts stylesheet.
const markdownPdfCss = fs.readFileSync(
	path.join(cssDir, "markdown-pdf.css"),
	"utf8",
);
// Read syntax highlighting color scheme, defaulting to 'tomorrow.css'.
const highlightStyle =
	config.markdown_options?.highlight_style || "tomorrow.css";
const tomorrowCss = fs.readFileSync(path.join(cssDir, highlightStyle), "utf8");

// Inject custom CSS adjustments to fix Mermaid layout and page breaks
// Fixes height overflow bounds and forces logical blocks to avoid breaking across printed pages.
const customAdjustments = `
.mermaid svg {
  height: auto !important;
  max-width: 100% !important;
}
pre, table, blockquote, .mermaid {
  page-break-inside: avoid;
}
`;

// Aggregate and combine all styling directives.
const combinedStyles = `
${markdownCss}
${markdownPdfCss}
${tomorrowCss}
${config.css || ""}
${customAdjustments}
`;

// 7. Build full HTML document matching VSCode extension template
// Resolve Mermaid JS library script URL. Default to CDN unpkg resource.
let mermaidUrl = "https://unpkg.com/mermaid/dist/mermaid.min.js";
// Assert if a local copy of mermaid.min.js is present inside the css asset subdirectory.
const localMermaid = path.join(__dirname, "css", "mermaid.min.js");
if (fs.existsSync(localMermaid)) {
	// Resolve relative filesystem URL to the local mermaid script.
	mermaidUrl = `file:///${path.resolve(localMermaid).replace(/\\/g, "/")}`;
}

// Sanitize the Mermaid theme setting using regex, allowing only safe alphanumeric strings.
const mermaidTheme = (config.mermaid_options?.theme || "default").replace(
	/[^a-zA-Z0-9_-]/g,
	"",
);

// Aggregate CSS stylesheets and HTML content markup templates.
const finalHtml = `<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<title>${escapeHtml(docTitle)}</title>
<style>
${combinedStyles}
</style>
<script src="${mermaidUrl}"></script>
</head>
<body>
  <script>
    mermaid.initialize({
      startOnLoad: true,
      theme: '${mermaidTheme}'
    });
  </script>
${htmlBody}
</body>
</html>
`;

// 8. Write temporary HTML file next to source markdown (resolves relative assets)
// The HTML file is temporarily saved next to the Markdown file, which allows Chromium
// to successfully resolve and render relative image resources and links.
const tempHtmlPath = sourceFile.replace(/\.md$/i, ".tmp.html");
// Write the fully constructed HTML document to the temp file.
fs.writeFileSync(tempHtmlPath, finalHtml, "utf8");

// Declare global browser scope reference for resource teardown hooks.
let browser;

// Signal handlers to cleanly close browser and delete tempHtmlPath on abort/signal
// Cleans up all system resources allocated to prevent memory leakage or hanging processes.
const cleanup = async () => {
	if (browser) {
		try {
			// Close the headless Chromium browser.
			await browser.close();
		} catch {}
	}
	if (fs.existsSync(tempHtmlPath)) {
		try {
			// Delete the temporary HTML file from disk.
			fs.unlinkSync(tempHtmlPath);
		} catch {}
	}
};

// Handle general process exit event.
process.on("exit", () => {
	if (fs.existsSync(tempHtmlPath)) {
		try {
			// Make sure temp HTML file is unlinked.
			fs.unlinkSync(tempHtmlPath);
		} catch {}
	}
});

// Handle SIGINT abort signal (e.g. Ctrl+C).
process.on("SIGINT", async () => {
	await cleanup();
	process.exit(130);
});

// Handle SIGTERM termination signal.
process.on("SIGTERM", async () => {
	await cleanup();
	process.exit(143);
});

// 9. Convert to PDF using Puppeteer
(async () => {
	// Launching log omitted to prevent redundant logs in stdout/stderr output streams.

	// Error tracking flag.
	let hasError = false;

	try {
		// Resolve header and footer templates from external files if specified
		const pdfOptions = config.pdf_options || {};

		// Helper to resolve template HTML content from config paths or inline strings.
		const resolveTemplate = (templatePath, inlineTemplate) => {
			if (templatePath) {
				const resolvedPath = path.resolve(
					path.dirname(configFile),
					templatePath,
				);
				if (fs.existsSync(resolvedPath)) {
					return fs.readFileSync(resolvedPath, "utf8");
				}
			}
			return inlineTemplate || "";
		};

		let headerTemplate = resolveTemplate(
			pdfOptions.headerTemplatePath,
			pdfOptions.headerTemplate,
		);
		let footerTemplate = resolveTemplate(
			pdfOptions.footerTemplatePath,
			pdfOptions.footerTemplate,
		);

		// Format current date as YYYY/MM/DD HH:mm (24-hour format)
		const now = new Date();
		const mm = String(now.getMonth() + 1).padStart(2, "0");
		const dd = String(now.getDate()).padStart(2, "0");
		const hh = String(now.getHours()).padStart(2, "0");
		const min = String(now.getMinutes()).padStart(2, "0");
		const formattedDate = `${now.getFullYear()}/${mm}/${dd} ${hh}:${min}`;

		// Helper to override date formatting placeholders inside header/footer templates.
		const interpolateDate = (template, dateStr) => {
			if (!template) return "";
			const dateRegex = /<span\s+class=(['"])date\1\s*>\s*<\/span>/gi;
			return template
				.replace(dateRegex, `<span>${dateStr}</span>`)
				.replace(/\{\{date\}\}/g, dateStr);
		};

		headerTemplate = interpolateDate(headerTemplate, formattedDate);
		footerTemplate = interpolateDate(footerTemplate, formattedDate);

		// Launch Chromium headless browser instance.
		browser = await puppeteer.launch({
			executablePath: config.launch_options.executablePath,
			// Pass configuration flags, defaulting to sandbox disable overrides.
			args: config.launch_options.args || [
				"--no-sandbox",
				"--disable-setuid-sandbox",
			],
		});

		// Create a new tab page.
		const page = await browser.newPage();
		// Disable page load timeouts to ensure large files render completely.
		await page.setDefaultTimeout(0);

		// Navigate to temp HTML file, wait for network idle to ensure Mermaid scripts render
		const fileUrl = `file:///${path.resolve(tempHtmlPath).replace(/\\/g, "/")}`;
		await page.goto(fileUrl, { waitUntil: "networkidle0" });

		// Wait for all document fonts to load completely
		await page.evaluate(() => document.fonts.ready);

		// Conditional waiting if Mermaid is present in the rendered HTML
		const hasMermaid = htmlBody.includes('class="mermaid"');
		if (hasMermaid) {
			// Wait for Mermaid SVGs to be inserted into the DOM.
			// Catches rendering timeouts to prevent compilation crashes on bad diagram codes.
			await page
				.waitForSelector(".mermaid svg", { timeout: 15000 })
				.catch(() => {
					if (format === "json") {
						console.error(
							JSON.stringify({
								level: "warning",
								msg: "Timeout waiting for Mermaid diagram SVGs. Proceeding...",
							}),
						);
					} else {
						console.log(
							"[WARNING] Timeout waiting for Mermaid diagram SVGs. Proceeding...",
						);
					}
				});

			// Give Mermaid layout/rendering a delay to fully settle.
			// Resolves rendering race conditions for large diagram maps.
			const settleDelay =
				config.mermaid_options &&
				config.mermaid_options.settle_delay !== undefined
					? config.mermaid_options.settle_delay
					: 200;
			await new Promise((resolve) => setTimeout(resolve, settleDelay));
		}

		// Generate PDF (retains default print media type for exact VSCode output quality)
		await page.pdf({
			path: targetFile,
			width: pdfOptions.width,
			height: pdfOptions.height,
			margin: pdfOptions.margin,
			printBackground: pdfOptions.printBackground,
			displayHeaderFooter: pdfOptions.displayHeaderFooter,
			headerTemplate: headerTemplate,
			footerTemplate: footerTemplate,
		});

		// Print success log message.
		// Omitted to prevent redundancy with final tabular/JSON status reports.
	} catch (err) {
		// Capture and print error message in JSON or plain text.
		if (format === "json") {
			console.error(
				JSON.stringify({
					level: "error",
					msg: `PDF Generation failed: ${err.message}`,
				}),
			);
		} else {
			console.error(`[ERROR] PDF Generation failed: ${err.message}`);
		}
		// Set error state flag to true.
		hasError = true;
	} finally {
		// Close Chromium and delete temporary HTML files inside the finally block to ensure cleanup.
		if (browser) {
			await browser.close();
		}
		// Cleanup temporary HTML file.
		if (fs.existsSync(tempHtmlPath)) {
			fs.unlinkSync(tempHtmlPath);
		}
		// If compilation encountered errors, terminate process with status code 1.
		if (hasError) {
			process.exit(1);
		}
	}
})();
