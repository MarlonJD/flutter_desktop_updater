# Windows ABI 2.7 compatibility fixtures

These files are frozen predecessor inputs for the Windows native ABI contract.
They are exact fixtures, not examples, and their bytes are covered by
`SHA256SUMS`.

## Provenance

- `desktop_updater_native_c.h` and `desktop_updater_version.h` are copied from
  baseline commit `2f91208f0de95b9656b0ce2a28258e70a2920b86`.
- `prepare-v2-probe.c` is the C source compatibility probe for the same
  baseline header. It binds the frozen `desktop_updater_prepare_install_v2`
  declaration and must keep compiling against only this fixture directory.
- `dotnet-probe/PrepareV2Probe.csproj` and `dotnet-probe/Program.cs` are the
  .NET source compatibility probe for the same ABI shape.

Future 3.0 work may reject these predecessor contracts at runtime, but Task 1
keeps their exact source-level predecessor ABI fixtures named and reproducible.
