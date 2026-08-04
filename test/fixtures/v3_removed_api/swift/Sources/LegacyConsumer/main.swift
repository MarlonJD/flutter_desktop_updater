import DesktopUpdaterKit

func legacyRequest() -> MacInstallRequest {
    fatalError("fixture is compiled only")
}

let request = legacyRequest()
try MacInstallHelper().scheduleInstallAndRelaunch(request)
