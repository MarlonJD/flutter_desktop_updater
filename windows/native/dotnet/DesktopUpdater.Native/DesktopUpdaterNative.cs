using System.Runtime.InteropServices;
using System.Text;

namespace DesktopUpdater.Native;

/// <summary>Signed installer elevation policy.</summary>
public enum DesktopUpdaterElevationPolicy
{
    /// <summary>Elevate only when the verified target requires it.</summary>
    Auto = 0,
    /// <summary>Always request elevation unless already elevated.</summary>
    Always = 1,
    /// <summary>Never request elevation and reject unwritable targets.</summary>
    Never = 2,
}

/// <summary>Complete verified context for a staged helper-only install.</summary>
public sealed class DesktopUpdaterInstallRequest
{
    /// <summary>Creates a complete staged-install request.</summary>
    public DesktopUpdaterInstallRequest(
        string stagingPath,
        IReadOnlyList<string> removedFiles,
        string? diagnosticsLogPath,
        string expectedProvenanceSha256,
        string expectedArtifactSha256,
        IReadOnlyList<string> allowedSignerThumbprints,
        DesktopUpdaterElevationPolicy requiresElevation,
        string installRoot,
        string executableRelativePath,
        string expectedPackageId)
    {
        StagingPath = RequireText(stagingPath, nameof(stagingPath));
        RemovedFiles = CopyStrings(removedFiles, nameof(removedFiles));
        DiagnosticsLogPath = diagnosticsLogPath;
        ExpectedProvenanceSha256 = RequireSha256(
            expectedProvenanceSha256,
            nameof(expectedProvenanceSha256));
        ExpectedArtifactSha256 = RequireSha256(
            expectedArtifactSha256,
            nameof(expectedArtifactSha256));
        AllowedSignerThumbprints = CopySha256Values(
            allowedSignerThumbprints,
            nameof(allowedSignerThumbprints));
        if (!Enum.IsDefined(typeof(DesktopUpdaterElevationPolicy), requiresElevation))
        {
            throw new ArgumentOutOfRangeException(nameof(requiresElevation));
        }
        RequiresElevation = requiresElevation;
        InstallRoot = RequireText(installRoot, nameof(installRoot));
        ExecutableRelativePath = RequireText(
            executableRelativePath,
            nameof(executableRelativePath));
        ExpectedPackageId = RequireText(
            expectedPackageId,
            nameof(expectedPackageId));
    }

    /// <summary>Application-owned staged bundle or installer directory.</summary>
    public string StagingPath { get; }
    /// <summary>Application-relative paths removed by complete-tree updates.</summary>
    public IReadOnlyList<string> RemovedFiles { get; }
    /// <summary>
    /// Compatibility-only diagnostics path. Protocol-v1 standalone helpers
    /// use their fixed platform log rather than this caller-selected path.
    /// </summary>
    public string? DiagnosticsLogPath { get; }
    /// <summary>Retained SHA-256 of the canonical stage provenance marker.</summary>
    public string ExpectedProvenanceSha256 { get; }
    /// <summary>SHA-256 of the verified release artifact.</summary>
    public string ExpectedArtifactSha256 { get; }
    /// <summary>Allowed Authenticode signer SHA-256 thumbprints.</summary>
    public IReadOnlyList<string> AllowedSignerThumbprints { get; }
    /// <summary>Signed Inno elevation behavior.</summary>
    public DesktopUpdaterElevationPolicy RequiresElevation { get; }
    /// <summary>Canonical current application root.</summary>
    public string InstallRoot { get; }
    /// <summary>Running executable path relative to the application root.</summary>
    public string ExecutableRelativePath { get; }
    /// <summary>Verified application package identity.</summary>
    public string ExpectedPackageId { get; }

    private static string RequireText(string? value, string parameterName)
    {
        if (string.IsNullOrWhiteSpace(value))
        {
            throw new ArgumentException(
                "A non-empty value is required.",
                parameterName);
        }
        return value!;
    }

    private static string RequireSha256(string? value, string parameterName)
    {
        if (value is null || value.Length != 64)
        {
            throw new ArgumentException(
                "A lowercase 64-character SHA-256 value is required.",
                parameterName);
        }
        foreach (var character in value)
        {
            if (!((character >= '0' && character <= '9') ||
                  (character >= 'a' && character <= 'f')))
            {
                throw new ArgumentException(
                    "A lowercase 64-character SHA-256 value is required.",
                    parameterName);
            }
        }
        return value;
    }

    private static IReadOnlyList<string> CopyStrings(
        IReadOnlyList<string>? values,
        string parameterName)
    {
        if (values is null)
        {
            throw new ArgumentNullException(parameterName);
        }
        var copy = new string[values.Count];
        for (var index = 0; index < values.Count; index++)
        {
            copy[index] = RequireText(values[index], parameterName);
        }
        return copy;
    }

