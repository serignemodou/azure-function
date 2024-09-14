# Input bindings are passed in via param block.
param($Timer)

# Get the current universal time in the default string format
$currentUTCtime = (Get-Date).ToUniversalTime()

# The 'IsPastDue' property is 'true' when the current function invocation is later than scheduled.
if ($Timer.IsPastDue) {
    Write-Host "PowerShell timer is running late!"
}

# Write an information log with the current time.
Write-Host "PowerShell timer trigger function ran! TIME: $currentUTCtime"

# Query to run to retrieve all appgws with the tag Operational-Schedule:Yes
$kqlQuery = @"
Resources
| where type == 'microsoft.network/applicationgateways'
| mvexpand tags
| extend tagKey = tostring(bag_keys(tags)[0])
| extend tagValue = tostring(tags[tagKey])
| where tagKey =~ "Operational-Schedule"
| where tagValue =~ "Yes"
| order by subscriptionId asc
"@

$batchSize = 100
$skipResult = 0

$appgwNumber = 1

# Set the return code
$returnError = 0

while ($true) {

    if ($skipResult -gt 0) {
        $graphResult = Search-AzGraph -Query $kqlQuery -first $batchSize -SkipToken $graphResult.SkipToken
    } 
    else {
        $graphResult = Search-AzGraph -Query $kqlQuery -first $batchSize
    }

    $listAppgw += $graphResult

    if ($graphResult.Count -lt $batchSize) {
        break;
    }
    $skipResult += $skipResult + $batchSize
}

Write-Host "Appgws with tag 'Operational-Schedule:Yes' : Found $($listAppgw.count) appgws"

Write-Host "Current subscription :" (Get-AzContext).Subscription.Name

