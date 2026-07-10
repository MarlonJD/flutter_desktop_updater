using System.Runtime.InteropServices;
using System.Text;

namespace DesktopUpdater.Native;

/// <summary>Typed result categories shared by every preview runtime.</summary>
public enum DesktopUpdaterOutcome
{
    /// <summary>No eligible release was selected.</summary>
    NoUpdate,
    /// <summary>An eligible release is available.</summary>
    UpdateAvailable,
    /// <summary>The application must direct the user to a fresh installer.</summary>
    FreshInstallRequired,
    /// <summary>The runtime is older than the descriptor minimum.</summary>
    UnsupportedMinimumUpdater,
    /// <summary>The host does not satisfy the descriptor minimum OS.</summary>
    UnsupportedMinimumOS,
    /// <summary>The installation identity is outside the rollout cohort.</summary>
    RolloutIneligible,
    /// <summary>The selected artifact kind is not implemented.</summary>
    UnsupportedArtifactKind,
    /// <summary>The descriptor is invalid or does not match its index item.</summary>
    InvalidDescriptor,
    /// <summary>Descriptor signature verification failed.</summary>
    SignatureFailure,
    /// <summary>The descriptor package ID does not match the application.</summary>
    PackageIdentityMismatch,
    /// <summary>Metadata or artifact transport failed.</summary>
    DownloadFailure,
    /// <summary>Artifact length or SHA-256 verification failed.</summary>
    ArtifactIntegrityFailure,
    /// <summary>Archive entries or extraction limits were unsafe.</summary>
    UnsafeArchive,
    /// <summary>The verified artifact could not be staged.</summary>
    StagingFailure,
    /// <summary>The native install helper rejected the handoff.</summary>
    InstallHandoffFailure,
}

/// <summary>Resolves whether the current host satisfies a minimum OS value.</summary>
public delegate bool MinimumOSResolver(string platform, string minimumOS);

/// <summary>Returns application-owned headers for one exact request URL.</summary>
public delegate IReadOnlyDictionary<string, string> RequestHeadersProvider(Uri url);

/// <summary>Validated application-owned configuration for the preview runtime.</summary>
public sealed class DesktopUpdaterConfiguration
{
    /// <summary>Default maximum bytes for one index or descriptor.</summary>
    public const long DefaultMaximumMetadataBytes = 4L * 1024L * 1024L;
    /// <summary>Default maximum number of archive entries.</summary>
    public const long DefaultMaximumArchiveEntries = 100_000L;
    /// <summary>Default maximum total uncompressed archive bytes.</summary>
    public const long DefaultMaximumUncompressedBytes = 8L * 1024L * 1024L * 1024L;
    /// <summary>Default maximum uncompressed bytes for one archive entry.</summary>
    public const long DefaultMaximumSingleEntryBytes = 4L * 1024L * 1024L * 1024L;

