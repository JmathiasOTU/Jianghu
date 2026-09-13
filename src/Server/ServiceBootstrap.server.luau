--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Loader = require(ReplicatedStorage.Packages.Loader)

local Services = Loader.LoadChildren(script.Parent.Services)
Loader.SpawnAll(Services, "Init")
