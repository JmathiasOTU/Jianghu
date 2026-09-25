--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementConstants = require(ReplicatedStorage.Shared.Constants.MovementConstants)
local MovementTuning = require(ReplicatedStorage.Shared.Movement.MovementTuning)

local Sessions = require(script.Parent.Sessions)
local SpeedCaps = require(script.Parent.SpeedCaps)

type EffectiveMovementConstants = MovementTuning.EffectiveMovementConstants
type PlayerSession = Sessions.PlayerSession

-- How the server accounts for claims and positions arriving in either
-- order (docs/MovementSystem.md §8.3-§8.4): the claim-lag window, how long
-- a buffered claim has waited, and the speed budget credited for it.
local ClaimTiming = {}

-- How far the server's view of a move can trail the client's own (re-audit
-- N-002): one network leg (server-measured ping, never client-sent) plus the
-- measured claim buffer (`WallRunClaimBufferSeconds`), which already exists
-- because position replication and claims arrive in either order. Capped at
-- one speed window, so a lag-switching client can't stretch it further.
function ClaimTiming.ClaimLagSeconds(session: PlayerSession): number
	local oneWay = math.max(session.player:GetNetworkPing(), 0) / 2
	return math.min(
		oneWay + MovementConstants.WallRunClaimBufferSeconds,
		MovementConstants.SpeedCheckIntervalSeconds
	)
end

-- How long a claim buffered until `pendingUntil` has been waiting.
function ClaimTiming.BufferedFor(pendingUntil: number): number
	return MovementConstants.WallRunClaimBufferSeconds - (pendingUntil - os.clock())
end

-- A claim travels separately from position replication: by the time one is
-- accepted, the client has already moved under the new move for about one
-- network leg. When the accept raises the cap, that stretch was budgeted at
-- the old cap, so the difference is credited for that leg (server-measured
-- ping, never anything the client sends) plus however long the claim waited
-- in a claim buffer. Capped at one speed-check window: anything older belongs
-- to a window that has already been judged.
function ClaimTiming.CreditClaimLatency(
	session: PlayerSession,
	capBefore: number,
	constants: EffectiveMovementConstants,
	bufferedFor: number?
)
	local capAfter = SpeedCaps.EffectiveMaxSpeed(session, constants)
	if capAfter <= capBefore then
		return
	end
	local oneWay = math.max(session.player:GetNetworkPing(), 0) / 2
	local lag = math.min(oneWay + (bufferedFor or 0), MovementConstants.SpeedCheckIntervalSeconds)
	session.speedBudget += (capAfter - capBefore) * lag
end

return ClaimTiming
