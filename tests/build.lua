local Efile = require "efile"

local suites = require "suites"

local exe_path = "../zig-out/debug-linux-x86_64/v0.0.1/cole"
local cflags = " -I ../stdlib --supress-warnings "

local function suite(name, files)
        local steps = { }

        for _, file in ipairs(files) do
            local path = name.."/"..file..".cole"
            table.insert(steps, Efile.Step
                .init(path)
                :dependOnFile(path)
                :action(exe_path..cflags..path.." -o "..file..".cole.exec"))
        end

        return steps
end

local project = Efile.Project
    .init("Cole_Tests")

for name, files in pairs(suites) do
    project:multiStep(suite(name, files))
end

project
    :step(Efile.Step
        .init("build")
        :dependOnSteps((function()
            local steps = { }
            for step, _ in pairs(project.steps) do
                table.insert(steps, step)
            end

            return steps
        end)()))

    :step(Efile.Step
        .init("record", { always_run = true })
        :dependOnStep("build")
        :action("testy record"))

    :step(Efile.Step
        .init("run", { always_run = true })
        :dependOnStep("build")
        :action("testy run"))

print(project:build(arg[1] or "build") or "Success")
