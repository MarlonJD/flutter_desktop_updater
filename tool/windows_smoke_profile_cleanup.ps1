function Remove-WindowsSmokeUserProfile {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^S-1-5-21-(?:[0-9]+-){3}[0-9]+$')]
    [string] $Sid,
    [Parameter(Mandatory = $true)]
    [string] $ExpectedPath
  )

  $profilesDirectory = [IO.Path]::GetFullPath(
    [Environment]::ExpandEnvironmentVariables(
      (Get-ItemProperty `
        -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' `
        -Name ProfilesDirectory).ProfilesDirectory
    )
  )
  $expected = [IO.Path]::GetFullPath($ExpectedPath)
  $expectedParent = [IO.Path]::GetDirectoryName($expected)
  $expectedLeaf = [IO.Path]::GetFileName($expected)
  if (-not [StringComparer]::OrdinalIgnoreCase.Equals(
      $expectedParent,
      $profilesDirectory
    ) -or $expectedLeaf -notmatch '^du(?:flutter|zip)[0-9a-f]{8}$') {
    throw "Refusing to remove an unexpected Windows smoke profile: $expected"
  }

  for ($attempt = 0; $attempt -lt 80; $attempt++) {
    $profiles = @(
      Get-CimInstance Win32_UserProfile -Filter "SID = '$Sid'" `
        -ErrorAction Stop
    )
    if ($profiles.Count -gt 1) {
      throw "Multiple Windows smoke user profiles have SID $Sid."
    }
    if ($profiles.Count -eq 0) {
      if (Test-Path -LiteralPath $expected) {
        throw "Windows smoke profile registration is absent but its path remains: $expected"
      }
      return
    }

    $profile = $profiles[0]
    $actual = [IO.Path]::GetFullPath([string] $profile.LocalPath)
    if (-not [StringComparer]::OrdinalIgnoreCase.Equals($actual, $expected)) {
      throw "Windows smoke user profile path changed: $actual"
    }
    if ([bool] $profile.Special) {
      throw "Refusing to remove a special Windows user profile: $Sid"
    }
    if ([bool] $profile.Loaded) {
      Start-Sleep -Milliseconds 250
      continue
    }

    Remove-CimInstance -InputObject $profile -ErrorAction Stop
    for ($verification = 0; $verification -lt 80; $verification++) {
      $remaining = @(
        Get-CimInstance Win32_UserProfile -Filter "SID = '$Sid'" `
          -ErrorAction Stop
      )
      if ($remaining.Count -eq 0 -and
          -not (Test-Path -LiteralPath $expected)) {
        return
      }
      Start-Sleep -Milliseconds 250
    }
    throw "Windows smoke user profile remained after deletion: $expected"
  }

  throw "Windows smoke user profile remained loaded: $expected"
}