    /// <summary>Creates and validates an application-owned runtime configuration.</summary>
    public DesktopUpdaterConfiguration(
        Uri appArchiveUrl,
        string expectedPackageId,
        string currentVersion,
        long? currentBuildNumber,
        string currentUpdaterVersion,
        string platform,
        string channel,
        string? installationIdentity,
        bool requireDescriptorSignature,
        IReadOnlyDictionary<string, byte[]> pinnedPublicKeysById,
        MinimumOSResolver minimumOSResolver,
        RequestHeadersProvider requestHeadersProvider,
        TimeSpan? downloadTimeout = null,
        long maximumMetadataBytes = DefaultMaximumMetadataBytes,
        long maximumArchiveEntries = DefaultMaximumArchiveEntries,
        long maximumUncompressedBytes = DefaultMaximumUncompressedBytes,
        long maximumSingleEntryBytes = DefaultMaximumSingleEntryBytes)
    {
        if (appArchiveUrl is null)
        {
            throw new ArgumentNullException(nameof(appArchiveUrl));
        }
        if (pinnedPublicKeysById is null)
        {
            throw new ArgumentNullException(nameof(pinnedPublicKeysById));
        }
        if (minimumOSResolver is null)
        {
            throw new ArgumentNullException(nameof(minimumOSResolver));
        }
        if (requestHeadersProvider is null)
        {
            throw new ArgumentNullException(nameof(requestHeadersProvider));
        }
        if (!appArchiveUrl.IsAbsoluteUri)
        {
            throw new ArgumentException("appArchiveUrl must be absolute.", nameof(appArchiveUrl));
        }
        ValidateText(expectedPackageId, nameof(expectedPackageId));
        ValidateText(currentVersion, nameof(currentVersion));
        ValidateText(currentUpdaterVersion, nameof(currentUpdaterVersion));
        ValidateText(platform, nameof(platform));
        ValidateText(channel, nameof(channel));
        if (currentBuildNumber < 0)
        {
            throw new ArgumentOutOfRangeException(
                nameof(currentBuildNumber),
                "currentBuildNumber must not be negative.");
        }
        if (requireDescriptorSignature && pinnedPublicKeysById.Count == 0)
        {
            throw new ArgumentException(
                "At least one pinned public key is required.",
                nameof(pinnedPublicKeysById));
        }
        foreach (var key in pinnedPublicKeysById)
        {
            if (string.IsNullOrWhiteSpace(key.Key) || key.Value is null || key.Value.Length != 32)
            {
                throw new ArgumentException(
                    "Pinned Ed25519 keys require a non-empty ID and 32 bytes.",
                    nameof(pinnedPublicKeysById));
            }
        }

        var resolvedTimeout = downloadTimeout ?? TimeSpan.FromSeconds(30);
        if (resolvedTimeout <= TimeSpan.Zero)
        {
            throw new ArgumentOutOfRangeException(
                nameof(downloadTimeout),
                "downloadTimeout must be greater than zero.");
        }
        if (maximumMetadataBytes <= 0 ||
            maximumArchiveEntries <= 0 ||
            maximumUncompressedBytes <= 0 ||
            maximumSingleEntryBytes <= 0)
        {
            throw new ArgumentOutOfRangeException(
                nameof(maximumMetadataBytes),
                "Runtime safety limits must be greater than zero.");
        }

        AppArchiveUrl = appArchiveUrl;
        ExpectedPackageId = expectedPackageId;
        CurrentVersion = currentVersion;
        CurrentBuildNumber = currentBuildNumber;
        CurrentUpdaterVersion = currentUpdaterVersion;
        Platform = platform;
        Channel = channel;
        InstallationIdentity = installationIdentity;
        RequireDescriptorSignature = requireDescriptorSignature;
        PinnedPublicKeysById = pinnedPublicKeysById.ToDictionary(
            entry => entry.Key,
            entry => entry.Value.ToArray());
        MinimumOSResolver = minimumOSResolver;
        RequestHeadersProvider = requestHeadersProvider;
        DownloadTimeout = resolvedTimeout;
        MaximumMetadataBytes = maximumMetadataBytes;
        MaximumArchiveEntries = maximumArchiveEntries;
        MaximumUncompressedBytes = maximumUncompressedBytes;
        MaximumSingleEntryBytes = maximumSingleEntryBytes;
    }

    /// <summary>Hosted app-archive URL.</summary>
    public Uri AppArchiveUrl { get; }
    /// <summary>Application-owned package identity.</summary>
    public string ExpectedPackageId { get; }
    /// <summary>Currently installed semantic version.</summary>
    public string CurrentVersion { get; }
    /// <summary>Currently installed platform build number, when available.</summary>
    public long? CurrentBuildNumber { get; }
    /// <summary>Current DesktopUpdater runtime version.</summary>
    public string CurrentUpdaterVersion { get; }
    /// <summary>Requested release platform.</summary>
    public string Platform { get; }
    /// <summary>Requested release channel.</summary>
    public string Channel { get; }
    /// <summary>Stable application-owned rollout identity.</summary>
    public string? InstallationIdentity { get; }
    /// <summary>Whether descriptor signatures are mandatory.</summary>
    public bool RequireDescriptorSignature { get; }
    /// <summary>Ed25519 public keys indexed by pinned key ID.</summary>
    public IReadOnlyDictionary<string, byte[]> PinnedPublicKeysById { get; }
    /// <summary>Application callback for minimum-OS policy.</summary>
    public MinimumOSResolver MinimumOSResolver { get; }
    /// <summary>Application callback for exact-request headers.</summary>
    public RequestHeadersProvider RequestHeadersProvider { get; }
    /// <summary>Per-request transport timeout.</summary>
    public TimeSpan DownloadTimeout { get; }
    /// <summary>Maximum bytes for one index or descriptor.</summary>
    public long MaximumMetadataBytes { get; }
    /// <summary>Maximum archive entry count.</summary>
    public long MaximumArchiveEntries { get; }
    /// <summary>Maximum total uncompressed archive bytes.</summary>
    public long MaximumUncompressedBytes { get; }
    /// <summary>Maximum uncompressed bytes for one archive entry.</summary>
    public long MaximumSingleEntryBytes { get; }

