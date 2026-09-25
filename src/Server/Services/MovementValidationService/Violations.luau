--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ViolationTracker = require(ReplicatedStorage.Shared.Util.ViolationTracker)

local MovementViolation = require(script.Parent.Parent.Parent.Events.MovementViolation)
local Sessions = require(script.Parent.Sessions)
local DebugFlags = require(script.Parent.DebugFlags)

type PlayerSession = Sessions.PlayerSession

-- Every movement correction reports through here (audit M-008): recorded
-- per kind in a bounded ViolationTracker and published on
-- Server/Events/MovementViolation for a future moderation system.
local Violations = {}

local speedViolations = ViolationTracker.new()
-- One tracker per kind: the debug overlay's payload is shaped around the
-- horizontal check's distance/budget/elapsed, and each kind keeps its own
-- count for the moderation event.
local violationTrackers: { [MovementViolation.Kind]: ViolationTracker.ViolationTracker } = {
	Speed = speedViolations,
	VerticalCeiling = ViolationTracker.new(),
	HardLandingEscape = ViolationTracker.new(),
}

-- Every correction reports through here (audit M-008): recorded, then
-- published on MovementViolation for a future moderation system. Policy
-- (flag, kick) deliberately lives with that subscriber, not in this service.
--
-- Every kind prints in Studio playtests: the debug overlay's history only
-- shows Speed, so a vertical or HardLanding snap was otherwise invisible. In
-- a live server a cheater could flood the log at will (audit M-025), so there
-- the record goes to the trackers and the event only.
function Violations.Report(
	session: PlayerSession,
	kind: MovementViolation.Kind,
	detail: { [string]: number }
)
	local violation = violationTrackers[kind]:Record(session.player, detail)
	if DebugFlags.SPEED_SANITY_DEBUG_LOGGING or RunService:IsStudio() then
		local fields = {}
		for key, value in pairs(detail) do
			table.insert(fields, string.format("%s=%.3f", key, value))
		end
		table.sort(fields)
		print(
			string.format(
				"[MovementViolation] %s %s state=%s %s",
				session.player.Name,
				kind,
				tostring(session.fsm.current),
				table.concat(fields, " ")
			)
		)
	end
	MovementViolation:Fire(session.player, kind, detail, violation.count)
end

-- The Speed tracker's record for `player` (count plus bounded history), for
-- the debug overlay broadcast.
function Violations.GetSpeedRecord(player: Player)
	return speedViolations:Get(player)
end

-- Forgets a leaving player in every tracker.
function Violations.ClearPlayer(player: Player)
	for _, tracker in pairs(violationTrackers) do
		tracker:Clear(player)
	end
end

return Violations
