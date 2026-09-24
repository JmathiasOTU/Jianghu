--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local LemonSignal = require(ReplicatedStorage.Packages.LemonSignal)

-- Server-only pub/sub channel (docs/ARCHITECTURE.md §2), same shape as
-- CharacterTeleported. The ONE sanctioned way for any server system to make
-- upward travel legitimate beyond the built-in moves (audit M-001, designer
-- answer 2026-09-24): knockback, launch pads, elevators, future Qinggong.
-- Fire with the extra rise in studs the character may now gain above wherever
-- it is right now; MovementValidationService raises that player's vertical
-- ceiling accordingly. Never wired to a client remote -- a client can't grant
-- itself height.
local VerticalAllowanceGranted: LemonSignal.Signal<Player, number> = LemonSignal.new()

return VerticalAllowanceGranted
