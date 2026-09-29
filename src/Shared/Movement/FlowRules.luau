--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)
local MovementStateGroups = require(ReplicatedStorage.Shared.FSM.MovementStateGroups)

type MovementState = MovementStates.MovementState

-- Flow only exists inside a sprint chain (designer, 2026-09-28;
-- docs/MovementSystem.md §4.9): the chain starts on entering Sprint, survives
-- every airborne and slide state after it, and ends on touching down in any
-- other grounded state.
-- Shared so the client and the server mirror end it on the same edges.
local FlowRules = {}

function FlowRules.ChainAfter(inChain: boolean, next: MovementState): boolean
	if next == MovementStates.Sprint then
		return true
	elseif MovementStateGroups.Grounded[next] then
		return false
	end
	return inChain
end

-- Whether entering `next` adds Flow, given the chain state after the transition.
function FlowRules.Gains(inChain: boolean, next: MovementState): boolean
	return inChain and MovementStateGroups.FlowBuilding[next] == true
end

return FlowRules
