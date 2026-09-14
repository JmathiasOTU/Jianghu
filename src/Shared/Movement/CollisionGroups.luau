--!strict
local PhysicsService = game:GetService("PhysicsService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local MovementStates = require(ReplicatedStorage.Shared.FSM.MovementStates)

type MovementState = MovementStates.MovementState

-- Passability while Crouch/Slide is active (docs/MOVEMENT.md §9) is handled
-- via Roblox CollisionGroups, not R6 rig resizing -- R6 has no supported
-- scaling API, and hand-editing Motor6D offsets to shrink the rig would fight
-- docs/ARCHITECTURE.md's "R6 only" stance for no real benefit. Group NAMES are
-- shared here so client and server (and any future level-geometry author) can
-- never drift on what a "crouched" part is called.
--
-- Registration (`PhysicsService:RegisterCollisionGroup`) only ever needs to
-- happen once, server-side -- collision group definitions are part of the
-- DataModel's PhysicsService and replicate to every client automatically, the
-- same way any other server-authored global game state does. A client never
-- calls RegisterGroups.
local CollisionGroups = {
	Default = "Character",
	Crouched = "CharacterCrouched",
}

-- Which states this passability applies to -- CrouchIdle/CrouchWalk/Slide/
-- SlideJump, exactly the four states item 7 of docs/MOVEMENT.md §9 names.
-- Kept as a set here (not duplicated per call site) so client and server can
-- never disagree about which states count, same reasoning as StateRules'
-- own shared Transitions/CanEnter tables.
local CROUCHED_STATES: { [MovementState]: boolean } = {
	[MovementStates.CrouchIdle] = true,
	[MovementStates.CrouchWalk] = true,
	[MovementStates.Slide] = true,
	[MovementStates.SlideJump] = true,
}

function CollisionGroups.RegisterGroups()
	if not RunService:IsServer() then
		return
	end
	-- Idempotent per Roblox's own docs (a no-op if the group already exists),
	-- so calling this once in Init() every server start is safe without a
	-- separate "have I already registered" flag.
	PhysicsService:RegisterCollisionGroup(CollisionGroups.Default)
	PhysicsService:RegisterCollisionGroup(CollisionGroups.Crouched)
end

function CollisionGroups.GroupForState(state: MovementState): string
	return if CROUCHED_STATES[state] then CollisionGroups.Crouched else CollisionGroups.Default
end

-- Applied independently client-side (for local feel -- the owning client
-- simulates its own character's physics, so only ITS OWN write actually
-- affects whether the local player can physically fit through a low gap) and
-- server-side (the authoritative copy every other client's view, and the
-- server's own awareness, is built from), each keyed off that side's OWN
-- mirrored FSM state -- never a client-reported flag, same trust direction as
-- everything else in this system (docs/MOVEMENT.md §9).
function CollisionGroups.Apply(character: Model, state: MovementState)
	local groupName = CollisionGroups.GroupForState(state)
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = groupName
		end
	end
end

return CollisionGroups
