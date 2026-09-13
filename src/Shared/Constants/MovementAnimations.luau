--!strict

-- AnimationId slots for LocomotionAnimator (Client/Controllers/Movement/Presentation).
-- All nil until real animations are uploaded -- same "don't guess placeholder
-- values" rule as MovementConstants (see commit a31e6d9, docs/MOVEMENT.md §7).
-- LocomotionAnimator skips loading/playing any slot left nil, so this module can
-- ship empty without breaking anything.
export type DirectionalAnimationSet = {
	Forward: string?,
	ForwardRight: string?,
	Right: string?,
	BackRight: string?,
	Back: string?,
	BackLeft: string?,
	Left: string?,
	ForwardLeft: string?,
}

local function emptyDirectionalSet(): DirectionalAnimationSet
	return {
		Forward = nil,
		ForwardRight = nil,
		Right = nil,
		BackRight = nil,
		Back = nil,
		BackLeft = nil,
		Left = nil,
		ForwardLeft = nil,
	}
end

local MovementAnimations = {
	-- Single non-directional clip: not moving, no facing-relative blend needed.
	Idle = nil :: string?,

	-- Full 8-directional sets, facing-relative (docs/MOVEMENT.md §1/§4) -- which
	-- one plays depends on the angle between current facing and move direction,
	-- not on world-space direction.
	Walk = emptyDirectionalSet(),
	Run = emptyDirectionalSet(),

	-- Single clip, not 8-directional: Sprint is forward-only by construction (§2)
	-- -- backpedal/pure-strafe drop you out of Sprint before a non-forward Sprint
	-- animation would ever be needed.
	Sprint = nil :: string?,
}

return MovementAnimations
