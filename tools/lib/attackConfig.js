"use strict";

const fs = require("node:fs");
const path = require("node:path");

function assertPlainObject(value, message) {
	if (value == null || typeof value !== "object" || Array.isArray(value)) {
		throw new Error(message);
	}
}

function normalizeActorConfig(actorName, actorConfig) {
	assertPlainObject(actorConfig, `attack config actor ${actorName} must be an object`);
	return {
		valid: actorConfig.valid,
		invalid: actorConfig.invalid,
	};
}

function normalizeAttackConfig(config) {
	if (config == null) {
		return {
			actors: {},
		};
	}

	assertPlainObject(config, "attack config must be a JSON object");
	const actors = {};
	for (const [actorName, actorConfig] of Object.entries(config.actors || {})) {
		actors[actorName] = normalizeActorConfig(actorName, actorConfig);
	}
	return {
		actors,
	};
}

function loadAttackConfig(projectRoot, configPath) {
	if (!configPath) {
		return normalizeAttackConfig(null);
	}
	const absolutePath = path.resolve(projectRoot, configPath);
	const rawConfig = JSON.parse(fs.readFileSync(absolutePath, "utf8"));
	return normalizeAttackConfig(rawConfig);
}

module.exports = {
	loadAttackConfig,
	normalizeAttackConfig,
};
