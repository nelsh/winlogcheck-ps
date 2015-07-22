[CmdletBinding()]
Param($mode,$log,$filter)

# Print usage information
function writeUsage($msg) {
    LogWrite "$msg`n" "red"
    $scriptname=$MyInvocation.ScriptName
    "Winlogcheck (or Logcheck for Windows)`n
    `Usage:`n
    `$scriptname -mode ignore`n
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
    $depthEventTime = $ini["DEPTHSTRING"]
    $query = "SELECT * FROM Win32_NTLogEvent 
        WHERE LogFile = '$log' AND TimeGenerated >= '$depthEventTime'"
    if ([bool]$where) {
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
    LogWrite("Run query: $query")
    [wmisearcher]$wmis = $query
    try {
        return $wmis.Get()
    } catch {
        LogWrite "$msg : failed."  "red"
        LogWrite("Exception:`n" + $_.Exception.ToString())
        exit (1)
    }
}

function createReport($events, $totalevents, $log, $filterscount) {
    $tablehead ="<table><caption align=left>{0}. Found {1} from {2} events.</caption>
        <tr><th width=100>(!)</th><th width=100>Time</th><th width=50>EventID</th><th>Source/Category</th><th width=200>User</th></tr>" 
    $report = "" 
    LogWrite ("Log = $log")
    if ($mode -ne "ignore") {
        $report = ($tablehead -f ("Report '" + $filter + "'"), $events.Length, $totalevents )
    }
    else {
        $report = ($tablehead -f ($log.ToUpper() + ". Use " + $filterscount), $events.Length, $totalevents )
    }
    foreach ($e in $events) {
        $shortTime = [DateTime]::ParseExact($e.TimeGenerated.Split('.')[0], "yyyyMMddHHmmss", [Globalization.CultureInfo]::InvariantCulture).ToLocalTime().ToString("HH:mm:ss")
        $report += ("<tr><td>{0}</td><td>{1}</td><td align=right>{2}</td><td>{3}/{4}</td><td>{5}</td></tr><tr><td></td><td colspan=6>{6}</td><tr>"`
            -f $e.Type, $shortTime, $e.EventCode, $e.SourceName, $e.CategoryString, $e.UserName, $e.Message)
    }
    $report += "</table>"
    return $report
}


### Task TEST ###

function runTest($filter) {
    LogWrite("Test filter: '$filter'")
    $ignoreFilterPath = ignoreFilterPath($filter)
    $specialFilterPath = specialFilterPath($filter)
    $where = ""
    $filterin = ""
    if (Test-Path $ignoreFilterPath) {
        $where = Get-Content $ignoreFilterPath
        $filterin = "ignore"
        LogWrite("Filter found: '$ignoreFilterPath'")
    }
    elseif (Test-Path $specialFilterPath) {
        $where = Get-Content $specialFilterPath
        $filterin = "special"
        LogWrite("Filter found: '$specialFilterPath'")
    }
    else {
        LogWrite "Filter '$filter' not found" "red"
        exit(1)
    }
    $log =  $filter.Split('.')[0]
    $msg = "Test filter='$filter' in '$filterin' for log='$log'"
    if ( (Get-EventLog -List | Where-Object {$_.Log -eq $log} ).Length -eq 0) {
        LogWrite "$msg : failed. Log '$log' not found`n" "red"
        exit (1)
        
    }
    $query = makeEventQuery $log $where
    (getEvents  $log $where).Lenght
    LogWrite "$msg : OK" "green"
}

### Task SPECIAL ###

function runSpecial($filter) {
    $specialFilterPath = specialFilterPath($filter)
    if (Test-Path $specialFilterPath) {
        $where = Get-Content $specialFilterPath
    }
    else {
        LogWrite "Special filter '$filter' not found`n" "red"
        exit(1)
    }
    $log = $filter.Split('.')[0]
    $totalevents =  (getEvents $log).Length
    $events = getEvents $log $where

    LogWrite ("Report '{0}'. Found {1} from {2} events" `
         -f $filter, $events.Length, $totalevents) #,Get-Item env:\Computername).Value

    if ($events.Length -gt 0) {
        Set-Content (Join-Path $ini["RPTPATH"] ($filter + ".html")) (createReport $events $totalevents) -Force
    }
}

### Task IGNORE ###

function runIgnore() {
    $ignorereport = ""
    foreach ($l in (Get-EventLog -List)) {
        $log = $l.Log
        $filters = @()
        foreach ($f in (Get-ChildItem (Join-Path $PSScriptRoot "ignore.conf") -filter "$log.*" -file)) {
            $filters += , (get-content $f.FullName) 
        }
        if ($filters.Count -gt 0 ) {
            $where = "(" + [system.String]::Join(") OR (", $filters) + ")"
        }
        else {
            $where = ""
        }
        $totalevents =  (getEvents $log).Length
        $events = getEvents $log $where
        LogWrite ("Eventlog '{0}'. Found {1} from {2} events" `
             -f $log, $events.Length, $totalevents) #,Get-Item env:\Computername).Value

#        if ($events.Length -gt 0) {
            $ignorereport += (createReport $events $totalevents $log $filters.Count)
#        }
    }
    Set-Content (Join-Path $ini["RPTPATH"] ("ignore.html")) $ignorereport -Force
}

#
# MAIN PROCEDURE
#

# 1a Step. Read parameters (if exsist) from ini-file and set defaults
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
    $ini.Add("DEPTHHOURS", 24) # One day
}
$ini.Add("DEPTHSTRING", ` #yyyyMMdd HH:00:00
    ((Get-Date).AddHours(-$ini["DEPTHHOURS"]).ToUniversalTime().ToString("yyyyMMdd HH") + ":00:00"))

# 1b Step. Simple logging
# Remove old logfiles (YYYYMMDD.log)
Get-ChildItem $ini["LOGPATH"] | Where-Object {$_.Name -match "^\d{8}.log$"}`
    | ? {$_.PSIsContainer -eq $false -and $_.lastwritetime -lt (get-date).adddays(-$ini["LOGSTORETIME"])}`
    | Remove-Item -Force

# Create logfile 
$logfile = Join-Path $ini["LOGPATH"] ( (Get-Date).ToString('yyyyMMdd') + ".log" )
if (!(Test-Path $logfile)) {
    New-Item -type file $logfile -force | Out-Null
}
# and simple function for logging to screen/logfile
function LogWrite($msg, $color) {
    Add-Content $logfile ((get-date -format HH:mm:ss) + " " + $msg)
    if ([bool]$color) {
        Write-Host "$msg" -foregroundcolor $color
    } 
    else {
        Write-Host $msg
    }
}

Logwrite ("Start {0}`n
Parameters:`n
    `LOGPATH`t`t= {1}
    `LOGSTORETIME`t= {2}
    `RPTPATH`t`t= {3}
    `DEPTHHOURS`t`t= {4}`n
    " -f $MyInvocation.MyCommand.Name, 
    $ini["LOGPATH"], $ini["LOGSTORETIME"], $ini["RPTPATH"], $ini["DEPTHHOURS"])

# 1c Step. Check command line
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

####
#### 2 MAIN STEP. Run Task ###
####
switch ($mode) {
    "ignore"  { runIgnore }
    "special" { runSpecial($filter) }
    "test"    { runTest($filter) }
}

LogWrite ("Success")