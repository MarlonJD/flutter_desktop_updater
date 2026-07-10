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
