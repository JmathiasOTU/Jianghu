--!strict

export type MoveIntent = {
	direction: Vector3,
}

export type MovementContext = {
	humanoid: Humanoid,
	moveIntent: MoveIntent,
	grounded: boolean,
	runDuration: number?,
}

return {}
