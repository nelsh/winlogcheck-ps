[CmdletBinding()]
Param($mode,$filterpath)

# Print usage information
function writeUsage($msg) {
    LogWrite "$msg`n" "red"
    $scriptname=$MyInvocation.ScriptName
    "Winlogcheck (or Logcheck for Windows)`n
    `Usage:`n
    `$scriptname -mode ignore`n
    `$scriptname -mode special -filterpath <absolute_or_relative_filter_path>`n
    `$scriptname -mode test -filterpath <absolute_or_relative_filter_path>`n`n"
}

function getFullFilterPath($filter) {
    if ($filter.Contains(":")) {
        return $filter.Trim()
    }
    Join-Path $PSScriptRoot $filter.Trim()
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
    $wmis.psbase.options.timeout = (New-Timespan -Minutes 30)
    try {
        return $wmis.Get()
    } catch {
        LogWrite "$msg : failed."  "red"
        LogWrite("Exception:`n" + $_.Exception.ToString())
        exit (1)
    }
}

function createReport($events, $totalevents, $log, $filterscount) {
    $tablehead = "<table style='width: 100%; margin-bottom:1em; border-bottom: 1px solid #ccc;'>
        <caption style='text-align: left; background:#f0f0f0; padding:0.5em 0.25em; 
            border-top: 2px solid #bbb;border-bottom: 1px solid #ccc;'>
        {0}. Found {1} from {2} events.</caption>"
    $report = "" 
    if ($mode -ne "ignore") {
        $report = ($tablehead -f ("Report '" + $filter + "'"), $events.Length, $totalevents )
    }
    else {
        $report = ($tablehead -f ($log.ToUpper() + ". Use " + $filterscount + " filter(s)"), $events.Length, $totalevents )
    }
    if ($events.Length -eq 0) {
        return ($report + "</table><br>")
    }
    $report += "<tr><th width=50>(!)</th><th width=60>Time</th><th width=40>EventID</th><th align=left>Source/Category</th><th align=left width=150>User</th></tr>"
    foreach ($e in $events) {
        $bg = "#F7F7F9"
        $level = $e.Type
        switch ($e.Type) {
            "information"   { $bg = "#D9EDF7" ; $level = "INFO"; $totals["foundother"]++ }
            "warning"       { $bg = "#FCF8E3" ; $level = "WARN"; $totals["foundwarnings"]++ }
            "error"         { $bg = "#F2DEDE" ; $level = "ERRO"; $totals["founderrors"]++ }
            "Audit Success" { $bg = "#D9EDF7" ; $level = "SUCC"; $totals["foundother"]++ }
            "Audit Failure" { $bg = "#F2DEDE" ; $level = "FAIL"; $totals["founderrors"]++ }
        }
        $shortTime = [DateTime]::ParseExact($e.TimeGenerated.Split('.')[0], "yyyyMMddHHmmss", [Globalization.CultureInfo]::InvariantCulture).ToLocalTime().ToString("HH:mm:ss")
        $message = ""
        if ([bool]$e.Message) {
            if ($log -eq "security") {
                $message = formatSecEventMsg($e.Message)
            }
            else {
                if ($e.CategoryString -eq "Web Event" -or $e.EventCode -eq 1309) {
                    $message = formatWebEventMsg($e.Message)
                }
                else {
                    $message = $e.Message.Replace("`r`n", "<br>")
                }
            }
        }
        else {
            $message = ("The following information was included with the event: " + $e.InsertionStrings)
        }
        $report += ("<tr style='background:{0}'><td>{1}</td><td>{2}</td><td align=right>{3}</td><td>{4}/{5}</td><td>{6}</td></tr><tr><td></td>`r`n<td colspan=6>{7}</td><tr>"`
            -f $bg, $level, $shortTime, $e.EventCode, $e.SourceName, $e.CategoryString, $e.UserName, $message)
    }
    $report += "</table><br>"
    return $report
}

function formatSecEventMsg ($message) {
    $i = 1
    $a = @()
    foreach ($s in $message.Replace("`r`n`r`n", "~").Split("~")) {
        if ($i -eq 1) {
            $a += , $s
        }
        elseif ($s.Contains("Account For Which Logon Failed:")`
            -or $s.Contains("Failure Information:")`
            -or $s.Contains("Network Information:") ) {
            $a += , $s
        }
        $i++
    }
    return ($a -join "<br>")
}

function formatWebEventMsg ($message) {
    Add-Type -AssemblyName System.Web
    $excInfo = ""
    $reqInfo = ""
    foreach ($s in $message.Replace(" `r `r", "~").Split("~")) {
        if ($s.StartsWith("Exception information:")) {
            foreach ($ss in $s.Replace(" `r    ", "~").Split("~")) {
                if ($ss.StartsWith("Exception message:") ) {
                    #foreach ($sss in $ss.Replace("`n   ", "~").Split("~")) {
                    #    $excInfo += ( $sss + "<br>`r`n" )
                    #}
                    $sss = $ss.Replace("`r", "").Replace("`n   ", "~").Split("~")
                    $excInfo += ( $sss[0] + "<br>`r`n")
                    $excInfo += ("<small>" + ($sss -join "<br>") + "</small>")
                }
            }
        }
        elseif ($s.StartsWith("Request information:")) {
            foreach ($ss in $s.Replace(" `r    ", "~").Split("~")) {
                if ($ss.StartsWith("Request URL:")`
                    -or $ss.StartsWith("User host address:") ) {
                    $reqInfo += ( [System.Web.HttpUtility]::HtmlEncode($ss) + "<br>`r`n" )
                }
            }
        }
    }
    return ($reqInfo + $excInfo)
}

function Send-Mail ($subj, $body) {
    $msg = New-Object Net.Mail.MailMessage($ini["MAILADDRESS"], $ini["MAILADDRESS"])
    $msg.IsBodyHtml = $true
    $msg.Subject = $subj
    $msg.Body = $body
    $smtp = New-Object Net.Mail.SmtpClient("")
    if ($ini["MAILSERVER"].Contains(":")) {
        $mailserver = $ini["MAILSERVER"].Split(":")
        $smtp.Host = $mailserver[0]
        $smtp.Port = $mailserver[1]
    }
    else {
        $smtp.Host = $ini["MAILSERVER"]
    }
    #$smtp.EnableSsl = $true 
    if ($ini.ContainsKey("MAILUSER") -and $ini.ContainsKey("MAILPASSWORD"))  {
        $smtp.Credentials = New-Object System.Net.NetworkCredential($ini["MAILUSER"], $ini["MAILPASSWORD"]); 
    }
    $smtp.Send($msg)
    LogWrite("... sent summary")
}

### Task TEST ###

function runTest($filter) {
    LogWrite("Test filter: '$filter'")
    $filter = getFullFilterPath($filter)
    if (Test-Path $filter) {
        $where = (Get-Content $filter) -join "`n"
        LogWrite("Filter found: '$filter'")
    }
    else {
        LogWrite "Filter '$filter' not found" "red"
        exit(1)
    }
    $log = (Split-Path $filter -leaf).Split('.')[0]
    $msg = "Test filter='$filter' for log='$log'"
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
    $specialFilterPath = getFullFilterPath($filter)
    if (Test-Path $specialFilterPath) {
        $where = (Get-Content $specialFilterPath) -join "`n"
    }
    else {
        LogWrite "Special filter '$filter' not found`n" "red"
        exit(1)
    }
    $log = (Split-Path $filter -leaf).Split('.')[0]
    $totals["allevents"] =  (getEvents $log).Length
    $events = getEvents $log $where

    LogWrite ("Report '{0}'. Found {1} from {2} events" `
         -f $filter, $events.Length, $totals["allevents"]) #,Get-Item env:\Computername).Value

#    if ($events.Length -gt 0) {
        $specialreport = (createReport $events $totals["allevents"] $log)
        Set-Content (Join-Path $ini["RPTPATH"] ((Split-Path $filter -leaf) + ".html")) $specialreport -Force
#    }
    if ([bool]$ini["MAILSEND"])  {
        $subj = "Winlogcheck "`
             + (Get-Item env:\Computername).Value`
             + " report '" + $filter + "': "`
             + "(errors=" + $totals["founderrors"].ToString()`
             + ", warnings=" + $totals["foundwarnings"].ToString()`
             + ", other=" + $totals["foundother"].ToString() + ")"`
             + " total " + $totals["allevents"] + " events"
        Send-Mail $subj $specialreport
    }
}

### Task IGNORE ###

function runIgnore() {
    $ignorereport = ""
    foreach ($l in (Get-EventLog -List)) {
        $log = $l.Log
        $filters = @()
        foreach ($filter in $ini["IGNORERULESPATH"]) {
            foreach ($f in (Get-ChildItem (getFullFilterPath($filter)) -filter "$log.*" -file)) {
                $filters += , ((get-content $f.FullName) -join "`n")
            }
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
             -f $log, $events.Length, $totalevents)
        $totals["allevents"] += $totalevents

        $ignorereport += (createReport $events $totalevents $log $filters.Count)
    }
    Set-Content (Join-Path $ini["RPTPATH"] ("ignore.html")) $ignorereport -Force
    if ([bool]$ini["MAILSEND"])  {
        $subj = "Winlogcheck "`
             + (Get-Item env:\Computername).Value + ": "`
             + "(errors=" + $totals["founderrors"].ToString()`
             + ", warnings=" + $totals["foundwarnings"].ToString()`
             + ", other=" + $totals["foundother"].ToString() + ")"`
             + " total " + $totals["allevents"].ToString() + " events"`
             + " in " + (Get-EventLog -List).Length.ToString() + " logs"
        Send-Mail $subj $ignorereport
    }
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
if (!($ini.ContainsKey("IGNORERULESPATH"))) { 
    $ini.Add("IGNORERULESPATH", @(Join-Path $PSScriptRoot "ignore.conf"))
} else {
    $ini["IGNORERULESPATH"] = $ini["IGNORERULESPATH"].Split(",")
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
if ($ini.ContainsKey("MAILADDRESS") -and $ini.ContainsKey("MAILSERVER"))  {
    $ini.Add("MAILSEND", $true) # One day
}

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
    `IGNORERULESPATH`t= {1}
    `LOGPATH`t`t= {2}
    `LOGSTORETIME`t= {3}
    `RPTPATH`t`t= {4}
    `DEPTHHOURS`t`t= {5}`n
    " -f $MyInvocation.MyCommand.Name,  ($ini["IGNORERULESPATH"] -join ', '),
    $ini["LOGPATH"], $ini["LOGSTORETIME"], $ini["RPTPATH"], $ini["DEPTHHOURS"])

# 1c Step. Check command line
if (!$mode -or  (($mode -ne "ignore") -and ($mode -ne "special") -and ($mode -ne "test"))) {
    writeUsage("Error: Mode not set or not found")
    exit(1)
} 
elseif ( ($mode -eq "special") -or ($mode -eq "test") ) {
    if (!$filterpath) {
        writeUsage("Error: Filter not set")
        exit(1)
    } 
}

####
#### 2 MAIN STEP. Run Task ###
####
$totals = @{
    "allevents" = 0
    "founderrors" = 0
    "foundwarnings" = 0
    "foundother" = 0
    }
switch ($mode) {
    "ignore"  { runIgnore }
    "special" { runSpecial($filterpath) }
    "test"    { runTest($filterpath) }
}

LogWrite ("Success")