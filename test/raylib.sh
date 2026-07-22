clear
cd ..
zig build debug-linux-x86_64 -freference-trace=10
zig-out/debug-linux-x86_64/v0.0.1/jaslc --working test main.jasl -I ../stdlib
cd test/build/c/
