using DesktopUpdater.Native;

var configuration = new DesktopUpdaterConfiguration(
    new Uri("https://updates.example.test/app-archive.json"),
    "com.example.native-contract",
    "2.7.0",
    270,
    "2.7.0",
    "windows",
    "stable",
    "external-dotnet-consumer",
    true,
    new Dictionary<string, byte[]>
    {
        ["native-contract-stable"] = Enumerable.Repeat((byte)1, 32).ToArray(),
    },
    (_, _) => true,
    _ => new Dictionary<string, string>());

if (configuration.MaximumMetadataBytes != 4 * 1024 * 1024 ||
    DesktopUpdaterOutcome.NoUpdate.ToString() != "NoUpdate")
{
    return 1;
}

Console.WriteLine("DesktopUpdater.Native runtime API compiled.");
return 0;
