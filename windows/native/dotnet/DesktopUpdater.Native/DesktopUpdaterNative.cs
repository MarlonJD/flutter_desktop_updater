using System.Runtime.InteropServices;
using System.Text;

namespace DesktopUpdater.Native;

/// <summary>Complete verified context for a staged helper-only install.</summary>
public sealed class DesktopUpdaterInstallRequest
{
    /// <summary>Creates a complete staged-install request.</summary>
    public DesktopUpdaterInstallRequest(
        string stagingPath,
        IReadOnlyList<string> removedFiles,
        string expectedProvenanceSha256,
        string expectedArtifactSha256,
        string installRoot,
        string executableRelativePath,
        string expectedPackageId)
    {
        StagingPath = RequireText(stagingPath, nameof(stagingPath));
        RemovedFiles = CopyStrings(removedFiles, nameof(removedFiles));
        ExpectedProvenanceSha256 = RequireSha256(
            expectedProvenanceSha256,
            nameof(expectedProvenanceSha256));
        ExpectedArtifactSha256 = RequireSha256(
            expectedArtifactSha256,
            nameof(expectedArtifactSha256));
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
    /// <summary>Retained SHA-256 of the canonical stage provenance marker.</summary>
    public string ExpectedProvenanceSha256 { get; }
    /// <summary>SHA-256 of the verified release artifact.</summary>
    public string ExpectedArtifactSha256 { get; }
    /// <summary>Canonical current application root hint.</summary>
    public string InstallRoot { get; }
    /// <summary>Running executable relative-path hint.</summary>
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
}

/// <summary>Authoritative native helper transaction state.</summary>
public enum DesktopUpdaterInstallTransactionState
{
    Unknown = 0,
    Prepared = 1,
    CommitAccepted = 2,
    Completed = 3,
    Cancelled = 4,
    Expired = 5,
    RolledBack = 6,
    ManualActionRequired = 7,
}

/// <summary>Stable result category returned by the native helper.</summary>
public enum DesktopUpdaterInstallTransactionResultCode
{
    None = 0,
    Accepted = 1,
    Succeeded = 2,
    Rejected = 3,
    EndpointUnavailable = 4,
    AuthenticationFailed = 5,
    InvalidResponse = 6,
    RecoveryRequired = 7,
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

    public string TransactionId { get; }
    public DesktopUpdaterInstallTransactionState State { get; }
    public DesktopUpdaterInstallTransactionResultCode ResultCode { get; }
    public string Detail { get; }
    public string ResponseDigestSha256 { get; }
    public string HelperEndpointIdentitySha256 { get; }
    public bool AwaitsCallerExit =>
        State == DesktopUpdaterInstallTransactionState.Prepared &&
        ResultCode == DesktopUpdaterInstallTransactionResultCode.RecoveryRequired;
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
    public DesktopUpdaterInstallTransactionStatus PreparedStatus { get; }
    public string TransactionId => PreparedStatus.TransactionId;

    public void Dispose() => Handle.Dispose();
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

/// <summary>Explicit ABI2 helper transaction API.</summary>
public static class DesktopUpdaterNative
{
    private const uint AbiVersion = 2;