    private static IReadOnlyList<string> CopySha256Values(
        IReadOnlyList<string>? values,
        string parameterName)
    {
        if (values is null)
        {
            throw new ArgumentNullException(parameterName);
        }
        var copy = new string[values.Count];
        for (var index = 0; index < values.Count; index++)
        {
            copy[index] = RequireSha256(
                values[index]?.ToLowerInvariant(),
                parameterName);
        }
        return copy;
    }
}

/// <summary>Authoritative native helper transaction state.</summary>
public enum DesktopUpdaterInstallTransactionState
{
    /// <summary>No authoritative transaction was found.</summary>
    Unknown = 0,
    /// <summary>The helper durably reserved the target.</summary>
    Prepared = 1,
    /// <summary>The helper accepted commit ownership.</summary>
    CommitAccepted = 2,
    /// <summary>The install and relaunch transaction completed.</summary>
    Completed = 3,
    /// <summary>The reservation was cancelled before mutation.</summary>
    Cancelled = 4,
    /// <summary>The reservation expired before commit.</summary>
    Expired = 5,
    /// <summary>The helper completed rollback.</summary>
    RolledBack = 6,
    /// <summary>The helper requires operator recovery.</summary>
    ManualActionRequired = 7,
}

/// <summary>Stable result category returned by the native helper.</summary>
public enum DesktopUpdaterInstallTransactionResultCode
{
    /// <summary>No result has been recorded.</summary>
    None = 0,
    /// <summary>The requested transition was accepted.</summary>
    Accepted = 1,
    /// <summary>The requested operation succeeded.</summary>
    Succeeded = 2,
    /// <summary>The helper rejected the request.</summary>
    Rejected = 3,
    /// <summary>The packaged helper endpoint is unavailable.</summary>
    EndpointUnavailable = 4,
    /// <summary>Endpoint or caller authentication failed.</summary>
    AuthenticationFailed = 5,
    /// <summary>The helper response failed validation.</summary>
    InvalidResponse = 6,
    /// <summary>Authoritative recovery is required.</summary>
    RecoveryRequired = 7,
    /// <summary>
    /// Installation reached a verified terminal state, but the best-effort
    /// at-most-once application relaunch was not durably confirmed.
    /// </summary>
    RelaunchFailure = 8,
}

/// <summary>One validated helper-owned transaction snapshot.</summary>
public sealed class DesktopUpdaterInstallTransactionStatus
{
    internal DesktopUpdaterInstallTransactionStatus(
        string transactionId,
        DesktopUpdaterInstallTransactionState state,
        DesktopUpdaterInstallTransactionResultCode resultCode,
        string detail,
        string responseDigestSha256,
        string helperEndpointIdentitySha256)
    {
        TransactionId = transactionId;
        State = state;
        ResultCode = resultCode;
        Detail = detail;
        ResponseDigestSha256 = responseDigestSha256;
        HelperEndpointIdentitySha256 = helperEndpointIdentitySha256;
    }

    /// <summary>Lowercase UUID identifying the helper transaction.</summary>
    public string TransactionId { get; }
    /// <summary>Current authoritative transaction state.</summary>
    public DesktopUpdaterInstallTransactionState State { get; }
    /// <summary>Stable result category.</summary>
    public DesktopUpdaterInstallTransactionResultCode ResultCode { get; }
    /// <summary>Redacted native detail.</summary>
    public string Detail { get; }
    /// <summary>SHA-256 binding the helper response.</summary>
    public string ResponseDigestSha256 { get; }
    /// <summary>SHA-256 identity of the authenticated helper endpoint.</summary>
    public string HelperEndpointIdentitySha256 { get; }
    /// <summary>
    /// Whether the atomic resolver retained this caller and requires it to
    /// exit before recovery can continue.
    /// </summary>
    public bool AwaitsCallerExit =>
        State == DesktopUpdaterInstallTransactionState.Prepared &&
        ResultCode ==
            DesktopUpdaterInstallTransactionResultCode.RecoveryRequired;
}

/// <summary>Caller-owned lease for one durable native helper reservation.</summary>
public sealed class DesktopUpdaterInstallReservation : IDisposable
{
    internal DesktopUpdaterInstallReservation(
        DesktopUpdaterReservationSafeHandle handle,
        DesktopUpdaterInstallTransactionStatus preparedStatus)
    {
        Handle = handle;
        PreparedStatus = preparedStatus;
    }

    internal DesktopUpdaterReservationSafeHandle Handle { get; }
    /// <summary>Validated status returned with this reservation.</summary>
    public DesktopUpdaterInstallTransactionStatus PreparedStatus { get; }
    /// <summary>Lowercase UUID identifying the helper transaction.</summary>
    public string TransactionId => PreparedStatus.TransactionId;

    /// <summary>Cancels an abandoned reservation and releases its handle.</summary>
    public void Dispose()
    {
        Handle.Dispose();
    }
}

