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
}
