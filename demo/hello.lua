-- A simple Lua demo

local function greet(name)
    print("Hello, " .. name .. "!")
end

greet("Matcha")

-- Variables and types
local count = 42
local pi = 3.14159
local active = true
local items = {"apple", "banana", "cherry"}

-- Control flow
for i, item in ipairs(items) do
    if i > 1 then
        print(i .. ": " .. item)
    end
end

-- Table as object
local editor = {
    name = "Matcha",
    version = 1,
    run = function(self)
        print(self.name .. " v" .. self.version)
    end,
}

editor:run()