internal sealed class DesktopUpdaterReservationSafeHandle : SafeHandle
{
    internal DesktopUpdaterReservationSafeHandle()
        : base(IntPtr.Zero, true)
    {
    }

    internal DesktopUpdaterReservationSafeHandle(IntPtr value)
        : this()
    {
        SetHandle(value);
    }

    public override bool IsInvalid => handle == IntPtr.Zero;

    protected override bool ReleaseHandle()
    {
        DesktopUpdaterNative.ReleaseReservationHandle(handle);
        return true;
    }
}

/// <summary>Schedules installation through the versioned native updater ABI.</summary>
public static class DesktopUpdaterNative
{
    private const uint AbiVersion = 1;

    /// <summary>Schedules a staged update and relaunches the current app.</summary>
    /// <param name="stagingPath">The staged bundle directory, or null for restart only.</param>
    /// <param name="removedFiles">App-relative paths to remove before overlay.</param>
    /// <param name="diagnosticsLogPath">Compatibility-only path; standalone helpers use the Windows Event Log.</param>
    /// <param name="installRoot">Canonical current application root.</param>
    /// <param name="executableRelativePath">Running executable relative to the application root.</param>
    /// <param name="expectedPackageId">Verified application package identity.</param>
    /// <exception cref="DesktopUpdaterException">The native helper rejected the request.</exception>
    public static void ScheduleInstallAndRelaunch(
        string? stagingPath,
        IReadOnlyList<string> removedFiles,
        string? diagnosticsLogPath,
        string? installRoot = null,
        string? executableRelativePath = null,
        string? expectedPackageId = null)
    {
        if (removedFiles is null)
        {
            throw new ArgumentNullException(nameof(removedFiles));
        }
        if (stagingPath is not null)
        {
            throw new ArgumentException(
                "Staged installs require verified provenance; use the " +
                "DesktopUpdaterInstallRequest overload.",
                nameof(stagingPath));
        }
        _ = ScheduleInstallAndRelaunchCore(
            stagingPath,
            removedFiles,
            diagnosticsLogPath,
            null,
            null,
            Array.Empty<string>(),
            DesktopUpdaterElevationPolicy.Never,
            installRoot,
            executableRelativePath,
            expectedPackageId,
            transactionId: null,
            prepareOnly: false);
    }

    /// <summary>Schedules a complete verified staged update.</summary>
    public static void ScheduleInstallAndRelaunch(
        DesktopUpdaterInstallRequest request)
    {
        if (request is null)
        {
            throw new ArgumentNullException(nameof(request));
        }
        _ = ScheduleInstallAndRelaunchCore(
            request.StagingPath,
            request.RemovedFiles,
            request.DiagnosticsLogPath,
            request.ExpectedProvenanceSha256,
            request.ExpectedArtifactSha256,
            request.AllowedSignerThumbprints,
            request.RequiresElevation,
            request.InstallRoot,
            request.ExecutableRelativePath,
            request.ExpectedPackageId,
            transactionId: null,
            prepareOnly: false);
    }

    /// <summary>Prepares a durable helper reservation without exiting.</summary>
    public static DesktopUpdaterInstallReservation PrepareInstall(
        DesktopUpdaterInstallRequest request)
    {
        if (request is null)
        {
            throw new ArgumentNullException(nameof(request));
        }
        return ScheduleInstallAndRelaunchCore(
            request.StagingPath,
            request.RemovedFiles,
            request.DiagnosticsLogPath,
            request.ExpectedProvenanceSha256,
            request.ExpectedArtifactSha256,
            request.AllowedSignerThumbprints,
            request.RequiresElevation,
            request.InstallRoot,
            request.ExecutableRelativePath,
            request.ExpectedPackageId,
            transactionId: null,
            prepareOnly: true) ?? throw new DesktopUpdaterException(
                "The native helper did not return a reservation.");
    }

    /// <summary>
    /// Prepares a durable helper reservation using a caller-persisted ID.
    /// </summary>
    public static DesktopUpdaterInstallReservation PrepareInstall(
        DesktopUpdaterInstallRequest request,
        string transactionId)
    {
        if (request is null)
        {
            throw new ArgumentNullException(nameof(request));
        }
        ValidateTransactionId(transactionId, nameof(transactionId));
        return ScheduleInstallAndRelaunchCore(
            request.StagingPath,
            request.RemovedFiles,
            request.DiagnosticsLogPath,
            request.ExpectedProvenanceSha256,
            request.ExpectedArtifactSha256,
            request.AllowedSignerThumbprints,
            request.RequiresElevation,
            request.InstallRoot,
            request.ExecutableRelativePath,
            request.ExpectedPackageId,
            transactionId,
            prepareOnly: true) ?? throw new DesktopUpdaterException(
                "The native helper did not return a reservation.",
                DesktopUpdaterInstallTransactionResultCode.RecoveryRequired,
                transactionId);
    }

