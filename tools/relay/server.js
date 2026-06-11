#!/usr/bin/env node
"use strict";

const crypto = require("node:crypto");
const http = require("node:http");

const MAX_BODY_BYTES = 1024 * 1024;

function parseArgs(argv) {
	const options = {
		port: 8787,
		cap: 500,
		apiKey: process.env.RELAY_API_KEY || null,
	};
	for (let index = 0; index < argv.length; index += 1) {
		const flag = argv[index];
		if (flag === "--port") {
			index += 1;
			options.port = Number(argv[index]);
		} else if (flag === "--cap") {
			index += 1;
			options.cap = Number(argv[index]);
		} else if (flag === "--api-key") {
			index += 1;
			options.apiKey = argv[index];
		} else {
			process.stderr.write(`unknown flag: ${flag}\n`);
			process.exit(2);
		}
	}
	if (!Number.isInteger(options.port) || options.port < 0) {
		process.stderr.write("--port must be a non-negative integer\n");
		process.exit(2);
	}
	if (!Number.isInteger(options.cap) || options.cap < 1) {
		process.stderr.write("--cap must be a positive integer\n");
		process.exit(2);
	}
	return options;
}

function createRelayState(cap) {
	return {
		cap,
		batches: [],
		nextSeq: 1,
	};
}

function isPlainObject(value) {
	return typeof value === "object" && value !== null && !Array.isArray(value);
}

function envelopeError(envelope) {
	if (!isPlainObject(envelope)) {
		return "envelope must be a JSON object";
	}
	const batches = envelope.batches ?? [];
	if (!Array.isArray(batches)) {
		return "envelope.batches must be an array";
	}
	for (const batch of batches) {
		if (!isPlainObject(batch)) {
			return "envelope.batches must contain only batch objects";
		}
	}
	return null;
}

function ingest(state, envelope) {
	const batches = Array.isArray(envelope.batches) ? envelope.batches : [];
	for (const batch of batches) {
		state.batches.push({
			serverSeq: state.nextSeq,
			serverId: envelope.serverId ?? null,
			placeVersion: envelope.placeVersion ?? null,
			relayDropped: envelope.relayDropped ?? 0,
			batch,
		});
		state.nextSeq += 1;
		while (state.batches.length > state.cap) {
			state.batches.shift();
		}
	}
	return batches.length;
}

function tail(state, since) {
	const latest = state.nextSeq - 1;
	const oldest = state.batches.length > 0 ? state.batches[0].serverSeq : state.nextSeq;
	const dropped = since + 1 < oldest ? oldest - since - 1 : 0;
	const batches = state.batches.filter((entry) => entry.serverSeq > since);
	return { batches, latest, dropped };
}

function authorized(apiKey, request) {
	if (apiKey == null) {
		return true;
	}
	const provided = request.headers["x-api-key"];
	if (typeof provided !== "string") {
		return false;
	}
	const expected = Buffer.from(apiKey);
	const received = Buffer.from(provided);
	if (expected.length !== received.length) {
		return false;
	}
	return crypto.timingSafeEqual(expected, received);
}

function sendJson(response, status, body) {
	const payload = JSON.stringify(body);
	response.writeHead(status, {
		"content-type": "application/json",
		"content-length": Buffer.byteLength(payload),
	});
	response.end(payload);
}

function readBody(request, response, onBody) {
	const chunks = [];
	let total = 0;
	let aborted = false;

	request.on("data", (chunk) => {
		if (aborted) {
			return;
		}
		total += chunk.length;
		if (total > MAX_BODY_BYTES) {
			aborted = true;
			sendJson(response, 413, { ok: false, error: "body too large" });
			request.destroy();
			return;
		}
		chunks.push(chunk);
	});
	request.on("end", () => {
		if (!aborted) {
			onBody(Buffer.concat(chunks).toString("utf8"));
		}
	});
}

function createServer(options) {
	const state = createRelayState(options.cap);

	const server = http.createServer((request, response) => {
		const url = new URL(request.url, "http://localhost");

		if (request.method === "POST" && url.pathname === "/ingest") {
			if (!authorized(options.apiKey, request)) {
				sendJson(response, 401, { ok: false, error: "unauthorized" });
				request.resume();
				return;
			}
			readBody(request, response, (body) => {
				let envelope = null;
				try {
					envelope = JSON.parse(body);
				} catch {
					sendJson(response, 400, { ok: false, error: "invalid JSON" });
					return;
				}
				const shapeError = envelopeError(envelope);
				if (shapeError != null) {
					sendJson(response, 400, { ok: false, error: shapeError });
					return;
				}
				const accepted = ingest(state, envelope);
				sendJson(response, 200, { ok: true, accepted, latest: state.nextSeq - 1 });
			});
			return;
		}

		if (request.method === "GET" && url.pathname === "/tail") {
			if (!authorized(options.apiKey, request)) {
				sendJson(response, 401, { ok: false, error: "unauthorized" });
				return;
			}
			const since = Number(url.searchParams.get("since") || 0);
			if (!Number.isInteger(since) || since < 0) {
				sendJson(response, 400, { ok: false, error: "since must be a non-negative integer" });
				return;
			}
			sendJson(response, 200, { ok: true, ...tail(state, since) });
			return;
		}

		if (request.method === "GET" && url.pathname === "/health") {
			sendJson(response, 200, { ok: true, latest: state.nextSeq - 1, count: state.batches.length });
			return;
		}

		sendJson(response, 404, { ok: false, error: "not found" });
	});

	return server;
}

function main() {
	const options = parseArgs(process.argv.slice(2));
	const server = createServer(options);
	server.listen(options.port, "127.0.0.1", () => {
		process.stdout.write(`relay listening on ${server.address().port}\n`);
	});
	return server;
}

if (require.main === module) {
	main();
}

module.exports = {
	createRelayState,
	createServer,
	envelopeError,
	ingest,
	tail,
};
