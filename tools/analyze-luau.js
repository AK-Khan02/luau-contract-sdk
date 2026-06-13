#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const repoRoot = path.resolve(__dirname, "..");
const roots = ["src", "examples", "tests", "plugin"];
const luauExtensions = new Set([".lua", ".luau"]);
const skippedDirectories = new Set([".git", "node_modules"]);

function collectLuauFiles(directory, files) {
	if (!fs.existsSync(directory)) {
		return;
	}

	for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
		if (entry.isDirectory()) {
			if (!skippedDirectories.has(entry.name)) {
				collectLuauFiles(path.join(directory, entry.name), files);
			}
			continue;
		}

		if (entry.isFile() && luauExtensions.has(path.extname(entry.name))) {
			files.push(path.relative(repoRoot, path.join(directory, entry.name)));
		}
	}
}

function collectAllLuauFiles() {
	const files = [];
	for (const root of roots) {
		collectLuauFiles(path.join(repoRoot, root), files);
	}
	return files.sort();
}

const files = collectAllLuauFiles();
if (process.argv.includes("--print-files")) {
	process.stdout.write(`${files.join("\n")}\n`);
	process.exit(0);
}

if (files.length === 0) {
	console.error("No Luau files found to analyze.");
	process.exit(1);
}

const analyzer = process.env.LUAU_ANALYZE || "luau-analyze";
const result = spawnSync(analyzer, files, {
	cwd: repoRoot,
	stdio: "inherit",
});

process.exit(result.status ?? 1);