    private static void ValidateText(string value, string parameterName)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new ArgumentException(
                $"{parameterName} must not be empty.",
                parameterName);
        }
    }
}

/// <summary>One typed result returned by the preview native runtime.</summary>
public sealed class DesktopUpdaterRuntimeResult
{
    internal DesktopUpdaterRuntimeResult(
        DesktopUpdaterOutcome outcome,
        string message,
        string? releaseVersion,
        string? artifactKind,
        string? stagedPath,
        string? supportPolicyStatus,
        bool mandatory,
        long? selectedBuildNumber,
        string? selectedPlatform,
        string? selectedChannel,
        string? freshInstallUrl,
        string? freshInstallMessage)
    {
        Outcome = outcome;
        Message = message;
        ReleaseVersion = releaseVersion;
        ArtifactKind = artifactKind;
        StagedPath = stagedPath;
        SupportPolicyStatus = supportPolicyStatus;
        Mandatory = mandatory;
        SelectedBuildNumber = selectedBuildNumber;
        SelectedPlatform = selectedPlatform;
        SelectedChannel = selectedChannel;
        FreshInstallUrl = freshInstallUrl;
        FreshInstallMessage = freshInstallMessage;
    }

    /// <summary>Typed runtime outcome.</summary>
    public DesktopUpdaterOutcome Outcome { get; }
    /// <summary>Human-readable non-secret detail.</summary>
    public string Message { get; }
    /// <summary>Selected release version, when a descriptor was verified.</summary>
    public string? ReleaseVersion { get; }
    /// <summary>Selected artifact kind, when a descriptor was verified.</summary>
    public string? ArtifactKind { get; }
    /// <summary>Disposable staged directory, after staging succeeds.</summary>
    public string? StagedPath { get; }
    /// <summary>Current support-policy state: supported, warning, or blocked.</summary>
    public string? SupportPolicyStatus { get; }
    /// <summary>Whether the selected release is mandatory.</summary>
    public bool Mandatory { get; }
    /// <summary>Selected platform build number, when present.</summary>
    public long? SelectedBuildNumber { get; }
    /// <summary>Selected release platform.</summary>
    public string? SelectedPlatform { get; }
    /// <summary>Selected release channel.</summary>
    public string? SelectedChannel { get; }
    /// <summary>Fresh-install URL when in-app installation is not allowed.</summary>
    public string? FreshInstallUrl { get; }
    /// <summary>Optional fresh-install explanation.</summary>
    public string? FreshInstallMessage { get; }
}

/// <summary>Stateful check, verification, staging, and helper-handoff client.</summary>
public sealed class DesktopUpdaterClient : IDisposable
{
    private const uint AbiVersion = 1;
    private static readonly ReleaseHeadersDelegate ReleaseHeadersCallback =
        ReleaseHeaders;
    private static readonly IntPtr ReleaseHeadersPointer =
        Marshal.GetFunctionPointerForDelegate(ReleaseHeadersCallback);

    private readonly DesktopUpdaterConfiguration _configuration;
    private readonly MinimumOSDelegate _minimumOS;
    private readonly HeadersProviderDelegate _headersProvider;
    private GCHandle _applicationHandle;
    private IntPtr _client;
    private bool _disposed;

