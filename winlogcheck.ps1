[CmdletBinding()]
Param($mode,$log,$filter)

# Print usage information
function writeUsage($msg) {
    Write-Host "$msg`n" -foregroundcolor "red"
    $scriptname=$MyInvocation.ScriptName
    "Winlogcheck (or Logcheck for Windows)`n
    `Usage:`n
    `$scriptname -mode ignore [ -log <eventlog_name> ]`n
    `$scriptname -mode special -filter <filter_name>`n
    `$scriptname -mode test -filter <filter_name>`n`n"
}

function roundEventTime($depthHours) {
    return ((Get-Date).AddHours(-$depthHours).ToUniversalTime().ToString("yyyyMMdd HH") + ":00:00")
}
function baseEventQuery($log, $depthEventTime) {
    "SELECT * FROM Win32_NTLogEvent 
        WHERE LogFile = '{0}' AND TimeGenerated >= '{1}'"`
        -f $log, $depthEventTime
}

function runTest($filter) {
    $ignoreFilterPath = Join-Path (Join-Path $PSScriptRoot "ignore.conf") $filter
    $specialFilterPath = Join-Path (Join-Path $PSScriptRoot "special.conf") $filter
    $where = ""
    $filterin = ""
    if (Test-Path $ignoreFilterPath) {
        $where = Get-Content $ignoreFilterPath
        $filterin = "ignore"
    }
    elseif (Test-Path $specialFilterPath) {
        $where = Get-Content $specialFilterPath
        $filterin = "special"
    }
    else {
        Write-Host "Filter '$filter' not found`n" -foregroundcolor "red"
        exit(1)
    }
    $log =  $filter.Split('.')[0]
    $msg = "Test filter='$filter' in '$filterin' for log='$log'"
    if ( (Get-EventLog -List | Where-Object {$_.Log -eq $log}).Length -eq 0) {
        Write-Host "$msg : failed. Log '$log' not found`n" -foregroundcolor "red"
        exit (1)
        
    }
    $query = (baseEventQuery $log (roundEventTime(24)))
        + (" AND ({0})" -f $where)
    [wmisearcher]$wmis = $query
    try {
        $wmis.Get().Lenght
        Write-Host "$msg : OK`n" -foregroundcolor "green"
        "Query:  $query"
    } catch {
        Write-Host "$msg : failed.`n" -foregroundcolor "red"
        Write-Host "Query: $query`n" -foregroundcolor "red"
        "Exception:`n"
        $_.Exception.ToString()
        exit (1)
    }

}

function runSpecial($filter) {}

function runIgnore($log) {}

#
# MAIN PROCEDURE
#

# 1a Step. Check command line
if (!$mode -or  (($mode -ne "ignore") -and ($mode -ne "special") -and ($mode -ne "test"))) {
    writeUsage("Error: Mode not set or not found")
    exit(1)
} 
elseif ( ($mode -eq "special") -or ($mode -eq "test") ) {
    if (!$filter) {
        writeUsage("Error: Filter not set")
        exit(1)
    } 
}

# 1b Step. Read parameters from ini-file
$inifile = Join-Path $PSScriptRoot ( $MyInvocation.MyCommand.Name.Replace("ps1", "ini") )
if (!(Test-Path $inifile)) {
    Write-Host ("INI-file not found '{0}'." -f $inifile) -foregroundcolor "red"
    exit(1)
}
$ini = ConvertFrom-StringData((Get-Content $inifile) -join "`n")

# 2. Run Task
switch ($mode) {
    "ignore"  { runIgnore($log) }
    "special" { runSpecial($filter) }
    "test"    { runTest($filter) }
}