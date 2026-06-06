"use strict";

const fs = require("node:fs");
const path = require("node:path");

function ensureTrailingNewline(value) {
	return value.endsWith("\n") ? value : `${value}\n`;
}

function writeGeneratedFiles(files, options = {}) {
	const changed = [];
	const missing = [];

	for (const file of files) {
		const contents = ensureTrailingNewline(file.contents);
		const existing = fs.existsSync(file.path) ? fs.readFileSync(file.path, "utf8") : null;
		if (existing !== contents) {
			changed.push(file.path);
			if (existing == null) {
				missing.push(file.path);
			}
			if (!options.check) {
				fs.mkdirSync(path.dirname(file.path), { recursive: true });
				fs.writeFileSync(file.path, contents);
			}
		}
	}

	if (options.check && changed.length > 0) {
		const detail = changed.map((filePath) => {
			return missing.includes(filePath) ? `${filePath} (missing)` : `${filePath} (stale)`;
		}).join("\n");
		const error = new Error(`generated files are not up to date:\n${detail}`);
		error.changed = changed;
		throw error;
	}

	return changed;
}

module.exports = {
	writeGeneratedFiles,
};
