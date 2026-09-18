local Efile = require "efile"

local exe_path = "../zig-out/debug-linux-x86_64/v0.0.1/cole"
local cflags = " -I ../stdlib --supress-warnings "

local function suite(name, files)
        local steps = { }

        for _, file in ipairs(files) do
            local path = name.."/"..file..".cole"
            table.insert(steps, Efile.Step
                .init(path)
                :action(exe_path..cflags..path.." -o "..file..".cole.exec"))
        end

        return steps
end

local project = Efile.Project
    .init("Cole_Tests")

    :multiStep(suite("stdlib", {
        "math",
        "string",
    }))

project:step(Efile.Step
    .init("all")
    :dependOnSteps((function()
        local steps = { }
        for step, _ in pairs(project.steps) do
            table.insert(steps, step)
        end

        return steps
    end)()))

print(project:build("all") or "Success")
