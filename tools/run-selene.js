#!/usr/bin/env node
"use strict";

const fs = require("node:fs");
const https = require("node:https");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const SELENE_VERSION = "0.31.0";
const repoRoot = path.resolve(__dirname, "..");
const cacheRoot = path.join(repoRoot, ".tool-cache", "selene", SELENE_VERSION);

function binaryName() {
	return process.platform === "win32" ? "selene.exe" : "selene";
}

function platformName() {
	if (process.platform === "darwin") {
		return "macos";
	}
	if (process.platform === "linux") {
		return "linux";
	}
	if (process.platform === "win32") {
		return "windows";
	}
	throw new Error(`Unsupported platform for Selene: ${process.platform}`);
}

function cachedBinaryPath() {
	return path.join(cacheRoot, platformName(), binaryName());
}

function run(command, args, options = {}) {
	const result = spawnSync(command, args, {
		cwd: repoRoot,
		stdio: "inherit",
		...options,
	});
	if (result.error) {
		throw result.error;
	}
	return result.status ?? 1;
}

function canRun(command) {
	const result = spawnSync(command, ["--version"], {
		cwd: repoRoot,
		stdio: "ignore",
	});
	return result.status === 0;
}

function download(url, targetPath) {
	return new Promise((resolve, reject) => {
		const request = https.get(url, (response) => {
			if (response.statusCode >= 300 && response.statusCode < 400 && response.headers.location) {
				response.resume();
				download(response.headers.location, targetPath).then(resolve, reject);
				return;
			}
			if (response.statusCode !== 200) {
				response.resume();
				reject(new Error(`Failed to download Selene: HTTP ${response.statusCode}`));
				return;
			}

			fs.mkdirSync(path.dirname(targetPath), { recursive: true });
			const file = fs.createWriteStream(targetPath);
			response.pipe(file);
			file.on("finish", () => {
				file.close(resolve);
			});
			file.on("error", reject);
		});
		request.on("error", reject);
	});
}

function extract(zipPath, destination) {
	fs.rmSync(destination, { force: true, recursive: true });
	fs.mkdirSync(destination, { recursive: true });

	if (process.platform === "win32") {
		const status = run("powershell", [
			"-NoProfile",
			"-Command",
			`Expand-Archive -Path ${JSON.stringify(zipPath)} -DestinationPath ${JSON.stringify(destination)} -Force`,
		]);
		if (status !== 0) {
			process.exit(status);
		}
		return;
	}

	const status = run("unzip", ["-q", zipPath, "-d", destination]);
	if (status !== 0) {
		process.exit(status);
	}
	fs.chmodSync(path.join(destination, binaryName()), 0o755);
}

async function ensureSelene() {
	const cached = cachedBinaryPath();
	if (fs.existsSync(cached)) {
		return cached;
	}

	const platform = platformName();
	const archiveName = `selene-${SELENE_VERSION}-${platform}.zip`;
	const archivePath = path.join(cacheRoot, archiveName);
	const url = `https://github.com/Kampfkarren/selene/releases/download/${SELENE_VERSION}/${archiveName}`;

	console.error(`Downloading Selene ${SELENE_VERSION} for ${platform}...`);
	await download(url, archivePath);
	extract(archivePath, path.dirname(cached));

	if (!fs.existsSync(cached)) {
		throw new Error(`Selene archive did not contain ${binaryName()}`);
	}
	return cached;
}

async function main() {
	const args = process.argv.slice(2);
	if (args.length === 0) {
		args.push("src", "examples", "plugin");
	}

	const envBinary = process.env.SELENE_BIN;
	if (envBinary) {
		process.exit(run(envBinary, args));
	}

	if (canRun("selene")) {
		process.exit(run("selene", args));
	}

	const binary = await ensureSelene();
	process.exit(run(binary, args));
}

main().catch((error) => {
	console.error(error.message || error);
	process.exit(1);
});
