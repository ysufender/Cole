local Testy = require "testy"

local test = Testy
    .init("Cole_Test")

    :suite((function()
        local files = {
            "string"
        }

        local suite = Testy.Suite.init("stdlib", "")

        for _, file in ipairs(files) do
            local execp = "build/c/"..file..".cole.exec"

            suite:test(Testy.Test
                .init(file, execp))
        end

        return suite
    end)())

if arg[1] == "record" then
    test:record()
elseif arg[1] == "run" then
    test:run()
end
