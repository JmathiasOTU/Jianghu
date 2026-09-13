opt server_output = "src/Server/Network/network.luau"
opt client_output = "src/Client/Network/network.luau"
opt casing = "PascalCase"
opt write_checks = true

-- Real events land here as movement/combat systems are built.
-- Every player-initiated combat/movement remote must set a rate limit
-- per docs/ARCHITECTURE.md §10 — see Events docs: https://zap.redblox.dev/config/events

-- Movement (Phase 1) --------------------------------------------------------
--
-- Idle, Walk, and Airborne need no remote: Humanoid state (WalkSpeed, jump, fall)
-- already replicates natively, and MovementValidationService mirrors those
-- transitions passively from that replication.
--
-- Run and Sprint are earned transitions (double-tap dwell / 3s continuous-Run
-- dwell) and are the real exploit surface, so the client explicitly claims them
-- here. The payload is deliberately scoped to only these two states -- Zap's own
-- type validation (write_checks above) then rejects any other claim before it
-- reaches handler logic at all. The server never trusts a client-sent timestamp
-- for the dwell check -- it validates against its own entry-timestamp for when it
-- observed the player enter Run, same lag-compensation principle as parry
-- (docs/ARCHITECTURE.md §4).
--
-- NOTE: Zap has no native per-event rate-limit field (verified against
-- zap.redblox.dev/config/events and /config/options.html, 2026-09-13), despite
-- docs/ARCHITECTURE.md §10 describing rate limits as declared here. Enforced
-- instead via Shared/Util/RateLimiter.luau, wired into MovementValidationService
-- when that lands in Step 2 -- see docs/MOVEMENT.md §5.
type ClaimableMovementState = enum { "Run", "Sprint" }

event RequestMovementTransition = {
	from: Client,
	type: Reliable,
	call: SingleAsync,
	data: ClaimableMovementState,
}
