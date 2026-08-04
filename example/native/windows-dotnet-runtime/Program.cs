using DesktopUpdater.Native;

if (!args.Contains("--smoke", StringComparer.Ordinal))
{
    var compileConfiguration = Configuration(
        new Uri("https://updates.example.test/app-archive.json"),
        Enumerable.Repeat((byte)1, 32).ToArray());
    if (compileConfiguration.MaximumMetadataBytes != 4 * 1024 * 1024 ||
        DesktopUpdaterOutcome.NoUpdate.ToString() != "NoUpdate")
    {
        return 1;
    }
    Console.WriteLine("DesktopUpdater.Native runtime API compiled.");
    return 0;
}

var options = Options.Parse(args);
var publicKey = Convert.FromBase64String(options.Required("--public-key-base64"));
if (publicKey.Length != 32)
{
    throw new InvalidOperationException("Smoke Ed25519 public key must contain 32 bytes.");
}
var configuration = Configuration(
    new Uri(options.Required("--app-archive-url"), UriKind.Absolute),
    publicKey,
    options.Required("--package-id"));
using var client = new DesktopUpdaterClient(configuration);
var check = client.CheckForUpdate();
if (check.Outcome != DesktopUpdaterOutcome.UpdateAvailable)
{
    throw new InvalidOperationException(
        $"check_for_update failed: {check.Outcome} {check.Message}");
}
var smokeRoot = options.Required("--smoke-root");
var staged = client.DownloadVerifyAndStage(
    Path.Combine(smokeRoot, "downloads"),
    Path.Combine(smokeRoot, "staging"));
if (staged.Outcome != DesktopUpdaterOutcome.UpdateAvailable ||
    string.IsNullOrWhiteSpace(staged.StagedPath))
{
    throw new InvalidOperationException(
        $"download_verify_and_stage failed: {staged.Outcome} {staged.Message}");
}
Directory.CreateDirectory(smokeRoot);
File.WriteAllLines(
    Path.Combine(smokeRoot, "runtime-diagnostics.log"),
    new[]
    {
        $"check {check.Outcome} {check.ReleaseVersion}",
        $"stage {staged.Outcome} {staged.ArtifactKind} {staged.StagedPath}",
    });
var transactionId = Guid.NewGuid().ToString("D");
File.WriteAllText(Path.Combine(smokeRoot, "transaction-id"), transactionId);
var prepared = client.PrepareInstall(transactionId, Array.Empty<string>());
if (prepared.Outcome != DesktopUpdaterOutcome.UpdateAvailable)
{
    throw new InvalidOperationException(
        $"prepare_install failed: {prepared.Outcome} {prepared.Message}");
}
var committed = client.CommitAfterExit();
if (committed.Outcome != DesktopUpdaterOutcome.UpdateAvailable)
{
    throw new InvalidOperationException(
        $"commit_after_exit failed: {committed.Outcome} {committed.Message}");
}
Console.WriteLine(
    $"prepare_install committed {prepared.ReleaseVersion} from {prepared.ArtifactKind}");
return 0;

static DesktopUpdaterConfiguration Configuration(
    Uri archiveUrl,
    byte[] publicKey,
    string packageId = "com.example.native-runtime-smoke")
{
    return new DesktopUpdaterConfiguration(
        archiveUrl,
        packageId,
        "3.0.0",
        270,
        "3.0.0",
        "windows",
        "stable",
        "windows-native-runtime-smoke",
        new Dictionary<string, byte[]>
        {
            ["native-runtime-smoke-stable"] = publicKey,
        },
        (_, _) => true,
        _ => new Dictionary<string, string>());
}

sealed class Options
{
    private readonly Dictionary<string, string> _values;

    private Options(Dictionary<string, string> values)
    {
        _values = values;
    }

    public static Options Parse(string[] arguments)
    {
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        for (var index = 0; index < arguments.Length; index++)
        {
            if (arguments[index] == "--smoke")
            {
                continue;
            }
            if (!arguments[index].StartsWith("--", StringComparison.Ordinal) ||
                index + 1 >= arguments.Length)
            {
                throw new ArgumentException($"Invalid smoke argument: {arguments[index]}");
            }
            values.Add(arguments[index], arguments[++index]);
        }
        return new Options(values);
    }

    public string Required(string name)
    {
        return _values.TryGetValue(name, out var value) &&
               !string.IsNullOrWhiteSpace(value)
            ? value
            : throw new ArgumentException($"Missing required smoke argument {name}.");
    }
}