    /// <summary>Prepares a durable helper reservation using a persisted ID.</summary>
    public static DesktopUpdaterInstallReservation PrepareInstall(
        DesktopUpdaterInstallRequest request,
        string transactionId)
    {
        if (request is null) throw new ArgumentNullException(nameof(request));
        ValidateTransactionId(transactionId, nameof(transactionId));

        var allocations = new List<IntPtr>();
        var removedAllocations = new List<IntPtr>(request.RemovedFiles.Count);
        var status = CreateNativeStatus();
        NativeResultAbi2 result = default;
        var resultReceived = false;
        IntPtr reservation = IntPtr.Zero;
        var reservationTransferred = false;
        try
        {
            var removedPointers = AllocateStringArray(
                request.RemovedFiles,
                allocations,
                removedAllocations);
            var nativeRequest = new NativeInstallRequestAbi2
            {
                AbiVersion = AbiVersion,
                StructSize = (nuint)Marshal.SizeOf<NativeInstallRequestAbi2>(),
                StagingPath = AllocateUtf16(request.StagingPath, allocations),
                RemovedFiles = removedPointers,
                RemovedFileCount = (nuint)request.RemovedFiles.Count,
                ExpectedProvenanceSha256 = AllocateUtf16(
                    request.ExpectedProvenanceSha256,
                    allocations),
                ExpectedArtifactSha256 = AllocateUtf16(
                    request.ExpectedArtifactSha256,
                    allocations),
                InstallRoot = AllocateUtf16(request.InstallRoot, allocations),
                ExecutableRelativePath = AllocateUtf16(
                    request.ExecutableRelativePath,
                    allocations),
                ExpectedPackageId = AllocateUtf16(
                    request.ExpectedPackageId,
                    allocations),
            };
            var transactionPointer = AllocateUtf16(transactionId, allocations);
            result = NativeMethods.PrepareInstall(
                ref nativeRequest,
                transactionPointer,
                out reservation,
                ref status);
            resultReceived = true;
            ThrowIfNativeError(result);
            var prepared = ReadStatus(status, requireProof: true);
            if (!string.Equals(
                    prepared.TransactionId,
                    transactionId,
                    StringComparison.Ordinal))
            {
                throw new DesktopUpdaterException(
                    "The native helper changed the transaction identity.",
                    DesktopUpdaterInstallTransactionResultCode.InvalidResponse,
                    transactionId);
            }
            if (prepared.State != DesktopUpdaterInstallTransactionState.Prepared ||
                prepared.ResultCode !=
                    DesktopUpdaterInstallTransactionResultCode.Accepted)
            {
                throw new DesktopUpdaterException(
                    "The native helper returned an invalid prepared status.",
                    prepared.ResultCode,
                    transactionId);
            }
            if (reservation == IntPtr.Zero)
            {
                throw new DesktopUpdaterException(
                    "The native helper returned no reservation handle.",
                    DesktopUpdaterInstallTransactionResultCode.RecoveryRequired,
                    transactionId);
            }
            var managed = new DesktopUpdaterInstallReservation(
                new DesktopUpdaterReservationSafeHandle(reservation),
                prepared);
            reservationTransferred = true;
            return managed;
        }
        finally
        {
            if (!reservationTransferred && reservation != IntPtr.Zero)
            {
                NativeMethods.ReservationRelease(reservation);
            }
            NativeMethods.TransactionStatusFree(ref status);
            if (resultReceived) NativeMethods.ResultFree(ref result);
            FreeAllocations(removedAllocations);
            FreeAllocations(allocations);
        }
    }

    public static DesktopUpdaterInstallTransactionStatus CommitAfterExit(
        DesktopUpdaterInstallReservation reservation) =>
        InvokeReservationOperation(reservation, commit: true);

    public static DesktopUpdaterInstallTransactionStatus CancelReservation(
        DesktopUpdaterInstallReservation reservation) =>
        InvokeReservationOperation(reservation, commit: false);

    public static DesktopUpdaterInstallTransactionStatus QueryTransaction(
        string transactionId) => InvokeTransactionOperation(transactionId, false);

    public static DesktopUpdaterInstallTransactionStatus
        ResolvePendingInstallAfterExit(string transactionId) =>
        InvokeTransactionOperation(transactionId, true);

    private static DesktopUpdaterInstallTransactionStatus InvokeReservationOperation(
        DesktopUpdaterInstallReservation reservation,
        bool commit)
    {
        if (reservation is null) throw new ArgumentNullException(nameof(reservation));
        if (reservation.Handle.IsClosed || reservation.Handle.IsInvalid)
        {
            throw new ObjectDisposedException(nameof(reservation));
        }
        var status = CreateNativeStatus();
        NativeResultAbi2 result = default;
        var resultReceived = false;
        try
        {
            result = commit
                ? NativeMethods.CommitAfterExit(reservation.Handle, ref status)
                : NativeMethods.CancelReservation(reservation.Handle, ref status);
            resultReceived = true;
            ThrowIfNativeError(result);
            var managed = ReadStatus(status, requireProof: false);
            ValidateStatusBinding(managed, reservation.TransactionId);
            if (!commit && managed.State ==
                DesktopUpdaterInstallTransactionState.Cancelled)
            {
                reservation.Dispose();
            }
            if (commit && (managed.State ==
                                DesktopUpdaterInstallTransactionState.CommitAccepted ||
                            managed.State ==
                                DesktopUpdaterInstallTransactionState.Completed))
            {
                reservation.Dispose();
            }
            return managed;
        }
        finally
        {
            NativeMethods.TransactionStatusFree(ref status);
            if (resultReceived) NativeMethods.ResultFree(ref result);
        }
    }