foreach ($appgw in $listAppgw) {

    try {
        if ((Get-AzContext).Subscription.Id -ne $appgw.subscriptionId) {
            Set-AzContext -Subscription $appgw.subscriptionId -ErrorAction Stop | Out-Null
            Write-Host "Current subscription :" (Get-AzContext).Subscription.Name
        }  
    }
    catch {
        Write-Error "'Set-AzContext' : $($_.Exception.Message)"
        $exception = New-Object System.Exception("Getting Set-AzContext exception...exiting")
        $null = throw $exception.Message
        exit
    }

    Write-Host "Current Appgw : ($appgwNumber/$($listAppgw.count)) $($appgw.Name)"
    $appgwobj = Get-AzApplicationGateway -ResourceGroupName $appgw.Resourcegroup -Name $appgw.Name
    $tags = $appgwobj.Tag

    $TimeNow = Get-Date
    #Write-Host "Current local time is : $TimeNow"

    $TimeNow = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId($(Get-Date), [System.TimeZoneInfo]::Local.Id, 'Central Europe Standard Time')
    #Write-Host "Current time converted to CET is : $TimeNow"    
            
    # Get the Value of the "Operational-UTCOffset" Tag, that represents the offset from UTC
    $UTCOffset = $tags["Operational-UTCOffset"]

    # Get current time in the Adjusted Time Zone
    if ($UTCOffset) {
        $TimeZoneAdjusted = $TimeNow.AddHours($UTCOffset)
        #Write-Host "Current time after adjusting the Time Zone is: $TimeZoneAdjusted"
    }
    else {
        $TimeZoneAdjusted = $TimeNow
    }

    ### Current Time associations

    $Day = $TimeZoneAdjusted.DayOfWeek

    if ($TimeZoneAdjusted.DayOfWeek -match "Sunday|Saturday") {
        $TodayIsWeekend = $true
    }
    else {
        $TodayIsWeekend = $false
    }

    ### Get Exclusions
    $Exclude = $false
    $Reason = ""
    $Exclusions = $tags["Operational-Exclusions"]

    if($null -ne $Exclusions){
        $Exclusions = $Exclusions.Split(',')
        foreach ($Exclusion in $Exclusions) {
            # Check excluded actions:
            If ($Exclusion.ToLower() -eq "stop"){ $actionExcluded = "Stop" }
            If ($Exclusion.ToLower() -eq "start"){ $actionExcluded = "Start" }
            
            # Check excluded days and compare with current day
            If ($Exclusion.ToLower() -like "*day") {
                if ($Exclusion -eq $Day){ 
                    $Exclude = $true
                    $Reason=$Day
                }
            }

            #Check excluded weekdays and copare with Today
            If ($Exclusion.ToLower() -eq "weekdays") {
                    if (-not $TodayIsWeekend){
                        $Exclude = $true
                        $Reason="Weekday"
                    }
            }

            # Check excluded weekends and compare with Today
            If ($Exclusion.ToLower() -eq "weekends") {
                if ($TodayIsWeekend){
                    $Exclude = $true
                    $Reason="Weekend"
                }
            }

            If ($Exclusion -eq (Get-Date -UFormat "%b %d")) {
                $Exclude = $true
                $Reason = "Date Excluded"
            }
        }
    }
    else{
        Write-Host "No 'Operational-Exclusions' tag found on '$($appgw.Name)'"
    }

    if (-not $Exclude) {

        # Get values from Tags and compare to the current time

        if (-not $TodayIsWeekend) {
            $ScheduledTime = $tags["Operational-Weekdays"]			
        } else{
            $ScheduledTime = $tags["Operational-Weekends"]
        }

        if ($ScheduledTime) {
            
            $ScheduledTime = $ScheduledTime -split "-"
            $ScheduledStart = $ScheduledTime[0]
            $ScheduledStop = $ScheduledTime[1]

            $ScheduledStartTime = Get-Date -Hour "$ScheduledStart" -Minute 0 -Second 0
            $ScheduledStopTime = Get-Date -Hour "$ScheduledStop" -Minute 0 -Second 0

            If (($TimeZoneAdjusted -gt $ScheduledStartTime) -and ($TimeZoneAdjusted -lt $ScheduledStopTime)) {
                #Current time is within the interval
                Write-Host "'$($appgw.Name)' should be running now"
                $action = "Start"
            } 
            else {
                #Current time is outside of the operational interval
                Write-Host "'$($appgw.Name)' should be stopped now"
                $action = "Stop"
            }

            If ($action -notlike "$actionExcluded") { #Make sure that action was not excluded
                #Get currently status
                $appgwCurrentState = $appgwobj.OperationalState
                
                if (($action -eq "Start") -and ($appgwCurrentState -eq "Stopped")) {
                    Write-host "Starting '$($appgw.Name)'"
                    try{
                        Start-AzApplicationGateway -ApplicationGateway $appgwobj -ErrorAction Stop | Out-Null                    }
                    catch{
                        # Even if we don't wait for the appgw to be started, an erreor can be raised when asking for the start
                        Write-Error "Error occured when starting '$($appgw.Name)' : $($_.Exception.Message)"
                        $returnError = 1
                        Continue # Go to next appgw in the current loop
                    }                    
                } 
                elseif ( $action -eq "Stop" -and ($appgwCurrentState -eq "Running") ) {                           
                    Write-host "Stopping '$($appgw.Name)'"
                    try{
                        Stop-AzApplicationGateway -ApplicationGateway $appgwobj -ErrorAction Stop | Out-Null
                    }
                    catch{
                        # Even if we don't wait for the appgw to be stopped, an erreor can be raised when asking for the stop
                        Write-Error "Error occured when stopping '$($appgw.Name)' : $($_.Exception.Message)"
                        $returnError = 1
                        Continue # Go to next appgw in the current loop
                    } 
                } 
                else {
                    Write-Host "'$($appgw.Name)' status is: '$appgwCurrentState'. No action will be performed ..."
                }
            } else {
                Write-Host "'$($appgw.Name)' is Excluded from changes during this run because Operational-Exclusions Tag contains action '$action'."
            }
        } else {
            Write-Warning "Scheduled Running Time for '$($appgw.Name)' was not detected. No action will be performed..."
        }
    } else {
        Write-Host "'$($appgw.Name)' is Excluded from changes during this run because Operational-Exclusions Tag contains exclusion '$Reason'."
   }
  
   $appgwNumber++
}

if ( $returnError -ne 0 )
{
    $exception = New-Object System.Exception("At least one error appeared, see errores above !!")
    $null = throw $exception.Message
}
