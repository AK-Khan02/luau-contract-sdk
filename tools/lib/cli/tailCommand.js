"use strict";

function formatRelayEntry(serverId, entry) {
	const parts = [`[${entry.level || "info"}]`];
	if (serverId != null) {
		parts.push(`${serverId}`);
	}
	if (entry.system != null) {
		parts.push(`${entry.system}`);
	}
	parts.push(`${entry.name || entry.code || "Diagnostic"}`);
	const prefix = parts.join(" ");
	return entry.message != null ? `${prefix}: ${entry.message}` : prefix;
}

async function fetchTail(options, since) {
	const url = new URL("/tail", options.endpoint);
	url.searchParams.set("since", String(since));
	const headers = {};
	if (options.apiKey != null) {
		headers["x-api-key"] = options.apiKey;
	}

	const response = await fetch(url, { headers });
	if (response.status === 401) {
		throw new Error("relay rejected the API key (401)");
	}
	if (!response.ok) {
		throw new Error(`relay returned status ${response.status}`);
	}
	return response.json();
}

function isRecordObject(value) {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

function printTailPage(page) {
	if (!isRecordObject(page) || !Array.isArray(page.batches)) {
		throw new Error("relay returned an unexpected payload");
	}
	if (page.dropped > 0) {
		process.stdout.write(`-- relay dropped ${page.dropped} batch(es) before this point --\n`);
	}
	for (const record of page.batches) {
		if (!isRecordObject(record) || !isRecordObject(record.batch)) {
			continue;
		}
		const entries = Array.isArray(record.batch.entries) ? record.batch.entries : [];
		for (const entry of entries) {
			if (isRecordObject(entry)) {
				process.stdout.write(`${formatRelayEntry(record.serverId, entry)}\n`);
			}
		}
	}
}

async function runTail(options) {
	if (typeof options.endpoint !== "string" || options.endpoint === "") {
		throw new Error("tail requires --endpoint");
	}
	if (!Number.isInteger(options.since) || options.since < 0) {
		throw new Error("--since must be a non-negative integer");
	}
	if (!Number.isFinite(options.intervalSeconds) || options.intervalSeconds <= 0) {
		throw new Error("--interval must be a positive number");
	}

	let since = options.since;

	if (options.once) {
		try {
			printTailPage(await fetchTail(options, since));
		} catch (error) {
			process.stderr.write(`tail: ${error.message}\n`);
			return 1;
		}
		return 0;
	}

	process.stderr.write(`tailing ${options.endpoint} (every ${options.intervalSeconds}s, since ${since})\n`);
	for (;;) {
		try {
			const page = await fetchTail(options, since);
			printTailPage(page);
			if (Number.isInteger(page.latest)) {
				since = Math.max(since, page.latest);
			}
		} catch (error) {
			process.stderr.write(`tail: ${error.message}\n`);
		}
		await new Promise((resolve) => {
			setTimeout(resolve, options.intervalSeconds * 1000);
		});
	}
}

module.exports = {
	runTail,
};
