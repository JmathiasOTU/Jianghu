--!strict

-- `forward`/`backward`/`strafeLeft`/`strafeRight` are the raw WASD axis holds, kept
-- alongside the resolved `direction` because Sprint's continuation rule cares about
-- the raw forward key specifically (tolerates forward-diagonal, drops on backpedal
-- or pure strafe) -- see docs/MOVEMENT.md §2. `direction` is the camera-relative,
-- world-space vector actually driving movement.
export type MoveIntent = {
	direction: Vector3,
	forward: boolean,
	backward: boolean,
	strafeLeft: boolean,
	strafeRight: boolean,
}

export type MovementContext = {
	moveIntent: MoveIntent,
	grounded: boolean,
	runDuration: number?,
}

return {}
