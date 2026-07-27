using System;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using DesktopUpdater.Native;
using Xunit;

namespace DesktopUpdater.Native.Tests;

public sealed class DesktopUpdaterNativeTests
{
    [Fact]
    public void ExceptionTypeIsPublic()
    {
        var error = new DesktopUpdaterException("example");

        Assert.Equal("example", error.Message);
    }

    [Fact]
    public void DecodesUtf8AbiErrorMessage()
    {
        const string message = "İstanbul update failed";
        var utf8Bytes = Encoding.UTF8.GetBytes(message + "\0");
        var messagePointer = Marshal.AllocHGlobal(utf8Bytes.Length);

        try
        {
            Marshal.Copy(utf8Bytes, 0, messagePointer, utf8Bytes.Length);
            var decodeMethod = typeof(DesktopUpdaterNative).GetMethod(
                "DecodeUtf8",
                BindingFlags.NonPublic | BindingFlags.Static);

            Assert.NotNull(decodeMethod);
            var decoded =
                (string?)decodeMethod!.Invoke(null, new object[] { messagePointer });

            Assert.Equal(message, decoded);
        }
        finally
        {
            Marshal.FreeHGlobal(messagePointer);
        }
    }

    [Fact]
    public void CallsRealNativeAbiAndDecodesItsError()
    {
        var missingStagingPath = Path.Combine(
            Path.GetTempPath(),
            $"desktop_updater_missing_{Guid.NewGuid():N}");

        var error = Assert.Throws<DesktopUpdaterException>(
            () => DesktopUpdaterNative.ScheduleInstallAndRelaunch(
                missingStagingPath,
                diagnosticsLogPath: null));

        Assert.Equal("Staged update directory does not exist.", error.Message);
    }
}
