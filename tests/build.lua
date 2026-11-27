local Efile = require "efile"

local suites = require "suites"

local cole_build = arg[1] or
    "debug"
    -- "safe"
    -- "fast"

local cole_backend = arg[2] or
    "QBE"
    -- "C"

local cole_version = "v0.2.0"

local exe_path = string.format("../zig-out/cole-%s-%s-linux-x86_64", cole_version, cole_build)

local cflags = " -I ../stdlib --supress-warnings --backend "..cole_backend.." "

local function suite(name, files)
        local steps = { }

        for _, file in ipairs(files) do
            local path = name.."/"..file..".cole"
            table.insert(steps, Efile.Step
                .init(path)
                :dependOnFile(path)
                :dependOnStep("build-cole")
                :pre("mkdir -p .testy/.cache/"..name)
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
        .init("build-cole")
        :action(string.format("zig build %s-linux-x86_64", cole_build)))

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
        :action("testy "..cole_backend.." record"))

    :step(Efile.Step
        .init("run", { always_run = true })
        :dependOnStep("build")
        :action("testy "..cole_backend.." run"))

    :step(Efile.Step
        .init("clean")
        :action("rm -rf build")
        :action("rm -rf .testy/.cache"))

print(project:build(arg[3] or "build") or "Success")
