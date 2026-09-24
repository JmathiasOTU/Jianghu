--!strict
-- Loads this repo's Roblox-style modules under Lune (audit M-035). Shared
-- movement code requires instances (`require(ReplicatedStorage.Shared.X)`,
-- `require(script.Parent.Y)`), which plain Lune can't resolve, so this maps
-- the Rojo tree onto the files it was built from and runs each module with
-- the handful of Roblox globals the pure shared code actually touches. Only
-- for pure logic: nothing here simulates physics, raycasts or replication.
local fs = require("@lune/fs")
local luau = require("@lune/luau")
local roblox = require("@lune/roblox")
local serde = require("@lune/serde")
local task = require("@lune/task")

-- Rojo mappings from default.project.json that shared code reaches through.
local SERVICE_ROOTS: { [string]: { [string]: string } } = {
	ReplicatedStorage = {
		Shared = "src/Shared",
		Packages = "Packages",
	},
}

local MODULE_EXTENSIONS = { ".luau", ".lua" }

-- Lune's fs calls can yield, and path resolution runs inside an __index
-- metamethod where yielding is illegal -- so both mapped trees are scanned
-- (and every source read) once, up front, and resolution is pure lookups.
local dirs: { [string]: boolean } = {}
local sources: { [string]: string } = {}
-- A Wally package folder whose own default.project.json points its tree at a
-- single file (LemonSignal: `src/LemonSignal.lua`), exactly as Rojo builds it.
local projectRedirects: { [string]: string } = {}

local function scan(path: string)
	dirs[path] = true
	for _, name in ipairs(fs.readDir(path)) do
		local child = path .. "/" .. name
		if fs.isDir(child) then
			scan(child)
		elseif string.match(name, "%.luau?$") then
			sources[child] = fs.readFile(child)
		elseif name == "default.project.json" then
			local project = serde.decode("json", fs.readFile(child))
			local treePath = project.tree and project.tree["$path"]
			if type(treePath) == "string" then
				projectRedirects[path] = path .. "/" .. treePath
			end
		end
	end
end

for _, roots in pairs(SERVICE_ROOTS) do
	for _, path in pairs(roots) do
		scan(path)
	end
end

local fsView = {
	isDir = function(path: string): boolean
		return dirs[path] == true
	end,
	isFile = function(path: string): boolean
		return sources[path] ~= nil
	end,
	readFile = function(path: string): string
		return assert(sources[path], `harness: no source for {path}`)
	end,
}

local function moduleFile(dirPath: string): string?
	for _, extension in ipairs(MODULE_EXTENSIONS) do
		local candidate = dirPath .. "/init" .. extension
		if fsView.isFile(candidate) then
			return candidate
		end
	end
	return nil
end

local nodeMeta = {}
local nodePaths: { [any]: string } = setmetatable({}, { __mode = "k" }) :: any

local function makeNode(path: string): any
	local node = setmetatable({}, nodeMeta)
	nodePaths[node] = path
	return node
end

local function parentPath(path: string): string
	return string.match(path, "^(.*)/[^/]+$") or path
end

local function resolveChild(path: string, name: string): any
	local base = if fsView.isFile(path) then parentPath(path) else path
	local child = base .. "/" .. name
	if fsView.isDir(child) then
		return makeNode(child)
	end
	for _, extension in ipairs(MODULE_EXTENSIONS) do
		if fsView.isFile(child .. extension) then
			return makeNode(child .. extension)
		end
	end
	error(`harness: no module or folder "{name}" under {base}`, 3)
end

nodeMeta.__index = function(node: any, key: string): any
	local path = nodePaths[node]
	if key == "Parent" then
		local ownDir = if fsView.isFile(path) and string.match(path, "/init%.luau?$")
			then parentPath(path)
			else path
		return makeNode(parentPath(ownDir))
	elseif key == "WaitForChild" or key == "FindFirstChild" then
		return function(self: any, name: string)
			return resolveChild(nodePaths[self], name)
		end
	end
	return resolveChild(path, key)
end

local function serviceNode(roots: { [string]: string }): any
	return setmetatable({}, {
		__index = function(_, name: string)
			local path = roots[name]
			if path then
				return makeNode(path)
			end
			error(`harness: service has no mapped child "{name}"`, 2)
		end,
	})
end

-- Services the shared code only touches at call time (Workspace casts,
-- PhysicsService registration) get an inert stub.
local game = {
	GetService = function(_self: any, name: string): any
		local roots = SERVICE_ROOTS[name]
		if roots then
			return serviceNode(roots)
		end
		return setmetatable({}, {
			__index = function()
				return function() end
			end,
		})
	end,
}

local RaycastParams = {
	new = function(): any
		return {}
	end,
}

-- LemonSignal creates one BindableEvent at load only to borrow the native
-- Connect/Disconnect it uses for RBXScriptSignals; pure Lua signals never
-- touch it. Anything else asking for an Instance is outside this harness.
local Instance = {
	new = function(className: string): any
		assert(className == "BindableEvent", `harness: Instance.new("{className}") unsupported`)
		local event = {}
		function event.Connect(_self: any, _callback: any)
			return {
				Disconnect = function() end,
			}
		end
		return {
			Event = event,
			Destroy = function() end,
		}
	end,
}

local cache: { [string]: any } = {}
local loading: { [string]: boolean } = {}

local requireNode: (node: any) -> any

local function loadFile(filePath: string, scriptNode: any): any
	if cache[filePath] ~= nil then
		return cache[filePath]
	end
	assert(not loading[filePath], `harness: require cycle through {filePath}`)
	loading[filePath] = true

	local environment = {
		game = game,
		script = scriptNode,
		require = requireNode,
		task = task,
		Vector3 = roblox.Vector3,
		CFrame = roblox.CFrame,
		Enum = roblox.Enum,
		Region3 = roblox.Region3,
		RaycastParams = RaycastParams,
		Instance = Instance,
	}
	local chunk = luau.load(fsView.readFile(filePath), {
		debugName = filePath,
		environment = environment,
	})
	local result = chunk()
	loading[filePath] = nil
	cache[filePath] = result
	return result
end

requireNode = function(node: any): any
	local path = nodePaths[node]
	assert(path, "harness: require() expects a module node")
	if fsView.isDir(path) then
		local redirect = projectRedirects[path]
		if redirect then
			return loadFile(redirect, node)
		end
		local file = moduleFile(path)
		assert(file, `harness: folder {path} has no init module`)
		return loadFile(file, node)
	end
	return loadFile(path, node)
end

local Harness = {}

Harness.game = game

-- `Harness.require("ReplicatedStorage", "Shared", "Movement", "StateRules")`
function Harness.require(service: string, ...: string): any
	local node = game:GetService(service)
	for _, name in ipairs({ ... }) do
		node = node[name]
	end
	return requireNode(node)
end

return Harness
