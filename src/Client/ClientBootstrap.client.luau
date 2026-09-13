--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Packages.Loader)

local Controllers = Loader.LoadChildren(script.Parent.Controllers)
Loader.SpawnAll(Controllers, "Init")
