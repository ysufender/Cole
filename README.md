# Cole: A Comptime Oriented Language

Cole is a statically typed, ahead of time compiled programming language that transpiles
into a lowered version of C. Cole supports types as values and compile time code execution,
and handles generics through comptime function execution.

Although it is usable as is right now, Cole far from being a completely finished project.
There are a couple bugs with compile time execution, typechecking, and C interop. But I'm
working steadily to fix and implement them as soon as I can.

For more information about the language and installation, see the [Cole website](https://cole.yusufenderosmanoglu.tech)

## Sample

(from [demo/raylib/main.cole](demo/raylib/main.cole))

```rust
import std::memory::allocator as Allocator;
import std::string as String;
import std::c as C;
import std::io::console as Console;
import std::math as Math;

import extra::ini as INI;
import extra::filewatch as FW;

import raylib as RayLib;

/*
 * Types
 */
let Player = struct {
    x    : mut float,
    y    : mut float,
    w    : float,
    h    : float,
    score: mut u32,
};

let Ball = struct {
    x: mut float,
    y: mut float,
    bx: mut float,
    by: mut float,
    r: float,
}; 

let main = fn (args: [][]u8) -> i32 {
    let _ini: mut any = INI::loadFile(C::Allocator, "demo/raylib/settings.ini");
    if _ini.tag != @Ok {
        Console::error("Failed to load settings.");
        return 1;
    }
    let ini: mut any = _ini.Ok;

    let iniWatcher: mut any = FW::createWatcher("demo/raylib/settings.ini");

    let WIDTH : mut float = getSettingOrelse(ini.&, "window", "width", 640);
    let HEIGHT: mut float = getSettingOrelse(ini.&, "window", "height", 480);

    let player: mut Player = (20, 100, 20, 70, 0);
    let cpu: mut Player = (cast(WIDTH-35), 100, 20, 70, 0);
    let ball: mut Ball = (WIDTH/2.0 - 10.0, 120.0, -1.0, -1.0, 10.0);

    RayLib::InitWindow(cast(WIDTH), cast(HEIGHT), "Pong");
    RayLib::SetTargetFPS(60);

    while !RayLib::WindowShouldClose() {
        // Load INI
        if FW::poll(iniWatcher.&) {
            _ini = INI::loadFile(C::Allocator, "demo/raylib/settings.ini");
            if _ini.tag == @Ok {
                ini = _ini.Ok;
            }
        }

        // Poll Events
        let direction = 
            if (RayLib::IsKeyDown(RayLib::KeyboardKey::W) or RayLib::IsKeyDown(RayLib::KeyboardKey::UP)) -1.0
            else if (RayLib::IsKeyDown(RayLib::KeyboardKey::S) or RayLib::IsKeyDown(RayLib::KeyboardKey::DOWN)) 1.0
            else 0.0;
            ...
    }
    ...
}


```

## Contributing

Check out the [CONTRIBUTING.md](./CONTRIBUTING.md) and [BUG_REPORT.md](./BUG_REPORT.md)

## Testing

There is a small test suite under `tests/`, written in the [Testy](https://codeberg.org/ysufender/Testy)
and [Efile](https://codeberg.org/ysufender/Efile) frameworks of mine.

You can run the tests by first changing your working directory to `tests/`
and then executing `efile run`.

If you wish to record the current outputs, you can use `efile record`.

If you want to just build the tests, you can use `efile build`.
