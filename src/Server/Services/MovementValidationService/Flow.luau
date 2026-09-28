--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local MovementStateGroups = require(ReplicatedStorage.Shared.FSM.MovementStateGroups)
local MovementTuning = require(ReplicatedStorage.Shared.Movement.MovementTuning)
local TraversalMath = require(ReplicatedStorage.Shared.Movement.TraversalMath)
local FlowRules = require(ReplicatedStorage.Shared.Movement.FlowRules)

local Sessions = require(script.Parent.Sessions)

type MovementState = MovementStates.MovementState
type EffectiveMovementConstants = MovementTuning.EffectiveMovementConstants
type PlayerSession = Sessions.PlayerSession

-- The server's own Flow (docs/FLOW.md): gained on its own mirrored
-- transitions, drained on its own clock, never read from the client. Each
-- gain lands up to one claim lag after the client's; draining starts that
-- much later too, so uneven lag between two claims can't leave the server
-- below the client (docs/FLOW.md §3).
local Flow = {}

function Flow.Multiplier(session: PlayerSession, constants: EffectiveMovementConstants): number
	return TraversalMath.FlowMultiplier(session.flow, constants.FlowMaxSpeedBonus)
end

-- For states whose horizontal speed was fixed at a launch or a slide entry:
-- never below the multiplier held since that began, as the client's speed
-- doesn't follow Flow down.
function Flow.HeldMultiplier(session: PlayerSession, constants: EffectiveMovementConstants): number
	return math.max(Flow.Multiplier(session, constants), session.heldFlowMultiplier or 1)
end

-- From `TransitionBookkeeping.OnChanged`, after the landing-grace snapshot.
-- Flow only lives inside a sprint chain (FlowRules): it gains there and is
-- gone the moment the mirror touches down outside Sprint.
function Flow.OnTransition(
	session: PlayerSession,
	next: MovementState,
	constants: EffectiveMovementConstants
)
	session.flowChain = FlowRules.ChainAfter(session.flowChain, next)
	if not session.flowChain then
		session.flow = 0
		session.lastFlowGainAt = nil
	elseif FlowRules.Gains(session.flowChain, next) then
		session.flow = TraversalMath.FlowAfterGain(session.flow, constants.FlowGainPerMove)
		session.lastFlowGainAt = os.clock()
	end
	if MovementStateGroups.FlowHolding[next] then
		session.heldFlowMultiplier = Flow.HeldMultiplier(session, constants)
	elseif MovementStateGroups.Grounded[next] then
		session.heldFlowMultiplier = nil
	end
end

-- Once per Heartbeat, never from a claim handler (which also re-runs the
-- mirror). `claimLag` is `ClaimTiming.ClaimLagSeconds`, passed in because
-- ClaimTiming requires SpeedCaps, which requires this module.
function Flow.Decay(
	session: PlayerSession,
	constants: EffectiveMovementConstants,
	dt: number,
	claimLag: number
)
	if session.flow <= 0 then
		return
	end
	session.flow = TraversalMath.FlowAfterDecay(
		session.flow,
		os.clock() - (session.lastFlowGainAt or 0),
		dt,
		constants.FlowDecayDelaySeconds + claimLag,
		constants.FlowDecayRate
	)
end

return Flow
