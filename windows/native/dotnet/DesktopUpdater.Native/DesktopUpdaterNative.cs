using System.Runtime.InteropServices;
using System.Text;

namespace DesktopUpdater.Native;

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

        IntPtr stagingPointer = IntPtr.Zero;
        IntPtr diagnosticsPointer = IntPtr.Zero;
        IntPtr installRootPointer = IntPtr.Zero;
        IntPtr executableRelativePathPointer = IntPtr.Zero;
        IntPtr expectedPackageIdPointer = IntPtr.Zero;
        IntPtr removedPointers = IntPtr.Zero;
        var removedAllocations = new List<IntPtr>(removedFiles.Count);
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

            var request = new NativeInstallRequestV1
            {
                AbiVersion = AbiVersion,
                StructSize = (nuint)Marshal.SizeOf<NativeInstallRequestV1>(),
                StagingPath = stagingPointer,
                DiagnosticsLogPath = diagnosticsPointer,
                RemovedFiles = removedPointers,
                RemovedFileCount = (nuint)removedFiles.Count,
                InstallRoot = installRootPointer,
                ExecutableRelativePath = executableRelativePathPointer,
                ExpectedPackageId = expectedPackageIdPointer,
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