    /// <summary>Creates a native client and copies all configuration values.</summary>
    public DesktopUpdaterClient(DesktopUpdaterConfiguration configuration)
    {
        _configuration = configuration ??
            throw new ArgumentNullException(nameof(configuration));
        _minimumOS = ResolveMinimumOS;
        _headersProvider = ProvideHeaders;
        _applicationHandle = GCHandle.Alloc(this);

        var allocations = new List<IntPtr>();
        NativeRuntimeResult result = default;
        var resultReceived = false;
        try
        {
            var keys = configuration.PinnedPublicKeysById.ToArray();
            var nativeKeys = new NativePinnedKey[keys.Length];
            for (var index = 0; index < keys.Length; index++)
            {
                var id = AllocateUtf8(keys[index].Key, allocations);
                var bytes = Marshal.AllocHGlobal(keys[index].Value.Length);
                allocations.Add(bytes);
                Marshal.Copy(keys[index].Value, 0, bytes, keys[index].Value.Length);
                nativeKeys[index] = new NativePinnedKey
                {
                    PublicKeyIdUtf8 = id,
                    PublicKeyBytes = bytes,
                    PublicKeyLength = (nuint)keys[index].Value.Length,
                };
            }
            var keyArray = AllocateStructArray(nativeKeys, allocations);
            var nativeConfiguration = new NativeConfiguration
            {
                AbiVersion = AbiVersion,
                StructSize = (nuint)Marshal.SizeOf<NativeConfiguration>(),
                AppArchiveUrlUtf8 = AllocateUtf8(
                    configuration.AppArchiveUrl.AbsoluteUri,
                    allocations),
                ExpectedPackageIdUtf8 = AllocateUtf8(
                    configuration.ExpectedPackageId,
                    allocations),
                CurrentVersionUtf8 = AllocateUtf8(
                    configuration.CurrentVersion,
                    allocations),
                CurrentBuildNumber = configuration.CurrentBuildNumber ?? 0,
                HasCurrentBuildNumber = configuration.CurrentBuildNumber.HasValue ? 1 : 0,
                CurrentUpdaterVersionUtf8 = AllocateUtf8(
                    configuration.CurrentUpdaterVersion,
                    allocations),
                PlatformUtf8 = AllocateUtf8(configuration.Platform, allocations),
                ChannelUtf8 = AllocateUtf8(configuration.Channel, allocations),
                InstallationIdentityUtf8 = configuration.InstallationIdentity is null
                    ? IntPtr.Zero
                    : AllocateUtf8(configuration.InstallationIdentity, allocations),
                RequireDescriptorSignature = configuration.RequireDescriptorSignature ? 1 : 0,
                PinnedPublicKeys = keyArray,
                PinnedPublicKeyCount = (nuint)nativeKeys.Length,
                MinimumOSResolver = _minimumOS,
                RequestHeadersProvider = _headersProvider,
                ApplicationContext = GCHandle.ToIntPtr(_applicationHandle),
                DownloadTimeoutMilliseconds = checked(
                    (ulong)configuration.DownloadTimeout.TotalMilliseconds),
                MaximumMetadataBytes = configuration.MaximumMetadataBytes,
                MaximumArchiveEntries = configuration.MaximumArchiveEntries,
                MaximumUncompressedBytes = configuration.MaximumUncompressedBytes,
                MaximumSingleEntryBytes = configuration.MaximumSingleEntryBytes,
            };

            result = NativeMethods.Create(ref nativeConfiguration);
            resultReceived = true;
            if (result.Ok == 0 || result.Client == IntPtr.Zero)
            {
                throw new DesktopUpdaterException(
                    ReadUtf8(result.MessageUtf8) ??
                    "The native runtime client could not be created.");
            }
            _client = result.Client;
            result.Client = IntPtr.Zero;
        }
        catch
        {
            if (_applicationHandle.IsAllocated)
            {
                _applicationHandle.Free();
            }
            throw;
        }
        finally
        {
            if (resultReceived)
            {
                NativeMethods.ResultFree(ref result);
            }
            FreeAllocations(allocations);
        }
    }

    /// <summary>Downloads and verifies discovery metadata and the descriptor.</summary>
    public DesktopUpdaterRuntimeResult CheckForUpdate()
    {
        ThrowIfDisposed();
        var result = NativeMethods.CheckForUpdate(_client);
        return ConsumeResult(ref result);
    }

    /// <summary>Downloads, verifies, and stages the selected artifact.</summary>
    public DesktopUpdaterRuntimeResult DownloadVerifyAndStage(
        string downloadDirectory,
        string stagingDirectory)
    {
        ThrowIfDisposed();
        var allocations = new List<IntPtr>();
        try
        {
            var request = new NativeStageRequest
            {
                AbiVersion = AbiVersion,
                StructSize = (nuint)Marshal.SizeOf<NativeStageRequest>(),
                DownloadDirectoryUtf8 = AllocateUtf8(
                    downloadDirectory,
                    allocations),
                StagingDirectoryUtf8 = AllocateUtf8(
                    stagingDirectory,
                    allocations),
            };
            var result = NativeMethods.DownloadVerifyAndStage(
                _client,
                ref request);
            return ConsumeResult(ref result);
        }
        finally
        {
            FreeAllocations(allocations);
        }
    }

