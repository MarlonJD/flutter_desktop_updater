using System;
using System.IO;

public static class InnoUpdatedApp {
  public static void Main() {
    File.WriteAllText(
        Environment.GetEnvironmentVariable("DESKTOP_UPDATER_INNO_SMOKE_PROOF"),
        "updated application relaunched");
  }
}
