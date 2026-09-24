--!strict
return function(t)
	local StateMachine = t.harness.require("ReplicatedStorage", "Shared", "FSM", "StateMachine")

	local transitions = {
		A = { "B" },
		B = { "A", "C" },
		C = { "A" },
	}

	t.describe("StateMachine", function()
		t.it("follows a legal edge and reports it", function()
			local fsm = StateMachine.new("A", transitions)
			local seen = {}
			fsm.changed:Connect(function(next, previous)
				table.insert(seen, `{previous}->{next}`)
			end)
			t.expect(fsm:RequestTransition("B", {})).toBeTruthy()
			t.expect(fsm.current).toBe("B")
			t.expect(seen[1]).toBe("A->B")
			fsm:Destroy()
		end)

		t.it("rejects an edge that isn't in the topology", function()
			local fsm = StateMachine.new("A", transitions)
			t.expect(fsm:RequestTransition("C", {})).toBeFalsy()
			t.expect(fsm.current).toBe("A")
			fsm:Destroy()
		end)

		t.it("rejects a self-transition", function()
			local fsm = StateMachine.new("A", { A = { "A" } })
			t.expect(fsm:RequestTransition("A", {})).toBeFalsy()
			fsm:Destroy()
		end)

		t.it("consults CanEnter for the target", function()
			local fsm = StateMachine.new("A", transitions, {
				B = function(context)
					return context.allowed
				end,
			})
			t.expect(fsm:RequestTransition("B", { allowed = false })).toBeFalsy()
			t.expect(fsm:RequestTransition("B", { allowed = true })).toBeTruthy()
			fsm:Destroy()
		end)
	end)
end