    private static DesktopUpdaterInstallTransactionStatus InvokeTransactionOperation(
        string transactionId,
        bool resolve)
    {
        ValidateTransactionId(transactionId, nameof(transactionId));
        var allocations = new List<IntPtr>();
        var status = CreateNativeStatus();
        NativeResultAbi2 result = default;
        var resultReceived = false;
        try
        {
            var transactionPointer = AllocateUtf16(transactionId, allocations);
            result = resolve
                ? NativeMethods.ResolvePendingInstallAfterExit(
                    transactionPointer,
                    ref status)
                : NativeMethods.QueryTransaction(transactionPointer, ref status);
            resultReceived = true;
            ThrowIfNativeError(result);
            var managed = ReadStatus(status, requireProof: false);
            ValidateStatusBinding(managed, transactionId);
            return managed;
        }
        finally
        {
            NativeMethods.TransactionStatusFree(ref status);
            if (resultReceived) NativeMethods.ResultFree(ref result);
            FreeAllocations(allocations);
        }
    }

    private static void ValidateStatusBinding(
        DesktopUpdaterInstallTransactionStatus status,
        string transactionId)
    {
        if (!string.Equals(
                status.TransactionId,
                transactionId,
                StringComparison.Ordinal))
        {
            throw new DesktopUpdaterException(
                "The native helper changed the transaction identity.",
                DesktopUpdaterInstallTransactionResultCode.InvalidResponse,
                transactionId);
        }
    }

    private static NativeTransactionStatusAbi2 CreateNativeStatus() =>
        new()
        {
            AbiVersion = AbiVersion,
            StructSize = (nuint)Marshal.SizeOf<NativeTransactionStatusAbi2>(),
        };

