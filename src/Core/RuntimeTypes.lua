--!strict

local TaskScheduler = require("../Roblox/TaskScheduler")

export type DiagnosticsSink = {
	record: (unknown, unknown?) -> unknown,
}

export type Request = {
	actor: unknown?,
	player: unknown?,
	payload: unknown?,
	input: unknown?,
	context: { [unknown]: unknown }?,
	diagnostics: DiagnosticsSink?,
	session: unknown?,
	sessionName: string?,
	states: { [string]: unknown }?,
	expectedRevision: unknown?,
	revision: unknown?,
	remote: string?,
}

export type SessionResolver = (unknown) -> unknown
export type SessionMap = { [string]: unknown | SessionResolver }
export type ActionHandler = (unknown, Request?) -> unknown
export type TapHandlers = {
	started: ((unknown) -> ())?,
	settled: ((unknown) -> ())?,
}
export type Middleware = (unknown, unknown) -> unknown
export type UseOptions = {
	actions: { string }?,
}

export type Config = {
	diagnostics: DiagnosticsSink?,
	sessions: SessionMap?,
	lifecycleSessions: SessionMap?,
	scheduler: TaskScheduler.Scheduler?,
}

export type NormalizedRequest = {
	action: string,
	actor: unknown?,
	payload: unknown?,
	context: { [unknown]: unknown },
	diagnostics: DiagnosticsSink?,
	session: unknown?,
	sessionName: string?,
	states: { [string]: unknown }?,
	expectedRevision: unknown?,
	remote: string?,
}

export type PipelineInfo = {
	action: string,
	actor: unknown?,
	payload: unknown?,
	remote: string?,
	validated: boolean?,
	diagnostics: DiagnosticsSink?,
}

export type RuntimeData = {
	_system: unknown,
	_diagnostics: DiagnosticsSink,
	_handlers: { [string]: ActionHandler },
	_sessions: SessionMap,
	_connections: { [string]: unknown },
	_boundRemotes: { [string]: boolean },
	_scheduler: TaskScheduler.Scheduler?,
	_asyncGate: unknown?,
	_taps: { [unknown]: TapHandlers },
	_middleware: { unknown },
	_destroyed: boolean,
}

return {}
