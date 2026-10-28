## Do Before Pushing

- Rebuild the compiler in debug mode
- `cd tests && efile clean && efile run`
- Make sure all tests pass
- Modify the version in:
    - `build.zig`
    - `builtin.cole`
    - `build.zig.zon`

## If Pushing Minor Version Change

- Update the `cole.yusufenderosmanoglu.tech` website accordingly.

## If Pushing Major Version Change

- Add new version entry to `cole.yusufenderosmanoglu.tech` and create
new language reference.
