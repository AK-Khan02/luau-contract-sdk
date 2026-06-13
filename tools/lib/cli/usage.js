"use strict";

function usage() {
	return `Luau Contract SDK

Usage:
  luau-contract scan [options]
  luau-contract generate remotes [options]
  luau-contract generate tests [options]
  luau-contract generate all [options]
  luau-contract check generated [options]
  luau-contract verify remotes [options]
  luau-contract migrate scan [options]
  luau-contract migrate suggest [options]
  luau-contract migrate patch [options]
  luau-contract migrate contract [options]
  luau-contract tail --endpoint <url> [options]

Options:
  --root <path>              Project root to scan. Defaults to cwd.
  --config <path>            Config file path. Defaults to luau-contracts.json when present.
  --include <glob>           Include glob. Repeatable. Replaces config include when used.
  --exclude <glob>           Exclude glob. Repeatable. Appends to default/config excludes.
  --format <format>          text, json, sarif, markdown. Repeatable or comma-separated.
  --out <path>               Output path for a single format.
  --out-dir <path>           Directory for multiple report formats.
  --fail-on <severity>       error, warn, or info. Defaults to error.
  --max-warnings <count>     Fail when new warnings exceed count.
  --baseline <path>          Existing JSON report whose findings are allowed.
  --update-baseline <path>   Write the current JSON report for future baseline use.
  --exact                    Load exact contract reports from configured contract modules.
  --contract-module <glob>   Exact contract module glob. Repeatable.
  --check                    Check generated files without writing them.
  --tests-out <path>         Output directory for generated attack tests when generating all.
  --sdk-require <path>       Require path used by generated tests for the SDK.
  --attack-config <path>     JSON fixtures for generated actor-policy attack cases.
  --custom-type-map <path>   JSON map from custom schema names to Luau type names.
  --generated-remotes <path> Include generated wrapper coverage for this directory.
  --generated-tests <path>   Include generated attack-test coverage for this directory.
  --write                    Write migration patches. Defaults to dry-run.
  --contracts-require <path> Require target inserted by migration patch. Use lua:<expr> for raw Luau.
  --system-name <name>       System name for migrate contract drafts.
  --strict-payload           Migration patches reject extra payload fields.
  --luau <path>              Luau executable. Defaults to luau.
  --endpoint <url>           Relay server base URL for tail.
  --api-key <key>            Relay API key sent as x-api-key.
  --since <seq>              Start tailing after this relay sequence number.
  --interval <seconds>       Poll interval for tail. Defaults to 2.
  --once                     Tail once and exit instead of polling.
  --help                     Show this help.
`;
}

module.exports = {
	usage,
};