    /// <summary>Commits a prepared reservation after app-exit ownership exists.</summary>
    public static DesktopUpdaterInstallTransactionStatus CommitAfterExit(
        DesktopUpdaterInstallReservation reservation)
    {
        return InvokeReservationOperation(reservation, commit: true);
    }

    /// <summary>Cancels a prepared reservation.</summary>
    public static DesktopUpdaterInstallTransactionStatus CancelReservation(
        DesktopUpdaterInstallReservation reservation)
    {
        return InvokeReservationOperation(reservation, commit: false);
    }

    /// <summary>Queries authoritative helper state during startup.</summary>
    public static DesktopUpdaterInstallTransactionStatus QueryTransaction(
        string transactionId)
    {
        return InvokeTransactionOperation(
            transactionId,
            NativeTransactionOperation.Query);
    }

    /// <summary>Asks the helper to recover an incomplete transaction.</summary>
    public static DesktopUpdaterInstallTransactionStatus RecoverPendingInstall(
        string transactionId)
    {
        return InvokeTransactionOperation(
            transactionId,
            NativeTransactionOperation.Recover);
    }

    /// <summary>
    /// Resolves an incomplete transaction after the previous app has exited.
    /// </summary>
    public static DesktopUpdaterInstallTransactionStatus
        ResolvePendingInstallAfterExit(string transactionId)
    {
        return InvokeTransactionOperation(
            transactionId,
            NativeTransactionOperation.ResolveAfterExit);
    }

