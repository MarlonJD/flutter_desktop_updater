function Stop-ExactProcessTree {
  param(
    [Parameter(Mandatory = $true)]
    [int] $RootProcessId,
    [string] $ExpectedCommandFragment
  )

  $snapshot = @(Get-CimInstance Win32_Process -ErrorAction Stop)
  $root = $snapshot | Where-Object { [int] $_.ProcessId -eq $RootProcessId }
  if ($null -ne $root -and
      -not [string]::IsNullOrWhiteSpace($ExpectedCommandFragment) -and
      $root.CommandLine -notlike "*$ExpectedCommandFragment*") {
    throw "Refusing to stop an unexpected root process: $RootProcessId"
  }

  $treeIds = [Collections.Generic.List[int]]::new()
  function Add-DescendantProcessIds([int] $ParentId) {
    foreach ($child in @($snapshot | Where-Object {
        [int] $_.ParentProcessId -eq $ParentId
      })) {
      Add-DescendantProcessIds ([int] $child.ProcessId)
      $treeIds.Add([int] $child.ProcessId)
    }
  }

  Add-DescendantProcessIds $RootProcessId
  $treeIds.Add($RootProcessId)
  foreach ($processId in $treeIds) {
    if (Get-Process -Id $processId -ErrorAction SilentlyContinue) {
      Stop-Process -Id $processId -Force -ErrorAction Stop
    }
  }
  foreach ($processId in $treeIds) {
    Wait-Process -Id $processId -Timeout 15 -ErrorAction SilentlyContinue
  }
  $remaining = @(
    $treeIds | Where-Object {
      Get-Process -Id $_ -ErrorAction SilentlyContinue
    }
  )
  if ($remaining.Count -ne 0) {
    throw "Exact process-tree cleanup left PIDs: $($remaining -join ',')"
  }
}
