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

function runTest($filter) {
    $where = ""
    if (Test-Path (Join-Path $ignorepath $filter)) {
        $where = Get-Content (Join-Path $ignorepath $filter)
    }
    elseif (Test-Path (Join-Path $specialpath $filter)) {
        $where = Get-Content (Join-Path $specialpath $filter)
    }
    else {
        Write-Host "Filter '$filter' not found`n" -foregroundcolor "red"
        exit(1)
    }
    $log =  $filter.Split('-')[0]

    $query = "SELECT * FROM Win32_NTLogEvent 
        WHERE LogFile = '{0}' AND TimeGenerated >= '{1}' AND ({2})"`
        -f $log, (Get-Date).AddDays(-1).ToUniversalTime().ToString("yyyyMMdd HH:mm:ss"), $where
    Write-Debug "Run query: $query"
    Get-WmiObject -Query $query
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
$ignorepath = Join-Path $PSScriptRoot "ignore.conf"
$specialpath = Join-Path $PSScriptRoot "special.conf"
switch ($mode) {
    "ignore"  { runIgnore($log) }
    "special" { runSpecial($filter) }
    "test"    { runTest($filter) }
}