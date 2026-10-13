local Efile = require "efile"

local demos = {
    ["raylib"] = {
        "main.cole",
        "raylib.cole",
    },
    
    ["brainfuck"] = {
        "main.cole",
        "cpu.cole",
    },
}

local cole = "cole "

local build_steps = {}

local project = Efile.Project
    .init("demo")
    
for demo, dependencies in pairs(demos) do
    table.insert(build_steps, demo.."-build")

    local step = Efile.Step
        .init(demo.."-build")
        
    for _, dependency in ipairs(dependencies) do
        step:dependOnFile(demo.."/"..dependency)
    end
    
    step:action(cole.."--working "..demo.." -I ../../stdlib -o "..demo.." main.cole")
    
    project:step(step)
    project:step(Efile.Step
        .init(demo)
        :action(demo.."/build/c/"..demo))
end

project:step(Efile.Step
    .init("all")
    :dependOnSteps(build_steps))
        
print(project:build(arg[1] or "all") or "Success")