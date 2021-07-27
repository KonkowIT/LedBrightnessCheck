$host.UI.RawUI.WindowTitle = "LedBrightnessCheck"


$homeDir = "C:\SN_Scripts\LedBrightnessCheck"
$jsonPath = "$homeDir\sn_data.json"

# API
$requestURL = 'http://api2.arrow.screennetwork.pl/'
$requestHeaders = @{'sntoken' = '***'; 'Content-Type' = 'application/json' }

# SSH
$username = "sn"
$secpasswd = ConvertTo-SecureString "***" -AsPlainText -Force
$credential = new-object -typename System.Management.Automation.PSCredential -argumentlist $username, $secpasswd
$authenticationKey = ( -join ($($env:USERPROFILE), "\.ssh\ssh-key"))

# Script
$script = @"
<#
    0 = logs ok
    1 = 'LED screen not detected'
    2 = No new logs in log file
    3 = No LedStudio software, No log file
#>

if ((Test-Path 'c:\screennetwork\LEDBrightness.log') -and (Test-Path 'c:\screennetwork\snled\LEDBrigths.exe')) {
    `$partLog = Get-Content 'c:\screennetwork\LEDBrightness.log' -tail 15
    `$lineNumber = `$partLog | Select-String -inputobject { `$_ } -Pattern 'BrightnessLOG' | % { `$_.lineNumber } | Select-Object -Last 1
    `$finalPartLog = `$partLog | Where-Object ReadCount -ge `$lineNumber
    `$logDate = `$partLog | Where-Object ReadCount -eq (`$lineNumber + 1)
    `$actualDate = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    
    if ((New-TimeSpan -Start `$logDate -End `$actualDate).Hours -lt 2) {
        
        if ((`$finalPartLog | Select-String -InputObject { `$_ } -Pattern 'LED screen not detected').Count -ne 0) { 
            `$sendMessage = 1 
        } 
        else { 
            `$sendMessage = 0
        }
    }
    else {
        `$sendMessage = 2
    }

} else {
    `$sendMessage = 3
} return  `$sendMessage
"@

# Script start date
$timeEnd = get-date -DisplayHint Time "22:00:01"

# Server SN
$serverSN = "10.99.99.1"

# Functions
function Start-SleepTimer($seconds) {
    $doneDT = (Get-Date).AddSeconds($seconds)
    while ($doneDT -gt (Get-Date)) {
        $secondsLeft = $doneDT.Subtract((Get-Date)).TotalSeconds
        $percent = ($seconds - $secondsLeft) / $seconds * 100
        Write-Progress -activity "LED connections" -Status "Nastepne sprawdzenie polaczen za" -SecondsRemaining $secondsLeft -PercentComplete $percent
        [System.Threading.Thread]::Sleep(500)
    } 
    Write-Progress -activity "Start-sleep" -Status "Nastepne sprawdzenie polaczen za" -SecondsRemaining 0 -Completed
}

Function SendSlackMessage {
    param (
        [string] $message
    )

    $token = "***"
    $send = (Send-SlackMessage -Token $token -Channel 'brightness_errors_ledstudio' -Text $message).ok
    #$send = (Send-SlackMessage -Token $token -Channel 'testowanko' -Text $message).ok
    Write-host "Wiadomosc wyslana: $send"
}

Function SendSlackMessageTemplate {
    param (
        [string] $message,
        [string] $name,
        [string] $loc
    )

    SendSlackMessage -message "*$name - $loc*`n``````$message``````"
}

function GetComputersFromAPI {
    [CmdletBinding()]
    param(
        [parameter(ValueFromPipeline)]
        [ValidateNotNull()]
        [String]$networkName,
        [Array]$dontCheck
    )
      
    # Body
    $requestBody = @"
{

"network": [$($networkName)]

}
"@
  
    # Request
    try {
        $request = Invoke-WebRequest -Uri $requestURL -Method POST -Body $requestBody -Headers $requestHeaders -ea Stop
    }
    catch [exception] {
        $Error[0]
        Exit 1
    }
  
    # Creating PS array of sn
    if ($request.StatusCode -eq 200) {
        $requestContent = $request.content | ConvertFrom-Json
    }
    else {
        Write-host ( -join ("Received bad StatusCode for request: ", $request.StatusCode, " - ", $request.StatusDescription)) -ForegroundColor Red
        Exit 1
    }
  
    $snList = @()
    $requestContent | ForEach-Object {
        if ((!($dontCheck -match $_.name)) -and ($_.lok -ne "LOK0014")) {
            $hash = [ordered]@{
                SN              = $_.name;
                IP              = $_.ip;
                Localisation    = $_.lok_name.toString().Trim();
                LastCheckResult = $false;
                SendedMsg       = $false;
            }
  
            $snList = [array]$snList + (New-Object psobject -Property $hash)
        }
    }
  
    return $snList
}

