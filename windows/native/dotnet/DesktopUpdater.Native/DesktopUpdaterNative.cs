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
    /// <summary>Optional JSONL diagnostics destination.</summary>
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

/// <summary>Schedules installation through the versioned native updater ABI.</summary>
public static class DesktopUpdaterNative
{
    private const uint AbiVersion = 1;

    /// <summary>Schedules a staged update and relaunches the current app.</summary>
    /// <param name="stagingPath">The staged bundle directory, or null for restart only.</param>
    /// <param name="removedFiles">App-relative paths to remove before overlay.</param>
    /// <param name="diagnosticsLogPath">Optional JSONL diagnostics destination.</param>
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
        ScheduleInstallAndRelaunchCore(
            stagingPath,
            removedFiles,
            diagnosticsLogPath,
            null,
            null,
            Array.Empty<string>(),
            DesktopUpdaterElevationPolicy.Never,
            installRoot,
            executableRelativePath,
            expectedPackageId);
    }

    /// <summary>Schedules a complete verified staged update.</summary>
    public static void ScheduleInstallAndRelaunch(
        DesktopUpdaterInstallRequest request)
    {
        if (request is null)
        {
            throw new ArgumentNullException(nameof(request));
        }
        ScheduleInstallAndRelaunchCore(
            request.StagingPath,
            request.RemovedFiles,
            request.DiagnosticsLogPath,
            request.ExpectedProvenanceSha256,
            request.ExpectedArtifactSha256,
            request.AllowedSignerThumbprints,
            request.RequiresElevation,
            request.InstallRoot,
            request.ExecutableRelativePath,
            request.ExpectedPackageId);
    }

    private static void ScheduleInstallAndRelaunchCore(
        string? stagingPath,
        IReadOnlyList<string> removedFiles,
        string? diagnosticsLogPath,
        string? expectedProvenanceSha256,
        string? expectedArtifactSha256,
        IReadOnlyList<string> allowedSignerThumbprints,
        DesktopUpdaterElevationPolicy elevationPolicy,
        string? installRoot,
        string? executableRelativePath,
        string? expectedPackageId)
    {
        IntPtr stagingPointer = IntPtr.Zero;
        IntPtr diagnosticsPointer = IntPtr.Zero;
        IntPtr provenancePointer = IntPtr.Zero;
        IntPtr artifactPointer = IntPtr.Zero;
        IntPtr signerPointers = IntPtr.Zero;
        IntPtr installRootPointer = IntPtr.Zero;
        IntPtr executableRelativePathPointer = IntPtr.Zero;
        IntPtr expectedPackageIdPointer = IntPtr.Zero;
        IntPtr removedPointers = IntPtr.Zero;
        var removedAllocations = new List<IntPtr>(removedFiles.Count);
        var signerAllocations = new List<IntPtr>(allowedSignerThumbprints.Count);
        NativeResultV1 result = default;
        var resultReceived = false;

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

            result = NativeMethods.ScheduleInstallAndRelaunch(ref request);
            resultReceived = true;
            if (result.Ok == 0)
            {
                var message = result.ErrorMessageUtf8 == IntPtr.Zero
                    ? "The native desktop updater failed without an error message."
                    : ReadUtf8(result.ErrorMessageUtf8)
                        ?? "The native desktop updater returned an invalid error message.";
                throw new DesktopUpdaterException(message);
            }
        }
        finally
        {
            if (resultReceived)
            {
                NativeMethods.ResultFree(ref result);
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
            EntryPoint = "desktop_updater_result_free_v1",
            ExactSpelling = true,
            CallingConvention = CallingConvention.Cdecl)]
        internal static extern void ResultFree(ref NativeResultV1 result);
    }
}
