const fs = require("node:fs");
const path = require("node:path");

// 1. Resolve local dependencies

const MarkdownIt = require("markdown-it");
const markdownItEmoji = require("markdown-it-emoji").full;
const markdownItContainer = require("markdown-it-container");
const markdownItPlantuml = require("markdown-it-plantuml");
const markdownItKatex = require("@vscode/markdown-it-katex").default;
const hljs = require("highlight.js");
const puppeteer = require("puppeteer-core");

// Helper to escape HTML in fallback fence rendering
const escapeHtml = (unsafe) => {
	return unsafe
		.replace(/&/g, "&amp;")
		.replace(/</g, "&lt;")
		.replace(/>/g, "&gt;")
		.replace(/"/g, "&quot;")
		.replace(/'/g, "&#039;");
};

// 2. Parse command line arguments
const args = process.argv.slice(2);
let configFile = "";
let sourceFile = "";
let targetFile = "";

for (let i = 0; i < args.length; i++) {
	if (args[i] === "--config-file" || args[i] === "-c") {
		configFile = args[++i];
	} else if (args[i] === "--source" || args[i] === "-s") {
		sourceFile = args[++i];
	} else if (args[i] === "--target" || args[i] === "-t") {
		targetFile = args[++i];
	}
}

if (!configFile || !sourceFile || !targetFile) {
	console.error(
		"Usage: node md2pdf_compiler.js --config-file <config.json> --source <source.md> --target <target.pdf>",
	);
	process.exit(1);
}

// 3. Load configurations and run pre-flight validation checks
let configContent = fs.readFileSync(configFile, "utf8");
if (configContent.startsWith("\uFEFF")) {
	configContent = configContent.slice(1);
}
const config = JSON.parse(configContent);

if (!config.launch_options?.executablePath) {
	console.error(
		"[ERROR] Config validation failed: 'launch_options.executablePath' is not defined.",
	);
	process.exit(1);
}
if (!fs.existsSync(config.launch_options.executablePath)) {
	console.error(
		`[ERROR] Configured browser executable not found at: ${config.launch_options.executablePath}`,
	);
	process.exit(1);
}

// 4. Initialize markdown-it with the same options and plugins as VSCode
const breaks =
	config.markdown_options && config.markdown_options.breaks !== undefined
		? config.markdown_options.breaks
		: false;
const md = new MarkdownIt({
	html: true,
	breaks: breaks,
	highlight: (str, lang) => {
		if (lang?.match(/\bmermaid\b/i)) {
			return `<div class="mermaid">${str}</div>`;
		}
		if (lang && hljs.getLanguage(lang)) {
			try {
				const highlighted = hljs.highlight(str, {
					language: lang,
					ignoreIllegals: true,
				}).value;
				return `<pre class="hljs"><code><div>${highlighted}</div></code></pre>`;
			} catch {}
		}
		return `<pre class="hljs"><code><div>${escapeHtml(str)}</div></code></pre>`;
	},
});

md.use(markdownItEmoji);
md.use(markdownItContainer);
md.use(markdownItPlantuml);
md.use(markdownItKatex, {
	enableBareBlocks: true,
	enableMathBlockInHtml: false,
});

// 5. Read input Markdown content
let mdContent = fs.readFileSync(sourceFile, "utf8");

// Strip UTF-8 Byte Order Mark (BOM) if present (ensures H1 at start of file parses correctly)
if (mdContent.startsWith("\uFEFF")) {
	mdContent = mdContent.slice(1);
}

// Strip YAML front-matter if present and extract title
let markdownBody = mdContent;
let docTitle = "";
if (mdContent.startsWith("---")) {
	const parts = mdContent.split("---");
	if (parts.length >= 3) {
		const frontMatter = parts[1];
		const match = frontMatter.match(
			/(?:^|\n)title\s*:\s*(["']?)(.*?)\1\s*(?:\n|$)/,
		);
		if (match) {
			docTitle = match[2].trim();
		}
		markdownBody = parts.slice(2).join("---");
	}
}

// Fallback to the base filename (including extension) if no YAML title is found
if (!docTitle) {
	docTitle = path.basename(sourceFile);
} else {
	// Strip standard markdown formatting from title
	docTitle = docTitle.replace(/[*_`~]/g, "").trim();
}

// Render Markdown to HTML body
const htmlBody = md.render(markdownBody);

// 6. Gather stylesheets from local css directory
const cssDir = path.join(__dirname, "css");
const markdownCss = fs.readFileSync(path.join(cssDir, "markdown.css"), "utf8");
const markdownPdfCss = fs.readFileSync(
	path.join(cssDir, "markdown-pdf.css"),
	"utf8",
);
const highlightStyle =
	config.markdown_options?.highlight_style || "tomorrow.css";
const tomorrowCss = fs.readFileSync(path.join(cssDir, highlightStyle), "utf8");

// Inject custom CSS adjustments to fix Mermaid layout and page breaks
const customAdjustments = `
.mermaid svg {
  height: auto !important;
  max-width: 100% !important;
}
pre, table, blockquote, .mermaid {
  page-break-inside: avoid;
}
`;

const combinedStyles = `
${markdownCss}
${markdownPdfCss}
${tomorrowCss}
${config.css || ""}
${customAdjustments}
`;

// 7. Build full HTML document matching VSCode extension template
let mermaidUrl = "https://unpkg.com/mermaid/dist/mermaid.min.js";
const localMermaid = path.join(__dirname, "css", "mermaid.min.js");
if (fs.existsSync(localMermaid)) {
	mermaidUrl = `file:///${path.resolve(localMermaid).replace(/\\/g, "/")}`;
}

const mermaidTheme = (config.mermaid_options?.theme || "default").replace(
	/[^a-zA-Z0-9_-]/g,
	"",
);

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
const tempHtmlPath = sourceFile.replace(/\.md$/i, ".tmp.html");
fs.writeFileSync(tempHtmlPath, finalHtml, "utf8");

let browser;

// Signal handlers to cleanly close browser and delete tempHtmlPath on abort/signal
const cleanup = async () => {
	if (browser) {
		try {
			await browser.close();
		} catch {}
	}
	if (fs.existsSync(tempHtmlPath)) {
		try {
			fs.unlinkSync(tempHtmlPath);
		} catch {}
	}
};

process.on("exit", () => {
	if (fs.existsSync(tempHtmlPath)) {
		try {
			fs.unlinkSync(tempHtmlPath);
		} catch {}
	}
});

process.on("SIGINT", async () => {
	await cleanup();
	process.exit(130);
});

process.on("SIGTERM", async () => {
	await cleanup();
	process.exit(143);
});

// 9. Convert to PDF using Puppeteer
(async () => {
	console.log(
		`[INFO] Launching Puppeteer to compile: ${sourceFile} -> ${targetFile}`,
	);

	let hasError = false;

	try {
		// Resolve header and footer templates from external files if specified
		const pdfOptions = config.pdf_options || {};
		let headerTemplate = pdfOptions.headerTemplate || "";
		if (pdfOptions.headerTemplatePath) {
			const resolvedPath = path.resolve(
				path.dirname(configFile),
				pdfOptions.headerTemplatePath,
			);
			if (fs.existsSync(resolvedPath)) {
				headerTemplate = fs.readFileSync(resolvedPath, "utf8");
			}
		}

		let footerTemplate = pdfOptions.footerTemplate || "";
		if (pdfOptions.footerTemplatePath) {
			const resolvedPath = path.resolve(
				path.dirname(configFile),
				pdfOptions.footerTemplatePath,
			);
			if (fs.existsSync(resolvedPath)) {
				footerTemplate = fs.readFileSync(resolvedPath, "utf8");
			}
		}

		// Format current date as YYYY/MM/DD HH:mm (24-hour format)
		const now = new Date();
		const mm = String(now.getMonth() + 1).padStart(2, "0");
		const dd = String(now.getDate()).padStart(2, "0");
		const hh = String(now.getHours()).padStart(2, "0");
		const min = String(now.getMinutes()).padStart(2, "0");
		const formattedDate = `${now.getFullYear()}/${mm}/${dd} ${hh}:${min}`;

		// Override standard date formatting
		const dateRegex = /<span\s+class=(['"])date\1\s*>\s*<\/span>/gi;
		if (headerTemplate) {
			headerTemplate = headerTemplate.replace(
				dateRegex,
				`<span>${formattedDate}</span>`,
			);
			headerTemplate = headerTemplate.replace(/\{\{date\}\}/g, formattedDate);
		}
		if (footerTemplate) {
			footerTemplate = footerTemplate.replace(
				dateRegex,
				`<span>${formattedDate}</span>`,
			);
			footerTemplate = footerTemplate.replace(/\{\{date\}\}/g, formattedDate);
		}
		browser = await puppeteer.launch({
			executablePath: config.launch_options.executablePath,
			args: config.launch_options.args || [
				"--no-sandbox",
				"--disable-setuid-sandbox",
			],
		});

		const page = await browser.newPage();
		await page.setDefaultTimeout(0);

		// Navigate to temp HTML file, wait for network idle to ensure Mermaid scripts render
		const fileUrl = `file:///${path.resolve(tempHtmlPath).replace(/\\/g, "/")}`;
		await page.goto(fileUrl, { waitUntil: "networkidle0" });

		// Wait for all document fonts to load completely
		await page.evaluate(() => document.fonts.ready);

		// Conditional waiting if Mermaid is present in the rendered HTML
		const hasMermaid = htmlBody.includes('class="mermaid"');
		if (hasMermaid) {
			// Wait for Mermaid SVGs to be inserted into the DOM
			await page
				.waitForSelector(".mermaid svg", { timeout: 15000 })
				.catch(() => {
					console.log(
						"[WARNING] Timeout waiting for Mermaid diagram SVGs. Proceeding...",
					);
				});

			// Give Mermaid layout/rendering a delay to fully settle
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

		console.log(`[OK] Successfully rendered: ${targetFile}`);
	} catch (err) {
		console.error(`[ERROR] PDF Generation failed: ${err.message}`);
		hasError = true;
	} finally {
		if (browser) {
			await browser.close();
		}
		// Cleanup temporary HTML file
		if (fs.existsSync(tempHtmlPath)) {
			fs.unlinkSync(tempHtmlPath);
		}
		if (hasError) {
			process.exit(1);
		}
	}
})();