# VPN not connected
if (!(Test-Connection -ComputerName $serverSN -Count 3 -Quiet)) {
    do {
        Write-Host "VPN nie polaczony" -ForegroundColor Red
        $arg = "& `'c:\screennetwork\admin\check-vpn.bat`'" 
        Start-Process powershell.exe -ArgumentList $arg -Wait verb RunAs
        Start-Sleep -s 60
    }
    until(Test-Connection -ComputerName $serverSN -Count 3 -Quiet)
}
# VPN connected
else {
    do {
        $timeNow = get-date -DisplayHint Time -Format "HH:mm:ss"
        $freshData = @(GetComputersFromAPI -networkName '"LED City", "LED Premium"')

        if (Test-Path $jsonPath) { 
            try { [System.Collections.ArrayList]$localData = ConvertFrom-Json (Get-Content $jsonPath -Raw -ea Continue) -ea Continue }
            catch { Write-Host "ERROR: $($_.Exception.message)" }

            foreach ($f in $freshData) {
                $counter = 0
                $ldCount = $localData.Count
                For ($i = 0; $i -lt $ldCount; $i++) {
            
                    if ($f.sn -eq $localData[$i].sn) {
                        # IP update
                        if ($f.ip -ne $localData[$i].ip) {
                            $localData[$i].ip = $f.ip
                        }
    
                        # Localisation update
                        if ($f.Localisation -ne $localData[$i].Localisation) {
                            $localData[$i].Localisation = $f.Localisation
                        }
                    }
                    else {
                        $counter++

                        if ($counter -eq $ldCount) {
                            # ADD NEW SN
                            $hash = [ordered]@{
                                SN              = $f.SN;
                                IP              = $f.IP;
                                Localisation    = $f.Localisation;
                                LastCheckResult = $f.LastCheckResult;
                                SendedMsg       = $f.SendedMsg;
                            }
              
                            Write-host "Adding $($f.sn) to json"
                            $localData = [array]$localData + (New-Object psobject -Property $hash)
                        }
                    }
                }
            }

            for ($l = 0; $l -lt $localData.count; $l++) {
                $n = $localData[$l].sn
      
                # REMOVE MISSING SN
                if (!($freshData.sn -contains $n)) {
                    Write-host "Removing $n from json"
                    $localData.Remove($localData[$l])
                }
            }

            ConvertTo-Json -InputObject $localData | Out-File $jsonPath -Force
        }
        else {
            ConvertTo-Json -InputObject $freshData | Out-File $jsonPath -Force
        }

        [System.Collections.ArrayList]$serversArray = ConvertFrom-Json (Get-Content $jsonPath -Raw -ea Stop) -ea Stop
        Write-Host "`nLedBrightnessCheck $timeNow`n" -BackgroundColor Black -ForegroundColor Magenta

        foreach ($led in $serversArray) {
            $getSSHSessionId = $null
            $snIP = $led.ip
            $sn = $led.sn
            $snLoc = $led.Localisation
            
            if ($snIP -eq "NULL") {
                Write-host "`nKomputer jest offline: $sn - $snLoc"  -ForegroundColor Red
            }
            elseIf ($led.LastCheckResult -eq "NoLedStudio") {
                Write-host "`nJSON: $sn - $snLoc`nNa komputerze nie ma zainstalowanego LED Studio" 
            }
            else {
                try {
                    New-SSHSession -ComputerName $snIP -Credential $credential -KeyFile $authenticationKey -ConnectionTimeout 300 -force -ErrorAction Stop -WarningAction silentlyContinue | out-null
                }
                catch {
                    Write-host "`nBlad laczenia z komputerem: $sn - $snLoc"  -ForegroundColor Red
                    Write-host $_.Exception.Message
                }

                $getSSHSessionId = (Get-SSHSession | Where-Object { $_.Host -eq $snIP }).SessionId

                if ($null -ne $getSSHSessionId) {
                    Write-host "`nPolaczono: $sn - $snLoc" -ForegroundColor Green
                    $out = (Invoke-SSHCommand -SessionId $getSSHSessionId -Command "$script").output[0].Trim()
                    $led.LastCheckResult = $out

                    <#
                        0 = logs ok
                        1 = 'LED screen not detected'
                        2 = No new logs in log file
                        3 = No LedStudio software, No log file
                    #>

                    if ($out -eq 0) {
                        Write-host "Wartosc w pliku log ok"

                        if ($led.SendedMsg -eq $true) {
                            SendSlackMessageTemplate -name $sn -loc $snLoc -message "Ekran zaczal poprawnie logowac wartosc ustawianej jasnosci"
                            $led.SendedMsg = $false
                        }
                    }
                    elseif ($out -eq 1) {
                        Write-host "LED SCREEN NOT DETECTED!" -ForegroundColor Red -BackgroundColor Black
                        
                        if ($led.SendedMsg -eq $false) {
                            SendSlackMessageTemplate -name $sn -loc $snLoc -message "LED Screen not detected"
                            $led.SendedMsg = $true
                        }
                    }
                    elseif ($out -eq 2) {
                        Write-host "BRAK NOWYCH WPISOW W PLIKU LOG OD 2H" -ForegroundColor Red -BackgroundColor Black

                        if ($led.SendedMsg -eq $false) {
                            SendSlackMessageTemplate -name $sn -loc $snLoc -message "Brak nowych wpisow w pliku log od co najmniej 2H"
                            $led.SendedMsg = $true
                        }
                    }
                    elseif ($out -eq 3) {
                        Write-host "Brak oprogramowania LED Studio na tym komuterze"
                        $led.LastCheckResult = "NoLedStudio"
                    }
                    else {
                        Write-host "BLAD: $out" -ForegroundColor Red
                    }

                    Write-Host ( -join ("Zamykanie polaczenia SSH: ", (Remove-SSHSession -SessionId $getSSHSessionId)))
                }
            }
        }

        ConvertTo-Json -InputObject $serversArray | Out-File $jsonPath -Force
        Start-SleepTimer 600
    } while ((New-TimeSpan -Start $timeNow -End $timeEnd) -gt 0)
}