    private static DesktopUpdaterInstallReservation? ScheduleInstallAndRelaunchCore(
        string? stagingPath,
        IReadOnlyList<string> removedFiles,
        string? diagnosticsLogPath,
        string? expectedProvenanceSha256,
        string? expectedArtifactSha256,
        IReadOnlyList<string> allowedSignerThumbprints,
        DesktopUpdaterElevationPolicy elevationPolicy,
        string? installRoot,
        string? executableRelativePath,
        string? expectedPackageId,
        string? transactionId,
        bool prepareOnly)
    {
        IntPtr stagingPointer = IntPtr.Zero;
        IntPtr diagnosticsPointer = IntPtr.Zero;
        IntPtr provenancePointer = IntPtr.Zero;
        IntPtr artifactPointer = IntPtr.Zero;
        IntPtr signerPointers = IntPtr.Zero;
        IntPtr installRootPointer = IntPtr.Zero;
        IntPtr executableRelativePathPointer = IntPtr.Zero;
        IntPtr expectedPackageIdPointer = IntPtr.Zero;
        IntPtr transactionIdPointer = IntPtr.Zero;
        IntPtr removedPointers = IntPtr.Zero;
        var removedAllocations = new List<IntPtr>(removedFiles.Count);
        var signerAllocations = new List<IntPtr>(allowedSignerThumbprints.Count);
        NativeResultV1 result = default;
        var resultReceived = false;
        NativeTransactionStatusV1 status = default;
        var statusReceived = false;
        IntPtr reservationPointer = IntPtr.Zero;
        var reservationTransferred = false;
        DesktopUpdaterInstallTransactionStatus? preparedStatus = null;
        DesktopUpdaterException? preparedStatusError = null;
        var prepareOutcome = NativePrepareOutcomeV2.Rejected;

        try
        {
            if (stagingPath is not null)
            {
                stagingPointer = Marshal.StringToHGlobalUni(stagingPath);
            }
            if (diagnosticsLogPath is not null)
            {
                diagnosticsPointer = Marshal.StringToHGlobalUni(diagnosticsLogPath);
            }
            if (expectedProvenanceSha256 is not null)
            {
                provenancePointer = Marshal.StringToHGlobalUni(
                    expectedProvenanceSha256);
            }
            if (expectedArtifactSha256 is not null)
            {
                artifactPointer = Marshal.StringToHGlobalUni(
                    expectedArtifactSha256);
            }
            if (installRoot is not null)
            {
                installRootPointer = Marshal.StringToHGlobalUni(installRoot);
            }
            if (executableRelativePath is not null)
            {
                executableRelativePathPointer =
                    Marshal.StringToHGlobalUni(executableRelativePath);
            }
            if (expectedPackageId is not null)
            {
                expectedPackageIdPointer =
                    Marshal.StringToHGlobalUni(expectedPackageId);
            }
            if (transactionId is not null)
            {
                transactionIdPointer =
                    Marshal.StringToHGlobalUni(transactionId);
            }

            if (removedFiles.Count > 0)
            {
                removedPointers = Marshal.AllocHGlobal(
                    checked(removedFiles.Count * IntPtr.Size));
                for (var index = 0; index < removedFiles.Count; index++)
                {
                    var removedFile = removedFiles[index];
                    if (removedFile is null)
                    {
                        throw new ArgumentException(
                            "Removed file paths must not contain null values.",
                            nameof(removedFiles));
                    }
                    var allocation = Marshal.StringToHGlobalUni(removedFile);
                    removedAllocations.Add(allocation);
                    Marshal.WriteIntPtr(
                        removedPointers,
                        index * IntPtr.Size,
                        allocation);
                }
            }
            if (allowedSignerThumbprints.Count > 0)
            {
                signerPointers = Marshal.AllocHGlobal(
                    checked(allowedSignerThumbprints.Count * IntPtr.Size));
                for (var index = 0;
                     index < allowedSignerThumbprints.Count;
                     index++)
                {
                    var allocation = Marshal.StringToHGlobalUni(
                        allowedSignerThumbprints[index]);
                    signerAllocations.Add(allocation);
                    Marshal.WriteIntPtr(
                        signerPointers,
                        index * IntPtr.Size,
                        allocation);
                }
            }

            var request = new NativeInstallRequestV1
            {
                AbiVersion = AbiVersion,
                StructSize = (nuint)Marshal.SizeOf<NativeInstallRequestV1>(),
                StagingPath = stagingPointer,
                DiagnosticsLogPath = diagnosticsPointer,
                RemovedFiles = removedPointers,
                RemovedFileCount = (nuint)removedFiles.Count,
                ExpectedProvenanceSha256 = provenancePointer,
                ExpectedArtifactSha256 = artifactPointer,
                AllowedSignerThumbprints = signerPointers,
                AllowedSignerThumbprintCount =
                    (nuint)allowedSignerThumbprints.Count,
                InstallRoot = installRootPointer,
                ExecutableRelativePath = executableRelativePathPointer,
                ExpectedPackageId = expectedPackageIdPointer,
                ElevationPolicy = (uint)elevationPolicy,
            };

            if (prepareOnly)
            {
                status = CreateNativeStatus();
                statusReceived = true;
                if (transactionId is null)
                {
                    result = NativeMethods.PrepareInstall(
                        ref request,
                        out reservationPointer,
                        ref status);
                }
                else
                {
                    result = NativeMethods.PrepareInstallV2(
                        ref request,
                        transactionIdPointer,
                        out reservationPointer,
                        ref status,
                        out prepareOutcome);
                }
            }
            else
            {
                result = NativeMethods.ScheduleInstallAndRelaunch(ref request);
            }
            resultReceived = true;

            if (transactionId is not null)
            {
                try
                {
                    preparedStatus = ReadStatus(
                        status,
                        requireProof: result.Ok != 0 &&
                            prepareOutcome == NativePrepareOutcomeV2.Prepared);
                }
                catch (DesktopUpdaterException error)
                {
                    preparedStatusError = error;
                }

                if (preparedStatus is not null &&
                    !string.Equals(
                        preparedStatus.TransactionId,
                        transactionId,
                        StringComparison.Ordinal))
                {
                    throw RecoveryRequired(
                        "The native helper changed the transaction identity.",
                        transactionId);
                }
                if (prepareOutcome ==
                    NativePrepareOutcomeV2.RecoveryRequired)
                {
                    throw RecoveryRequired(
                        ReadNativeErrorMessage(result),
                        transactionId);
                }
                if (result.Ok == 0)
                {
                    if (prepareOutcome != NativePrepareOutcomeV2.Rejected)
                    {
                        throw RecoveryRequired(
                            "The native helper returned an invalid prepare outcome.",
                            transactionId);
                    }
                    var resultCode = preparedStatus?.ResultCode ??
                        DesktopUpdaterInstallTransactionResultCode.Rejected;
                    if (resultCode ==
                        DesktopUpdaterInstallTransactionResultCode
                            .RecoveryRequired)
                    {
                        throw RecoveryRequired(
                            ReadNativeErrorMessage(result),
                            transactionId);
                    }
                    throw new DesktopUpdaterException(
                        ReadNativeErrorMessage(result),
                        resultCode,
                        transactionId);
                }
                if (prepareOutcome != NativePrepareOutcomeV2.Prepared ||
                    preparedStatusError is not null ||
                    preparedStatus is null)
                {
                    throw RecoveryRequired(
                        preparedStatusError?.Message ??
                            "The native helper returned an invalid prepared status.",
                        transactionId);
                }
            }

            if (result.Ok == 0)
            {
                throw new DesktopUpdaterException(
                    ReadNativeErrorMessage(result));
            }
            if (!prepareOnly)
            {
                return null;
            }
            if (reservationPointer == IntPtr.Zero)
            {
                if (transactionId is not null)
                {
                    throw RecoveryRequired(
                        "The native helper returned no reservation handle.",
                        transactionId);
                }
                throw new DesktopUpdaterException(
                    "The native helper returned no reservation handle.");
            }
            preparedStatus ??= ReadStatus(status, requireProof: true);
            if (preparedStatus.State !=
                    DesktopUpdaterInstallTransactionState.Prepared ||
                preparedStatus.ResultCode !=
                    DesktopUpdaterInstallTransactionResultCode.Accepted)
            {
                if (transactionId is not null)
                {
                    throw RecoveryRequired(
                        "The native helper returned an invalid prepared status.",
                        transactionId);
                }
                throw new DesktopUpdaterException(
                    "The native helper returned an invalid prepared status.");
            }
            var reservation = new DesktopUpdaterInstallReservation(
                new DesktopUpdaterReservationSafeHandle(reservationPointer),
                preparedStatus);
            reservationTransferred = true;
            return reservation;
        }
        finally
        {
            if (!reservationTransferred && reservationPointer != IntPtr.Zero)
            {
                NativeMethods.ReservationRelease(reservationPointer);
            }
            if (statusReceived)
            {
                NativeMethods.TransactionStatusFree(ref status);
            }
            if (resultReceived)
            {
                NativeMethods.ResultFree(ref result);
            }
            if (transactionIdPointer != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(transactionIdPointer);
            }
            foreach (var allocation in removedAllocations)
            {
                Marshal.FreeHGlobal(allocation);
            }
            foreach (var allocation in signerAllocations)
            {
                Marshal.FreeHGlobal(allocation);
            }
            if (signerPointers != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(signerPointers);
            }
            if (artifactPointer != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(artifactPointer);
            }
            if (provenancePointer != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(provenancePointer);
            }
            if (removedPointers != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(removedPointers);
            }
            if (diagnosticsPointer != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(diagnosticsPointer);
            }
            if (expectedPackageIdPointer != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(expectedPackageIdPointer);
            }
            if (executableRelativePathPointer != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(executableRelativePathPointer);
            }
            if (installRootPointer != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(installRootPointer);
            }
            if (stagingPointer != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(stagingPointer);
            }
        }
    }

