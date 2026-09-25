--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStateNames = require(ReplicatedStorage.Shared.FSM.MovementStateNames)
local DeveloperAllowlist = require(ReplicatedStorage.Shared.Constants.DeveloperAllowlist)

local Network = require(script.Parent.Parent.Parent.Network.network)
local DebugOverlayState = require(script.Parent.Parent.Parent.State.DebugOverlayState)
local Sessions = require(script.Parent.Sessions)
local Violations = require(script.Parent.Violations)
local Context = require(script.Parent.Context)

type PlayerSession = Sessions.PlayerSession

-- The F4 overlay's view of the server mirror (docs/MovementSystem.md §10).
local DebugBroadcast = {}

-- Symbol -> the plain string literal Network.MovementDebugState's payload needs
-- (Zap enums are string unions, not Symbols) -- see
-- Shared/FSM/MovementStateNames.luau (unified there during the 2026-09-15
-- cleanup pass; this used to be a second, hand-duplicated copy of the
-- client's own DEBUG_STATE_NAMES in Movement/init.luau).
local DEBUG_STATE_NAMES = MovementStateNames.DebugNames

-- Debug overlay (F4, developer-only, docs/MovementSystem.md): one-way broadcast of this
-- session's mirrored state to the owning client only, so the overlay can flag
-- client/server disagreement instead of only showing the client's own
-- (self-reported) view -- that's the actual point of the panel. Restricted to
-- developers so a normal player's client never even receives this traffic.
--
-- `violations` (docs/MovementSystem.md §10) sends ViolationTracker's bounded history,
-- not just the running count -- `ageSeconds` is computed fresh right here,
-- every broadcast, from this server's own `os.clock()` rather than sending
-- the raw recorded timestamp, since the two machines' clocks aren't
-- comparable (unlike `elapsed`, which is already a duration, not a moment).
function DebugBroadcast.Send(session: PlayerSession)
	if not DeveloperAllowlist.IsDeveloper(session.player) then
		return
	end
	-- Gated on the panel actually being open (docs/MovementSystem.md §4.4,
	-- `docs/MovementSystem.md` §4.4 cleanup), not just on developer status --
	-- this used to fire every Heartbeat to every connected developer
	-- regardless of whether they had F4 open at all, which is exactly the
	-- "no blanket per-Heartbeat network cost" mistake this file's own
	-- optimization standards (§7/§11) warn against for new code.
	if not DebugOverlayState.IsOpen(session.player) then
		return
	end

	local context = Context.Build(session)
	local violation = Violations.GetSpeedRecord(session.player)
	local now = os.clock()

	local violationEntries: { { flatDelta: number, maxDistance: number, elapsed: number, ageSeconds: number } } =
		{}
	if violation then
		for _, entry in ipairs(violation.history) do
			table.insert(violationEntries, {
				flatDelta = entry.flatDelta,
				maxDistance = entry.maxDistance,
				elapsed = entry.elapsed,
				ageSeconds = now - entry.at,
			})
		end
	end

	Network.MovementDebugState.Fire(session.player, {
		state = DEBUG_STATE_NAMES[session.fsm.current],
		runDuration = if context.runDuration then context.runDuration :: number else nil,
		violationCount = if violation then violation.count else 0,
		violations = violationEntries,
	})
end

return DebugBroadcast
