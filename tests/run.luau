--!strict
-- Unit test runner for the pure shared movement modules (audit M-035).
-- Run from the repo root: `lune run tests/run`. Every `tests/specs/*.spec.luau`
-- returns `function(t)` and uses `t.describe`, `t.it` and `t.expect`. Exits
-- non-zero if any test fails, so CI can gate on it.
local fs = require("@lune/fs")
local process = require("@lune/process")

local harness = require("./harness")

type Expectation = {
	toBe: (expected: any) -> (),
	toBeCloseTo: (expected: number, epsilon: number?) -> (),
	toBeAtLeast: (bound: number) -> (),
	toBeAtMost: (bound: number) -> (),
	toBeTruthy: () -> (),
	toBeFalsy: () -> (),
	toThrow: () -> (),
}

local DEFAULT_EPSILON = 1e-6

local function expect(actual: any): Expectation
	local function fail(message: string)
		error(message, 3)
	end
	return {
		toBe = function(expected: any)
			if actual ~= expected then
				fail(`expected {tostring(expected)}, got {tostring(actual)}`)
			end
		end,
		toBeCloseTo = function(expected: number, epsilon: number?)
			if math.abs(actual - expected) > (epsilon or DEFAULT_EPSILON) then
				fail(`expected ~{expected}, got {actual}`)
			end
		end,
		toBeAtLeast = function(bound: number)
			if actual < bound then
				fail(`expected >= {bound}, got {actual}`)
			end
		end,
		toBeAtMost = function(bound: number)
			if actual > bound then
				fail(`expected <= {bound}, got {actual}`)
			end
		end,
		toBeTruthy = function()
			if not actual then
				fail(`expected truthy, got {tostring(actual)}`)
			end
		end,
		toBeFalsy = function()
			if actual then
				fail(`expected falsy, got {tostring(actual)}`)
			end
		end,
		toThrow = function()
			if pcall(actual) then
				fail("expected the function to throw")
			end
		end,
	}
end

local passed = 0
local failures: { string } = {}
local prefix: { string } = {}

local api = {
	harness = harness,
	expect = expect,
	describe = function(name: string, body: () -> ())
		table.insert(prefix, name)
		body()
		table.remove(prefix)
	end,
	it = function(name: string, body: () -> ())
		local fullName = table.concat(prefix, " > ") .. " > " .. name
		local ok, err = pcall(body)
		if ok then
			passed += 1
		else
			table.insert(failures, `{fullName}\n    {tostring(err)}`)
		end
	end,
}

local specDir = "tests/specs"
local specNames = {}
for _, name in ipairs(fs.readDir(specDir)) do
	if string.match(name, "%.spec%.luau$") then
		table.insert(specNames, name)
	end
end
table.sort(specNames)

for _, name in ipairs(specNames) do
	local spec = require(`./specs/{string.gsub(name, "%.luau$", "")}`)
	local ok, err = pcall(spec, api)
	if not ok then
		table.insert(failures, `{name} (failed to load)\n    {tostring(err)}`)
	end
end

for _, failure in ipairs(failures) do
	print(`FAIL {failure}`)
end
print(`{passed} passed, {#failures} failed ({#specNames} spec files)`)
process.exit(if #failures == 0 then 0 else 1)