    private static DesktopUpdaterInstallTransactionStatus InvokeReservationOperation(
        DesktopUpdaterInstallReservation reservation,
        bool commit)
    {
        if (reservation is null)
        {
            throw new ArgumentNullException(nameof(reservation));
        }
        if (reservation.Handle.IsClosed || reservation.Handle.IsInvalid)
        {
            throw new ObjectDisposedException(
                nameof(DesktopUpdaterInstallReservation));
        }
        var status = CreateNativeStatus();
        NativeResultV1 result = default;
        var resultReceived = false;
        try
        {
            result = commit
                ? NativeMethods.CommitAfterExit(reservation.Handle, ref status)
                : NativeMethods.CancelReservation(reservation.Handle, ref status);
            resultReceived = true;
            ThrowIfNativeError(result);
            var managed = ReadStatus(status, requireProof: false);
            if (!string.Equals(
                    managed.TransactionId,
                    reservation.TransactionId,
                    StringComparison.Ordinal))
            {
                throw new DesktopUpdaterException(
                    "The native helper changed the transaction identity.");
            }
            if (!string.IsNullOrEmpty(managed.ResponseDigestSha256) &&
                !string.Equals(
                    managed.ResponseDigestSha256,
                    reservation.PreparedStatus.ResponseDigestSha256,
                    StringComparison.Ordinal))
            {
                throw new DesktopUpdaterException(
                    "The native helper changed the response digest.");
            }
            if (!string.IsNullOrEmpty(
                    managed.HelperEndpointIdentitySha256) &&
                !string.Equals(
                    managed.HelperEndpointIdentitySha256,
                    reservation.PreparedStatus.HelperEndpointIdentitySha256,
                    StringComparison.Ordinal))
            {
                throw new DesktopUpdaterException(
                    "The native helper endpoint identity changed.");
            }
            if (!commit && managed.State ==
                DesktopUpdaterInstallTransactionState.Cancelled)
            {
                reservation.Dispose();
            }
            return managed;
        }
        finally
        {
            NativeMethods.TransactionStatusFree(ref status);
            if (resultReceived)
            {
                NativeMethods.ResultFree(ref result);
            }
        }
    }

    private static DesktopUpdaterInstallTransactionStatus InvokeTransactionOperation(
        string transactionId,
        NativeTransactionOperation operation)
    {
        ValidateTransactionId(transactionId, nameof(transactionId));
        var transactionPointer = Marshal.StringToHGlobalUni(transactionId);
        var status = CreateNativeStatus();
        NativeResultV1 result = default;
        var resultReceived = false;
        try
        {
            switch (operation)
            {
                case NativeTransactionOperation.Query:
                    result = NativeMethods.QueryTransaction(
                        transactionPointer,
                        ref status);
                    break;
                case NativeTransactionOperation.Recover:
                    result = NativeMethods.RecoverPendingInstall(
                        transactionPointer,
                        ref status);
                    break;
                case NativeTransactionOperation.ResolveAfterExit:
                    result = NativeMethods.ResolvePendingInstallAfterExit(
                        transactionPointer,
                        ref status);
                    break;
                default:
                    throw new ArgumentOutOfRangeException(nameof(operation));
            }
            resultReceived = true;
            ThrowIfNativeError(result);
            var managed = ReadStatus(status, requireProof: false);
            if (!string.Equals(
                    managed.TransactionId,
                    transactionId,
                    StringComparison.Ordinal))
            {
                throw new DesktopUpdaterException(
                    "The native helper changed the transaction identity.",
                    DesktopUpdaterInstallTransactionResultCode.InvalidResponse,
                    transactionId);
            }
            return managed;
        }
        finally
        {
            NativeMethods.TransactionStatusFree(ref status);
            if (resultReceived)
            {
                NativeMethods.ResultFree(ref result);
            }
            Marshal.FreeHGlobal(transactionPointer);
        }
    }

