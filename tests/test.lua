local Testy = require "testy"

local suites = require "suites"

local function suite(name, tests)
    local s = Testy.Suite.init(name)
    for _, test in ipairs(tests) do
        local execp = "build/c/"..test..".cole.exec"
        s:test(Testy.Test
            .init(test, execp))
    end
    return s
end

local test = Testy.init("Cole_Test")
for name, tests in pairs(suites) do
    test:suite(suite(name, tests))
end

if arg[1] == "record" then
    test:record(arg[2] and {table.unpack(arg, 2)} or nil)
elseif arg[1] == "run" then
    local res = test:run(arg[2] and {table.unpack(arg, 2)} or nil)

    if res then
        if res.fail ~= 0 then
            os.exit(1)
        else
            print(string.format("Total %d suites, %d tests passed.", (function()
                local suitec, tests = 0, 0
                for _, suit in pairs(test.suites) do
                    suitec = suitec + 1
                    for _, _ in pairs(suit.tests) do
                        tests = tests + 1
                    end
                end
                return suitec, tests
            end)()))
            os.exit(0)
        end
    end
end
