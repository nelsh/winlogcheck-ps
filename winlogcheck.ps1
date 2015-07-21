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


function ignoreFilterPath($filter) {
    Join-Path (Join-Path $PSScriptRoot "ignore.conf") $filter
}
function specialFilterPath($filter) {
    Join-Path (Join-Path $PSScriptRoot "special.conf") $filter
}

function makeEventQuery($log, $where) {
    $depthEventTime = ((Get-Date).AddHours(-$ini["DEPTHHOURS"]).ToUniversalTime().ToString("yyyyMMdd HH") + ":00:00")
    $query = "SELECT * FROM Win32_NTLogEvent 
        WHERE LogFile = '$log' AND TimeGenerated >= '$depthEventTime'"
    if ($where.Length -gt 0) {
        $not = ""
        if ($mode -eq "ignore") {
            $not = " NOT "
        }
        $query += " AND $not ( $where )"
    }
    return $query
}


function getEvents($log, $where) {
    $query = makeEventQuery $log $where
    [wmisearcher]$wmis = $query
    try {
        return $wmis.Get()
    } catch {
        Write-Host "$msg : failed.`nQuery: $query`n" -foregroundcolor "red"
        "Exception:`n"
        $_.Exception.ToString()
        exit (1)
    }
}

function createReport($events) {
    foreach ($e in $events) {
        $shortTime = [DateTime]::ParseExact($e.TimeGenerated.Split('.')[0], "yyyyMMddHHmmss", [Globalization.CultureInfo]::InvariantCulture).ToLocalTime().ToString("HH:mm:ss")
        Write-Host ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}`n"`
            -f $e.Type, $shortTime, $e.SourceName, $e.CategoryString, $e.EventCode, $e.UserName)
        Write-Host ("{0}`n`n" -f $e.Message)
    }
}


### Task TEST ###

function runTest($filter) {
    $ignoreFilterPath = ignoreFilterPath($filter)
    $specialFilterPath = specialFilterPath($filter)
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
    if ( (Get-EventLog -List | Where-Object {$_.Log -eq $log} ).Length -eq 0) {
        Write-Host "$msg : failed. Log '$log' not found`n" -foregroundcolor "red"
        exit (1)
        
    }
    $query = makeEventQuery $log $where
    try {
        (getEvents  $log $where).Lenght
        Write-Host "$msg : OK`n" -foregroundcolor "green"
        "Query:  $query"
    } catch {
        Write-Host "$msg : failed.`nQuery: $query`n" -foregroundcolor "red"
        "Exception:`n"
        $_.Exception.ToString()
        exit (1)
    }

}

### Task SPECIAL ###

function runSpecial($filter) {
    $specialFilterPath = specialFilterPath($filter)
    if (Test-Path $specialFilterPath) {
        $where = Get-Content $specialFilterPath
    }
    else {
        Write-Host "Special filter '$filter' not found`n" -foregroundcolor "red"
        exit(1)
    }
    $events = getEvents ($filter.Split('.')[0]) $where
    if ($events.Length > 0) {
        createReport($events)
    }
}

### Task IGNORE ###

function runIgnore($log) {
    foreach ($log in (Get-EventLog -List)) {
        $logname = $log.Log
        $filters = @()
        foreach ($f in (Get-ChildItem (Join-Path $PSScriptRoot "ignore.conf") -filter "$logname.*" -file)) {
            $filters += , (get-content $f.FullName) 
        }
        if ($filters.Count > 0 ) {
            $where = "(" + [system.String]::Join(") OR (", $filters) + ")"
        }
        $events = getEvents $logname $where
        if ($events.Length > 0) {
            createReport($events)
        }
    }
}

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

# 1b Step. Read parameters (if exsist) from ini-file and set defaults
$inifile = Join-Path $PSScriptRoot ( $MyInvocation.MyCommand.Name.Replace("ps1", "ini") )
$ini = @{}
if (Test-Path $inifile) {
    $ini = ConvertFrom-StringData((Get-Content $inifile) -join "`n")
}
if (!($ini.ContainsKey("LOGPATH"))) { 
    $ini.Add("LOGPATH", $PSScriptRoot) # whereis this script
}
if (!($ini.ContainsKey("RPTPATH"))) { 
    $ini.Add("RPTPATH", $PSScriptRoot) # whereis this script
}
if (!($ini.ContainsKey("LOGSTORETIME"))) { 
    $ini.Add("LOGSTORETIME", 7) # One week
}
if (!($ini.ContainsKey("DEPTHHOURS"))) { 
    $ini.Add("DEPTHHOURS", 24) # One week
}

# 1c Step. Simple logging
# Remove old logfiles (YYYYMMDD.log)
Get-ChildItem $ini["LOGPATH"] | Where-Object {$_.Name -match "^\d{8}.log$"}`
    | ? {$_.PSIsContainer -eq $false -and $_.lastwritetime -lt (get-date).adddays(-$ini["LOGSTORETIME"])}`
    | Remove-Item -Force

# Create logfile 
$log = Join-Path $ini["LOGPATH"] ( (Get-Date).ToString('yyyyMMdd') + ".log" )
if (!(Test-Path $log)) {
    New-Item -type file $log -force | Out-Null
}
# and simple function for logging to screen/logfile
function LogWrite($msg) {
    Add-Content $log ((get-date -format HH:mm:ss) + " " + $msg)
    Write-Output $msg
}

####
#### 2 MAIN STEP. Run Task ###
####
switch ($mode) {
    "ignore"  { runIgnore($log) }
    "special" { runSpecial($filter) }
    "test"    { runTest($filter) }
}