    private static NativeTransactionStatusV1 CreateNativeStatus()
    {
        return new NativeTransactionStatusV1
        {
            AbiVersion = AbiVersion,
            StructSize = (nuint)Marshal.SizeOf<NativeTransactionStatusV1>(),
        };
    }

    private static DesktopUpdaterInstallTransactionStatus ReadStatus(
        NativeTransactionStatusV1 status,
        bool requireProof)
    {
        if (status.AbiVersion != AbiVersion ||
            status.StructSize < (nuint)Marshal.SizeOf<NativeTransactionStatusV1>() ||
            !Enum.IsDefined(
                typeof(DesktopUpdaterInstallTransactionState),
                (int)status.State) ||
            !Enum.IsDefined(
                typeof(DesktopUpdaterInstallTransactionResultCode),
                (int)status.ResultCode))
        {
            throw new DesktopUpdaterException(
                "The native helper returned an invalid status ABI.");
        }
        var transactionId = ReadUtf8(status.TransactionIdUtf8) ?? "";
        var detail = ReadUtf8(status.DetailUtf8) ?? "";
        var responseDigest = ReadUtf8(status.ResponseDigestSha256Utf8) ?? "";
        var endpointIdentity =
            ReadUtf8(status.HelperEndpointIdentitySha256Utf8) ?? "";
        if (!IsCanonicalTransactionId(transactionId) ||
            (requireProof &&
             (!IsLowercaseSha256(responseDigest) ||
              !IsLowercaseSha256(endpointIdentity))))
        {
            throw new DesktopUpdaterException(
                "The native helper returned an invalid transaction response.");
        }
        return new DesktopUpdaterInstallTransactionStatus(
            transactionId,
            (DesktopUpdaterInstallTransactionState)status.State,
            (DesktopUpdaterInstallTransactionResultCode)status.ResultCode,
            detail,
            responseDigest,
            endpointIdentity);
    }

    private static bool IsLowercaseSha256(string value)
    {
        if (value.Length != 64)
        {
            return false;
        }
        foreach (var character in value)
        {
            if (!((character >= '0' && character <= '9') ||
                  (character >= 'a' && character <= 'f')))
            {
                return false;
            }
        }
        return true;
    }

    private static bool IsCanonicalTransactionId(string? value)
    {
        return value is not null &&
            value.Length == 36 &&
            value[14] == '4' &&
            "89ab".IndexOf(value[19]) >= 0 &&
            Guid.TryParseExact(value, "D", out var parsed) &&
            string.Equals(
                value,
                parsed.ToString("D"),
                StringComparison.Ordinal);
    }

    private static void ValidateTransactionId(
        string? transactionId,
        string parameterName)
    {
        if (!IsCanonicalTransactionId(transactionId))
        {
            throw new ArgumentException(
                "A canonical lowercase UUIDv4 transaction ID is required.",
                parameterName);
        }
    }

    private static DesktopUpdaterException RecoveryRequired(
        string message,
        string transactionId)
    {
        return new DesktopUpdaterException(
            message,
            DesktopUpdaterInstallTransactionResultCode.RecoveryRequired,
            transactionId);
    }

    private static string ReadNativeErrorMessage(NativeResultV1 result)
    {
        return result.ErrorMessageUtf8 == IntPtr.Zero
            ? "The native desktop updater failed without an error message."
            : ReadUtf8(result.ErrorMessageUtf8)
                ?? "The native desktop updater returned an invalid error message.";
    }

    private static void ThrowIfNativeError(NativeResultV1 result)
    {
        if (result.Ok != 0)
        {
            return;
        }
        throw new DesktopUpdaterException(ReadNativeErrorMessage(result));
    }