    /// <summary>Hands the staged update to the versioned install helper.</summary>
    public DesktopUpdaterRuntimeResult InstallAndRelaunch(
        IReadOnlyList<string> removedFiles,
        string? diagnosticsLogPath)
    {
        ThrowIfDisposed();
        if (removedFiles is null)
        {
            throw new ArgumentNullException(nameof(removedFiles));
        }
        var allocations = new List<IntPtr>();
        try
        {
            var removedPointers = new IntPtr[removedFiles.Count];
            for (var index = 0; index < removedFiles.Count; index++)
            {
                removedPointers[index] = AllocateUtf8(
                    removedFiles[index] ?? throw new ArgumentException(
                        "Removed file paths must not contain null values.",
                        nameof(removedFiles)),
                    allocations);
            }
            var pointerArray = AllocatePointerArray(
                removedPointers,
                allocations);
            var request = new NativeInstallRequest
            {
                AbiVersion = AbiVersion,
                StructSize = (nuint)Marshal.SizeOf<NativeInstallRequest>(),
                DiagnosticsLogPathUtf8 = diagnosticsLogPath is null
                    ? IntPtr.Zero
                    : AllocateUtf8(diagnosticsLogPath, allocations),
                RemovedFilesUtf8 = pointerArray,
                RemovedFileCount = (nuint)removedPointers.Length,
            };
            var result = NativeMethods.InstallAndRelaunch(_client, ref request);
            return ConsumeResult(ref result);
        }
        finally
        {
            FreeAllocations(allocations);
        }
    }

