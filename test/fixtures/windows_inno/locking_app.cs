using System;
using System.Diagnostics;
using System.IO;
using System.Threading;
using System.Windows.Forms;

// Models an initiating process and a second instance which refuses graceful
// shutdown. Running this EXE also locks its own on-disk image against replacement.
public sealed class InnoLockingApp : Form {
  private readonly string readyPath;

  private InnoLockingApp(string readyPath) {
    this.readyPath = readyPath;
    Text = "desktop_updater Inno regression fixture";
    ShowInTaskbar = false;
    Opacity = 0;
  }

  protected override void OnShown(EventArgs e) {
    base.OnShown(e);
    File.WriteAllText(readyPath, Process.GetCurrentProcess().Id.ToString());
  }

  protected override void WndProc(ref Message message) {
    const int WM_QUERYENDSESSION = 0x0011;
    const int WM_ENDSESSION = 0x0016;
    const int WM_CLOSE = 0x0010;
    if (message.Msg == WM_QUERYENDSESSION ||
        message.Msg == WM_ENDSESSION || message.Msg == WM_CLOSE) {
      message.Result = IntPtr.Zero;
      return;
    }
    base.WndProc(ref message);
  }

  [STAThread]
  public static void Main(string[] arguments) {
    if (arguments.Length < 2) throw new ArgumentException("Missing fixture mode or ready path.");
    if (arguments[0] == "--caller") {
      File.WriteAllText(arguments[1], Process.GetCurrentProcess().Id.ToString());
      while (!File.Exists(arguments[2])) Thread.Sleep(50);
      return;
    }
    Application.Run(new InnoLockingApp(arguments[1]));
  }
}