    internal static void ReleaseReservationHandle(IntPtr handle)
    {
        NativeMethods.ReservationRelease(handle);
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

    private enum NativePrepareOutcomeV2 : uint
    {
        Rejected = 0,
        Prepared = 1,
        RecoveryRequired = 2,
    }

    private enum NativeTransactionOperation
    {
        Query,
        Recover,
        ResolveAfterExit,
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeInstallRequestV1
    {
        public uint AbiVersion;
        public nuint StructSize;
        public IntPtr StagingPath;
        public IntPtr DiagnosticsLogPath;
        public IntPtr RemovedFiles;
        public nuint RemovedFileCount;
        public IntPtr ExpectedProvenanceSha256;
        public IntPtr ExpectedArtifactSha256;
        public IntPtr AllowedSignerThumbprints;
        public nuint AllowedSignerThumbprintCount;
        public IntPtr InstallRoot;
        public IntPtr ExecutableRelativePath;
        public IntPtr ExpectedPackageId;
        public uint ElevationPolicy;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeResultV1
    {
        public uint AbiVersion;
        public int Ok;
        public IntPtr ErrorMessageUtf8;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeTransactionStatusV1
    {
        public uint AbiVersion;
        public nuint StructSize;
        public uint State;
        public uint ResultCode;
        public IntPtr TransactionIdUtf8;
        public IntPtr DetailUtf8;
        public IntPtr ResponseDigestSha256Utf8;
        public IntPtr HelperEndpointIdentitySha256Utf8;
    }

    private static class NativeMethods
    {
        [DllImport(
            "desktop_updater_native",
            EntryPoint = "desktop_updater_schedule_install_and_relaunch_v1",
            ExactSpelling = true,
            CallingConvention = CallingConvention.Cdecl)]
        internal static extern NativeResultV1 ScheduleInstallAndRelaunch(
            ref NativeInstallRequestV1 request);

        [DllImport(
            "desktop_updater_native",
            EntryPoint = "desktop_updater_prepare_install_v1",
            ExactSpelling = true,
            CallingConvention = CallingConvention.Cdecl)]
        internal static extern NativeResultV1 PrepareInstall(
            ref NativeInstallRequestV1 request,
            out IntPtr reservation,
            ref NativeTransactionStatusV1 status);

        [DllImport(
            "desktop_updater_native",
            EntryPoint = "desktop_updater_prepare_install_v2",
            ExactSpelling = true,
            CallingConvention = CallingConvention.Cdecl)]
        internal static extern NativeResultV1 PrepareInstallV2(
            ref NativeInstallRequestV1 request,
            IntPtr transactionId,
            out IntPtr reservation,
            ref NativeTransactionStatusV1 status,
            out NativePrepareOutcomeV2 prepareOutcome);

        [DllImport(
            "desktop_updater_native",
            EntryPoint = "desktop_updater_commit_after_exit_v1",
            ExactSpelling = true,
            CallingConvention = CallingConvention.Cdecl)]
        internal static extern NativeResultV1 CommitAfterExit(
            DesktopUpdaterReservationSafeHandle reservation,
            ref NativeTransactionStatusV1 status);

        [DllImport(
            "desktop_updater_native",
            EntryPoint = "desktop_updater_cancel_reservation_v1",
            ExactSpelling = true,
            CallingConvention = CallingConvention.Cdecl)]
        internal static extern NativeResultV1 CancelReservation(
            DesktopUpdaterReservationSafeHandle reservation,
            ref NativeTransactionStatusV1 status);

        [DllImport(
            "desktop_updater_native",
            EntryPoint = "desktop_updater_query_transaction_v1",
            ExactSpelling = true,
            CallingConvention = CallingConvention.Cdecl)]
        internal static extern NativeResultV1 QueryTransaction(
            IntPtr transactionId,
            ref NativeTransactionStatusV1 status);

        [DllImport(
            "desktop_updater_native",
            EntryPoint = "desktop_updater_recover_pending_install_v1",
            ExactSpelling = true,
            CallingConvention = CallingConvention.Cdecl)]
        internal static extern NativeResultV1 RecoverPendingInstall(
            IntPtr transactionId,
            ref NativeTransactionStatusV1 status);

        [DllImport(
            "desktop_updater_native",
            EntryPoint =
                "desktop_updater_resolve_pending_install_after_exit_v1",
            ExactSpelling = true,
            CallingConvention = CallingConvention.Cdecl)]
        internal static extern NativeResultV1 ResolvePendingInstallAfterExit(
            IntPtr transactionId,
            ref NativeTransactionStatusV1 status);

        [DllImport(
            "desktop_updater_native",
            EntryPoint = "desktop_updater_transaction_status_free_v1",
            ExactSpelling = true,
            CallingConvention = CallingConvention.Cdecl)]
        internal static extern void TransactionStatusFree(
            ref NativeTransactionStatusV1 status);

        [DllImport(
            "desktop_updater_native",
            EntryPoint = "desktop_updater_reservation_release_v1",
            ExactSpelling = true,
            CallingConvention = CallingConvention.Cdecl)]
        internal static extern void ReservationRelease(IntPtr reservation);

        [DllImport(
            "desktop_updater_native",
            EntryPoint = "desktop_updater_result_free_v1",
            ExactSpelling = true,
            CallingConvention = CallingConvention.Cdecl)]
        internal static extern void ResultFree(ref NativeResultV1 result);
    }
}
