"use strict";

const assert = require("node:assert");
const test = require("node:test");
const { fromReport, sanitizeIdentifier } = require("../lib/contractArtifacts");

test("distinct inputs that sanitize identically collide as contract modules", () => {
	assert.throws(
		() => fromReport({
			contracts: [
				{ name: "My-System", remotes: {} },
				{ name: "My_System", remotes: {} },
			],
		}),
		(error) => {
			assert.match(error.message, /Contract module name collision/);
			assert.match(error.message, /My-System/);
			assert.match(error.message, /My_System/);
			return true;
		},
	);
});

test("distinct remote names that sanitize identically collide within a contract", () => {
	assert.throws(
		() => fromReport({
			contracts: [
				{
					name: "Inventory",
					remotes: {
						"Do-Thing": {},
						"Do_Thing": {},
					},
				},
			],
		}),
		(error) => {
			assert.match(error.message, /Remote \(Inventory\) identifier name collision/);
			assert.match(error.message, /Do-Thing/);
			assert.match(error.message, /Do_Thing/);
			return true;
		},
	);
});

test("non-colliding contract and remote names pass without error", () => {
	const artifacts = fromReport({
		contracts: [
			{ name: "InventoryService", remotes: { EquipItem: {}, DropItem: {} } },
			{ name: "MatchService", remotes: { AdvanceRound: {} } },
		],
	});

	assert.deepEqual(
		artifacts.contracts.map((contract) => contract.identifier),
		["InventoryService", "MatchService"],
	);
	assert.deepEqual(
		artifacts.contracts[0].remotes.map((remote) => remote.remoteIdentifier),
		["EquipItem", "DropItem"],
	);
});

test("identically sanitizing remote names in different contracts do not collide", () => {
	// Remote identifiers are scoped per contract: "Do-Thing" and "Do_Thing"
	// in separate contracts land in separate generated files, so this is fine.
	const artifacts = fromReport({
		contracts: [
			{ name: "A", remotes: { "Do-Thing": {} } },
			{ name: "B", remotes: { "Do_Thing": {} } },
		],
	});

	assert.equal(artifacts.contracts.length, 2);
	assert.equal(artifacts.contracts[0].remotes[0].remoteIdentifier, "Do_Thing");
	assert.equal(artifacts.contracts[1].remotes[0].remoteIdentifier, "Do_Thing");
});

test("sanitizeIdentifier still maps non-identifier characters to underscores", () => {
	// Guard against regressions to the underlying transform the collision
	// detection is built on top of.
	assert.equal(sanitizeIdentifier("My-System"), "My_System");
	assert.equal(sanitizeIdentifier("My_System"), "My_System");
	assert.equal(sanitizeIdentifier("123abc"), "abc");
	assert.equal(sanitizeIdentifier("", "Fallback"), "Fallback");
});