    private static DesktopUpdaterInstallTransactionStatus ReadStatus(
        NativeTransactionStatusAbi2 status,
        bool requireProof)
    {
        if (status.AbiVersion != AbiVersion ||
            status.StructSize < (nuint)Marshal.SizeOf<NativeTransactionStatusAbi2>() ||
            !Enum.IsDefined(typeof(DesktopUpdaterInstallTransactionState),
                (int)status.State) ||
            !Enum.IsDefined(typeof(DesktopUpdaterInstallTransactionResultCode),
                (int)status.ResultCode))
        {
            throw new DesktopUpdaterException(
                "The native helper returned an invalid status ABI.");
        }
        var transactionId = ReadUtf8(status.TransactionIdUtf8) ?? string.Empty;
        var detail = ReadUtf8(status.DetailUtf8) ?? string.Empty;
        var responseDigest = ReadUtf8(status.ResponseDigestSha256Utf8) ?? string.Empty;
        var endpointIdentity =
            ReadUtf8(status.HelperEndpointIdentitySha256Utf8) ?? string.Empty;
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
        if (value.Length != 64) return false;
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

    private static bool IsCanonicalTransactionId(string? value) =>
        value is not null && value.Length == 36 && value[14] == '4' &&
        "89ab".IndexOf(value[19]) >= 0 &&
        Guid.TryParseExact(value, "D", out var parsed) &&
        string.Equals(value, parsed.ToString("D"), StringComparison.Ordinal);

    private static void ValidateTransactionId(string? transactionId, string name)
    {
        if (!IsCanonicalTransactionId(transactionId))
        {
            throw new ArgumentException(
                "A canonical lowercase UUIDv4 transaction ID is required.",
                name);
        }
    }

    private static string ReadNativeErrorMessage(NativeResultAbi2 result) =>
        result.ErrorMessageUtf8 == IntPtr.Zero
            ? "The native desktop updater failed without an error message."
            : ReadUtf8(result.ErrorMessageUtf8) ??
                "The native desktop updater returned an invalid error message.";

    private static void ThrowIfNativeError(NativeResultAbi2 result)
    {
        if (result.AbiVersion != AbiVersion ||
            result.StructSize < (nuint)Marshal.SizeOf<NativeResultAbi2>())
        {
            throw new DesktopUpdaterException("The native helper returned an invalid result ABI.");
        }
        if (result.Ok == 0) throw new DesktopUpdaterException(ReadNativeErrorMessage(result));
    }

    internal static void ReleaseReservationHandle(IntPtr handle) =>
        NativeMethods.ReservationRelease(handle);

    private static IntPtr AllocateUtf16(string value, List<IntPtr> allocations)
    {
        var pointer = Marshal.StringToHGlobalUni(value);
        allocations.Add(pointer);
        return pointer;
    }

    private static IntPtr AllocateStringArray(
        IReadOnlyList<string> values,
        List<IntPtr> allocations,
        List<IntPtr> stringAllocations)
    {
        if (values.Count == 0) return IntPtr.Zero;
        var pointerArray = Marshal.AllocHGlobal(checked(values.Count * IntPtr.Size));
        allocations.Add(pointerArray);
        for (var index = 0; index < values.Count; index++)
        {
            var pointer = Marshal.StringToHGlobalUni(values[index]);
            stringAllocations.Add(pointer);
            Marshal.WriteIntPtr(pointerArray, index * IntPtr.Size, pointer);
        }
        return pointerArray;
    }

    private static void FreeAllocations(IEnumerable<IntPtr> allocations)
    {
        foreach (var allocation in allocations)
        {
            if (allocation != IntPtr.Zero) Marshal.FreeHGlobal(allocation);
        }
    }

    private static string? ReadUtf8(IntPtr value)
    {
        if (value == IntPtr.Zero) return null;
        var length = 0;
        while (Marshal.ReadByte(value, length) != 0) length++;
        var bytes = new byte[length];
        Marshal.Copy(value, bytes, 0, length);
        return Encoding.UTF8.GetString(bytes);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeInstallRequestAbi2
    {
        public uint AbiVersion;
        public nuint StructSize;
        public IntPtr StagingPath;
        public IntPtr RemovedFiles;
        public nuint RemovedFileCount;
        public IntPtr ExpectedProvenanceSha256;
        public IntPtr ExpectedArtifactSha256;
        public IntPtr InstallRoot;
        public IntPtr ExecutableRelativePath;
        public IntPtr ExpectedPackageId;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeResultAbi2
    {
        public uint AbiVersion;
        public nuint StructSize;
        public int Ok;
        public IntPtr ErrorMessageUtf8;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeTransactionStatusAbi2
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
            EntryPoint = "desktop_updater_prepare_install_abi2",
            ExactSpelling = true,
            CallingConvention = CallingConvention.Cdecl)]
        internal static extern NativeResultAbi2 PrepareInstall(
            ref NativeInstallRequestAbi2 request,
            IntPtr transactionId,
            out IntPtr reservation,
            ref NativeTransactionStatusAbi2 status);

        [DllImport(
            "desktop_updater_native",
            EntryPoint = "desktop_updater_commit_after_exit_abi2",
            ExactSpelling = true,
            CallingConvention = CallingConvention.Cdecl)]
        internal static extern NativeResultAbi2 CommitAfterExit(
            DesktopUpdaterReservationSafeHandle reservation,
            ref NativeTransactionStatusAbi2 status);

        [DllImport(
            "desktop_updater_native",
            EntryPoint = "desktop_updater_cancel_reservation_abi2",
            ExactSpelling = true,
            CallingConvention = CallingConvention.Cdecl)]
        internal static extern NativeResultAbi2 CancelReservation(
            DesktopUpdaterReservationSafeHandle reservation,
            ref NativeTransactionStatusAbi2 status);

        [DllImport(
            "desktop_updater_native",
            EntryPoint = "desktop_updater_query_transaction_abi2",
            ExactSpelling = true,
            CallingConvention = CallingConvention.Cdecl)]
        internal static extern NativeResultAbi2 QueryTransaction(
            IntPtr transactionId,
            ref NativeTransactionStatusAbi2 status);

        [DllImport(
            "desktop_updater_native",
            EntryPoint = "desktop_updater_resolve_pending_install_after_exit_abi2",
            ExactSpelling = true,
            CallingConvention = CallingConvention.Cdecl)]
        internal static extern NativeResultAbi2 ResolvePendingInstallAfterExit(
            IntPtr transactionId,
            ref NativeTransactionStatusAbi2 status);

        [DllImport(
            "desktop_updater_native",
            EntryPoint = "desktop_updater_transaction_status_free_abi2",
            ExactSpelling = true,
            CallingConvention = CallingConvention.Cdecl)]
        internal static extern void TransactionStatusFree(
            ref NativeTransactionStatusAbi2 status);

        [DllImport(
            "desktop_updater_native",
            EntryPoint = "desktop_updater_reservation_release_abi2",
            ExactSpelling = true,
            CallingConvention = CallingConvention.Cdecl)]
        internal static extern void ReservationRelease(IntPtr reservation);

        [DllImport(
            "desktop_updater_native",
            EntryPoint = "desktop_updater_result_free_abi2",
            ExactSpelling = true,
            CallingConvention = CallingConvention.Cdecl)]
        internal static extern void ResultFree(ref NativeResultAbi2 result);
    }
}