    /// <inheritdoc />
    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }
        _disposed = true;
        if (_client != IntPtr.Zero)
        {
            NativeMethods.ClientFree(_client);
            _client = IntPtr.Zero;
        }
        if (_applicationHandle.IsAllocated)
        {
            _applicationHandle.Free();
        }
        GC.SuppressFinalize(this);
    }

    private int ResolveMinimumOS(
        IntPtr applicationContext,
        IntPtr platformUtf8,
        IntPtr minimumOSUtf8)
    {
        try
        {
            return _configuration.MinimumOSResolver(
                ReadUtf8(platformUtf8) ?? string.Empty,
                ReadUtf8(minimumOSUtf8) ?? string.Empty)
                ? 1
                : 0;
        }
        catch
        {
            return 0;
        }
    }

    private NativeHeaderList ProvideHeaders(
        IntPtr applicationContext,
        IntPtr urlUtf8)
    {
        try
        {
            var url = new Uri(ReadUtf8(urlUtf8) ?? string.Empty);
            var values = _configuration.RequestHeadersProvider(url);
            var lease = new HeaderLease(values);
            var handle = GCHandle.Alloc(lease);
            return new NativeHeaderList
            {
                AbiVersion = AbiVersion,
                StructSize = (nuint)Marshal.SizeOf<NativeHeaderList>(),
                Entries = lease.Entries,
                EntryCount = (nuint)lease.Count,
                ReleaseContext = GCHandle.ToIntPtr(handle),
                Release = ReleaseHeadersPointer,
            };
        }
        catch
        {
            return new NativeHeaderList
            {
                AbiVersion = AbiVersion,
                StructSize = (nuint)Marshal.SizeOf<NativeHeaderList>(),
            };
        }
    }

    private static void ReleaseHeaders(
        IntPtr releaseContext,
        IntPtr entries,
        nuint entryCount)
    {
        if (releaseContext == IntPtr.Zero)
        {
            return;
        }
        var handle = GCHandle.FromIntPtr(releaseContext);
        if (handle.Target is HeaderLease lease)
        {
            lease.Dispose();
        }
        handle.Free();
    }

    private static DesktopUpdaterRuntimeResult ConsumeResult(
        ref NativeRuntimeResult result)
    {
        try
        {
            if (result.Ok == 0)
            {
                throw new DesktopUpdaterException(
                    ReadUtf8(result.MessageUtf8) ??
                    "The native runtime call failed without an error message.");
            }
            return new DesktopUpdaterRuntimeResult(
                result.Outcome,
                ReadUtf8(result.MessageUtf8) ?? string.Empty,
                ReadUtf8(result.ReleaseVersionUtf8),
                ReadUtf8(result.ArtifactKindUtf8),
                ReadUtf8(result.StagedPathUtf8),
                ReadUtf8(result.SupportPolicyStatusUtf8),
                result.Mandatory != 0,
                result.HasSelectedBuildNumber != 0
                    ? result.SelectedBuildNumber
                    : null,
                ReadUtf8(result.SelectedPlatformUtf8),
                ReadUtf8(result.SelectedChannelUtf8),
                ReadUtf8(result.FreshInstallUrlUtf8),
                ReadUtf8(result.FreshInstallMessageUtf8));
        }
        finally
        {
            NativeMethods.ResultFree(ref result);
        }
    }

    private void ThrowIfDisposed()
    {
        if (_disposed || _client == IntPtr.Zero)
        {
            throw new ObjectDisposedException(nameof(DesktopUpdaterClient));
        }
    }

    private static IntPtr AllocateUtf8(
        string value,
        ICollection<IntPtr> allocations)
    {
        if (value is null)
        {
            throw new ArgumentNullException(nameof(value));
        }
        var bytes = Encoding.UTF8.GetBytes(value + "\0");
        var pointer = Marshal.AllocHGlobal(bytes.Length);
        Marshal.Copy(bytes, 0, pointer, bytes.Length);
        allocations.Add(pointer);
        return pointer;
    }

    private static IntPtr AllocateStructArray<T>(
        IReadOnlyList<T> values,
        ICollection<IntPtr> allocations)
        where T : struct
    {
        if (values.Count == 0)
        {
            return IntPtr.Zero;
        }
        var size = Marshal.SizeOf<T>();
        var pointer = Marshal.AllocHGlobal(checked(size * values.Count));
        allocations.Add(pointer);
        for (var index = 0; index < values.Count; index++)
        {
            Marshal.StructureToPtr(
                values[index],
                IntPtr.Add(pointer, index * size),
                false);
        }
        return pointer;
    }

    private static IntPtr AllocatePointerArray(
        IReadOnlyList<IntPtr> values,
        ICollection<IntPtr> allocations)
    {
        if (values.Count == 0)
        {
            return IntPtr.Zero;
        }
        var pointer = Marshal.AllocHGlobal(
            checked(IntPtr.Size * values.Count));
        allocations.Add(pointer);
        for (var index = 0; index < values.Count; index++)
        {
            Marshal.WriteIntPtr(pointer, index * IntPtr.Size, values[index]);
        }
        return pointer;
    }

    private static void FreeAllocations(IEnumerable<IntPtr> allocations)
    {
        foreach (var pointer in allocations.Reverse())
        {
            if (pointer != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(pointer);
            }
        }
    }

    private static string? ReadUtf8(IntPtr value)
    {
        if (value == IntPtr.Zero)
        {
            return null;
        }
        var length = 0;
        while (Marshal.ReadByte(value, length) != 0)
        {
            length++;
        }
        var bytes = new byte[length];
        Marshal.Copy(value, bytes, 0, length);
        return Encoding.UTF8.GetString(bytes);
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int MinimumOSDelegate(
        IntPtr applicationContext,
        IntPtr platformUtf8,
        IntPtr minimumOSUtf8);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate NativeHeaderList HeadersProviderDelegate(
        IntPtr applicationContext,
        IntPtr urlUtf8);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void ReleaseHeadersDelegate(
        IntPtr releaseContext,
        IntPtr entries,
        nuint entryCount);

    [StructLayout(LayoutKind.Sequential)]
    private struct NativePinnedKey
    {
        public IntPtr PublicKeyIdUtf8;
        public IntPtr PublicKeyBytes;
        public nuint PublicKeyLength;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeHeader
    {
        public IntPtr NameUtf8;
        public IntPtr ValueUtf8;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeHeaderList
    {
        public uint AbiVersion;
        public nuint StructSize;
        public IntPtr Entries;
        public nuint EntryCount;
        public IntPtr ReleaseContext;
        public IntPtr Release;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeConfiguration
    {
        public uint AbiVersion;
        public nuint StructSize;
        public IntPtr AppArchiveUrlUtf8;
        public IntPtr ExpectedPackageIdUtf8;
        public IntPtr CurrentVersionUtf8;
        public long CurrentBuildNumber;
        public int HasCurrentBuildNumber;
        public IntPtr CurrentUpdaterVersionUtf8;
        public IntPtr PlatformUtf8;
        public IntPtr ChannelUtf8;
        public IntPtr InstallationIdentityUtf8;
        public int RequireDescriptorSignature;
        public IntPtr PinnedPublicKeys;
        public nuint PinnedPublicKeyCount;
        public MinimumOSDelegate MinimumOSResolver;
        public HeadersProviderDelegate RequestHeadersProvider;
        public IntPtr ApplicationContext;
        public ulong DownloadTimeoutMilliseconds;
        public long MaximumMetadataBytes;
        public long MaximumArchiveEntries;
        public long MaximumUncompressedBytes;
        public long MaximumSingleEntryBytes;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRuntimeResult
    {
        public uint AbiVersion;
        public nuint StructSize;
        public int Ok;
        public DesktopUpdaterOutcome Outcome;
        public IntPtr Client;
        public IntPtr MessageUtf8;
        public IntPtr ReleaseVersionUtf8;
        public IntPtr ArtifactKindUtf8;
        public IntPtr StagedPathUtf8;
        public IntPtr SupportPolicyStatusUtf8;
        public int Mandatory;
        public int HasSelectedBuildNumber;
        public long SelectedBuildNumber;
        public IntPtr SelectedPlatformUtf8;
        public IntPtr SelectedChannelUtf8;
        public IntPtr FreshInstallUrlUtf8;
        public IntPtr FreshInstallMessageUtf8;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeStageRequest
    {
        public uint AbiVersion;
        public nuint StructSize;
        public IntPtr DownloadDirectoryUtf8;
        public IntPtr StagingDirectoryUtf8;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeInstallRequest
    {
        public uint AbiVersion;
        public nuint StructSize;
        public IntPtr DiagnosticsLogPathUtf8;
        public IntPtr RemovedFilesUtf8;
        public nuint RemovedFileCount;
    }

    private sealed class HeaderLease : IDisposable
    {
        private readonly List<IntPtr> _allocations = new();

        public HeaderLease(IReadOnlyDictionary<string, string> values)
        {
            var headers = values.Select(entry => new NativeHeader
            {
                NameUtf8 = AllocateUtf8(entry.Key, _allocations),
                ValueUtf8 = AllocateUtf8(entry.Value, _allocations),
            }).ToArray();
            Entries = AllocateStructArray(headers, _allocations);
            Count = headers.Length;
        }

        public IntPtr Entries { get; }
        public int Count { get; }

        public void Dispose()
        {
            FreeAllocations(_allocations);
            _allocations.Clear();
        }
    }

    private static class NativeMethods
    {
        [DllImport(
            "desktop_updater_runtime",
            EntryPoint = "desktop_updater_runtime_client_create_v1",
            ExactSpelling = true,
            CallingConvention = CallingConvention.Cdecl)]
        internal static extern NativeRuntimeResult Create(
            ref NativeConfiguration configuration);

        [DllImport(
            "desktop_updater_runtime",
            EntryPoint = "desktop_updater_runtime_client_check_for_update_v1",
            ExactSpelling = true,
            CallingConvention = CallingConvention.Cdecl)]
        internal static extern NativeRuntimeResult CheckForUpdate(IntPtr client);

        [DllImport(
            "desktop_updater_runtime",
            EntryPoint = "desktop_updater_runtime_client_download_verify_and_stage_v1",
            ExactSpelling = true,
            CallingConvention = CallingConvention.Cdecl)]
        internal static extern NativeRuntimeResult DownloadVerifyAndStage(
            IntPtr client,
            ref NativeStageRequest request);

        [DllImport(
            "desktop_updater_runtime",
            EntryPoint = "desktop_updater_runtime_client_install_and_relaunch_v1",
            ExactSpelling = true,
            CallingConvention = CallingConvention.Cdecl)]
        internal static extern NativeRuntimeResult InstallAndRelaunch(
            IntPtr client,
            ref NativeInstallRequest request);

        [DllImport(
            "desktop_updater_runtime",
            EntryPoint = "desktop_updater_runtime_client_free_v1",
            ExactSpelling = true,
            CallingConvention = CallingConvention.Cdecl)]
        internal static extern void ClientFree(IntPtr client);

        [DllImport(
            "desktop_updater_runtime",
            EntryPoint = "desktop_updater_runtime_result_free_v1",
            ExactSpelling = true,
            CallingConvention = CallingConvention.Cdecl)]
        internal static extern void ResultFree(ref NativeRuntimeResult result);
    }
}
