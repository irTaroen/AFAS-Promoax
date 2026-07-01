<#
Deze module levertloggingfunctionaliteit. De functie initialize-log kan meerdere keren wordeen aangeroepen om bijvoorbeeld het loglevel te veranderen.
Standaard wordt per dag een bestand aangemaakt in de directory <scriptpath>\log.
Bij een Error of Fatal kan ook een bestand in D:\FileCheck geplaatst. Deze optie is aan te zetten bij het initialieren met de optie NoFileCheck:$false 

Door R. Glintmeijer, 2018


    ########### Init Logging Module ##############
    if(!$PSScriptRoot) {
        $PSScriptRoot = Split-Path $MyInvocation.MyCommand.Path -Parent
    }

    Import-Module "$PsScriptRoot\Modules\Logging.psm1"
    Initialize-Log -Level 'INFO'
    ########### Init Logging Module ##############

    # Hier je code met Write-LogInfo

    Close-Log

#>

Set-StrictMode -Version Latest

function Write-LogInfo
{
    param
    (
        [parameter(Mandatory=$True, ValueFromPipeLine=$True)]
        [string[]] $Messages
    )
    Process
    {
        if (!(Test-path variable:script:Initialized))
        {
            Initialize-Log
        }

        if($Script:LogInfo)
        {
            Write-Host -Object "$(Get-Date -Format "HH:mm:ss:fff") INFO   : " -NoNewline
            Write-Host -Object "$Messages"
            try
            {
                "$(Get-Date -Format $Script:LogDateFormat) Info    : $Messages" | out-file -encoding ASCII "$Script:LogFileName" -Append -ErrorAction Stop
            }
            catch
            {
                Write-LogFatal "Logging to file $($Script:LogFileName) failed: $($_.Exception.Message)"
            }
        } 
    }
}

function Write-LogDebug
{
    param
    (
        [parameter(Mandatory=$True, ValueFromPipeLine=$True)]
        [string[]] $Messages
    )
    Process
    {
        if (!(Test-path variable:script:Initialized))
        {
            Initialize-Log
        }

        if($Script:LogDebug)
        {
            Write-Host -Object "$(Get-Date -Format "HH:mm:ss:fff") DEBUG  : " -NoNewline
            Write-Host -ForegroundColor Green -Object "$Messages"
            try
            {
                "$(Get-Date -Format $Script:LogDateFormat) Debug   : $Messages" | out-file -encoding ASCII "$Script:LogFileName" -append -ErrorAction Stop
            }
            catch
            {
                Write-LogFatal "Logging to file $($Script:LogFileName) failed: $($_.Exception.Message)"
            }
        }
    }
}


function Write-LogWarning
{
    param
    (
        [parameter(Mandatory=$True, ValueFromPipeLine=$True)]
        [string[]] $Messages
    )
    Process
    {
        if (!(Test-path variable:script:Initialized))
        {
            Initialize-Log
        }

        if($Script:LogWarning)
        {
            Write-Host -Object "$(Get-Date -Format "HH:mm:ss:fff") WARNING: " -NoNewline
            Write-Host -ForegroundColor Yellow -Object "$Messages"
            try
            {
                "$(Get-Date -Format $Script:LogDateFormat) Warning : $Messages" | out-file -encoding ASCII "$Script:LogFileName" -append -ErrorAction Stop
            }
            catch
            {
                Write-LogFatal "Logging to file $($Script:LogFileName) failed: $($_.Exception.Message)"
            }
        }
    }
}

function Write-LogError
{
    param
    (
        [parameter(Mandatory=$True, ValueFromPipeLine=$True)]
        [string[]] $Messages
    )
    Process
    {
        if (!(Test-path variable:script:Initialized))
        {
            Initialize-Log
        }

        if($Script:LogError)
        {
            $Script:ErrorCount++
            Write-Host -Object "$(Get-Date -Format "HH:mm:ss:fff") ERROR  : " -NoNewline
            Write-Host -ForegroundColor Red -Object "$Messages"
            try
            {
                $datumTijd = (Get-Date -Format $Script:LogDateFormat)
                "$datumTijd Error   : $Messages" | out-file -encoding ASCII "$Script:LogFileName" -append -ErrorAction Stop
                if(!($Script:NoFileCheck))
                {    
                    "$datumTijd Error   : $Messages" | out-file -encoding ASCII "$Script:ErrFileName" -append -ErrorAction Stop
                }
            }
            catch
            {
                Write-LogFatal "Logging to file $($Script:LogFileName) failed: $($_.Exception.Message)"
            }
            
        }
    }
}

function Write-LogException
{
    param
    (
        [parameter(Mandatory=$True, ValueFromPipeLine=$True)]
        [System.Management.Automation.ErrorRecord] $ErrorObject
    )
    Process
    {
		If ($ErrorObject.InvocationInfo.MyCommand) {
			Write-LogError $("{0} : {1}" -f $ErrorObject.InvocationInfo.MyCommand.Name, $ErrorObject.Exception.Message)
		} else {
			Write-LogError $("{0}" -f $ErrorObject.Exception.Message)
		}
foreach($line in ($ErrorObject.InvocationInfo.PositionMessage -split "`r`n")) {
			Write-LogError $("{0}" -f $line)
		}
		Write-LogError $("    + CategoryInfo          : {0}" -f $ErrorObject.CategoryInfo.ToString())
        Write-LogError $("    + FullyQualifiedErrorId : {0}" -f $ErrorObject.FullyQualifiedErrorId)
    }
}

function Write-LogFatal
{
    param
    (
        [parameter(Mandatory=$True, ValueFromPipeLine=$True)]
        [string[]] $Messages
    )
    Process
    {
        if (!(Test-path variable:script:Initialized))
        {
            Initialize-Log
        }

        if($Script:LogFatal)
        {
            $Script:ErrorCount++
            Write-Host -Object "$(Get-Date -Format "HH:mm:ss:fff") FATAL  : " -NoNewline
            Write-Host -ForegroundColor Magenta -Object "$Messages"
            Write-Host -Object "$(Get-Date -Format "HH:mm:ss:fff") FATAL  : " -NoNewline
            Write-Host -ForegroundColor Magenta -Object "--  Exiting  --"
            $datumTijd = (Get-Date -Format $Script:LogDateFormat)
            "$datumTijd Fatal   : $Messages" | out-file -encoding ASCII "$Script:LogFileName" -append
            "$datumTijd Fatal   : --  Exiting  --`n" | out-file -encoding ASCII "$Script:LogFileName" -append
            if(!($Script:NoFileCheck))
            {    
                "$datumTijd Fatal   : $Messages" | out-file -encoding ASCII "$Script:ErrFileName" -append
                "$datumTijd Fatal   : --  Exiting  --`n" | out-file -encoding ASCII "$Script:ErrFileName" -append
            }
        }
    }
}


function Initialize-Log
{
    [cmdletbinding(DefaultParameterSetName='dagen')]
    param
    (
        [ValidateSet("DEBUG", "INFO", "WARNING", "ERROR", "FATAL")]
        [string] $Level="INFO",
        [bool] $NoFileCheck=$true,
        [parameter(Mandatory=$false)][ValidateSet("D:\FileCheck","D:\FC")]
        [string]$FileCheck="D:\FileCheck",
        [parameter(ParameterSetName='dagen')]
        [Int32]$MaxAgeDays = 40,
        [parameter(ParameterSetName='uren')]
        [Int32]$MaxAgeHours,
        [Int32]$MinFileCount = 0
    )

    if (($Level -eq "ALL") -or ($Level -eq "DEBUG"))
    {
        $Script:LogDebug=$Script:LogInfo=$Script:LogWarning=$Script:LogError=$Script:LogFatal=$True
    }

    if (($Level -eq "INFO") -or (!$Level))
    {
        $Script:LogInfo=$Script:LogWarning=$Script:LogError=$Script:LogFatal=$True
        $Script:LogDebug=$False
    }

    if ($Level -eq "WARNING")
    {
        $Script:LogWarning=$Script:LogError=$Script:LogFatal=$True
        $Script:LogDebug=$Script:LogInfo=$False
    }

    if ($Level -eq "ERROR")
    {
        $Script:LogError=$Script:LogFatal=$True
        $Script:LogDebug=$Script:LogInfo=$Script:LogWarning=$False
    }

    if ($Level -eq "FATAL")
    {
        $Script:LogFatal=$True
        $Script:LogDebug=$Script:LogInfo=$Script:LogWarning=$Script:LogError=$False
    }


    $ScriptName = Split-Path $MyInvocation.PSCommandPath -Leaf
    if (!$ScriptName) {
        $ScriptName = "PS-Script"
    } else {
        $ScriptName = $ScriptName.Replace(".ps1","")
    }

    $ScriptRoot = Split-Path $MyInvocation.PSCommandPath -Parent
    
    if ($ScriptRoot)
    {
        $script:logfolder = "$ScriptRoot\Log"
    }
    else
    {
        $ScriptRoot = "$ENV:Temp"
        Write-Host "Logging-directory is $ENV:Temp\Log."

        $script:logfolder = "$ENV:Temp\Log"
    }


    If (!(Test-path $script:logfolder))
    {
        try
        {
            $dummy = New-Item $script:logfolder -type directory -ErrorAction Stop
            Write-Host "Directory aangemaakt: $($script:logfolder)"
        }
        catch
        {
            Write-Host "Fout bij aanmaken directory $script:logfolder: $($_.Exception.Message)" 
        }
    }


	$Script:ScriptName=$ScriptName
    $Script:LogFileBaseName="$ScriptName.$($ENV:ComputerName).$($ENV:UserName)"
    $Script:LogFileName="$script:logfolder\$($Script:LogFileBaseName).$(Get-Date -Format "yyyy-MM-dd").log"
    $Script:LogDateFormat="[yyyy-MM-dd HH:mm:ss:fff]"
    $Script:ErrFileBaseName="$FileCheck\$($Script:LogFileBaseName)"
    $Script:ErrFileName="$Script:ErrFileBaseName.$(Get-Date -Format "yyyy-MM-dd").err.log"
    $Script:ErrorFiles="$Script:ErrFileBaseName.*.err.log"
    $Script:Initialized=$True
    $Script:FunctionIndent=0
    $Script:ErrorCount=0

    if ($NoFileCheck)
    {
        $Script:NoFileCheck = $True
    }
    else
    {
        $Script:NoFileCheck = $False
        if (!(Test-Path $FileCheck))
        {
            New-Item -path $FileCheck -ItemType Directory | Out-Null
        }
    }

    $script:ScriptRoot = $ScriptRoot
    $script:ScriptName = $ScriptName
    
    if ($PSCmdlet.ParameterSetName -eq 'dagen') {
        $script:MaxAgeDays = $MaxAgeDays
    }
    if ($PSCmdlet.ParameterSetName -eq 'uren') {
        $script:MaxAgeHours = $MaxAgeHours
    }
    $script:MinFileCount = $MinFileCount
    
	$CallStack = Get-PSCallStack
	If ($CallStack[-1].Position) {
		$Addition = "Opdrachtregel: '$($CallStack[-1].Position)', Werkdirectory: '$((Get-Location).Path)'"
	} else {
		$Addition = ""
	}
    Write-LogInfo("Start van script $($MyInvocation.PSCommandPath) door gebruiker $($ENV:username) op $($ENV:ComputerName). $($Addition)")
}

function Send-Log
{
    param
    (
        [string] $To,
        [string] $SmtpServer,
        [string] $From="$($env:COMPUTERNAME).$($ScriptName)@$(([System.Net.Dns]::GetHostByName(($env:COMPUTERNAME))).Hostname.Split('.',2)[-1])",
        [switch] $BodyAsLogfile=$false,
		[switch] $OnlyOnError=$false
    )

    if (!($To -match "\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,4}\b" ))
    {
        Write-LogError "Send-log aangeroepen zonder geldig emailadres."
        return
    }

    if (!($BodyAsLogfile))
    {
        $SendOptions = @{
            Body = $("Log van script $($ScriptName): $Script:LogFileName")
            Attachments = $Script:LogFileName
        }
    }
    else 
    {
        $SendOptions = @{
            Body = $(Get-Content -Path $Script:LogFileName | Out-String)
        }
    }
   
	If (!$OnlyOnError -or ($OnlyOnError -and $Script:ErrorCount -gt 0)) {
		try 
		{
			Write-LogInfo("Versturen logfile naar $To via $SmtpServer met afzender $From")
			Send-MailMessage -SmtpServer $SmtpServer -From $From -To $To -Subject "Log van script $ScriptName" -ErrorAction Stop @SendOptions
		}
		catch
		{
			Write-LogInfo "E-mailen vanuit script mislukt: $($_.Exception.Message)"
		}
	}
}

function Clean-LogFiles
{
<#
interne functie
#>
param(
    [parameter(Mandatory=$True)]
    [string]$Folder,
    [parameter(ParameterSetName='dagen')]
    [Int32]$MaxAgeDays,
    [parameter(ParameterSetName='uren')]
    [Int32]$MaxAgeHours,
    [Int32]$MinFileCount = 0
    )

    if ($MaxAgeDays) {
        Write-LogDebug ("Bestanden verwijderen die ouder zijn dan $MaxAgeDays $($PSCmdlet.ParameterSetName) in folder $Folder")
    } else {
        Write-LogDebug ("Bestanden verwijderen die ouder zijn dan $MaxAgeHours $($PSCmdlet.ParameterSetName) in folder $Folder")
    }

    $files = Get-ChildItem -Path $Folder -File -Filter "$($Script:ScriptName).*.log" | Sort-Object -Property LastWriteTime # oudste files vooraan in de lijst

    $aantalFiles = ($files | Measure-Object).Count
    
    if ($aantalFiles -eq 0)
    {
        Write-LogDebug "Geen bestanden gevonden in folder $Folder"
        return
    }
    
    #Write-LogDebug "Bestanden gevonden in folder $Folder" 

    foreach ($file in $files)
    {   
        if ($aantalFiles -le $MinFileCount)
        {
            break
        }
        $aantalFiles = $aantalFiles - 1

        $ts = New-Timespan -Start $file.LastWriteTime -End (Get-Date)

        $verwijderen = $false
        if ( ($PSCmdlet.ParameterSetName -eq "uren") -and ($ts.TotalHours -ge $MaxAgeHours) )
        {
            $verwijderen = $true
        }
        if ( ($PSCmdlet.ParameterSetName -eq "dagen") -and ($ts.TotalDays -ge $MaxAgeDays) )
        {
            $verwijderen = $true
        }

        if ($verwijderen)
        {
            try
            {
                Remove-Item $file.FullName -Force -ErrorAction Stop
                Write-LogInfo ("Oude logfile verwijderd: " + $file.FullName)
            }
            catch
            {
                Write-LogError ("Fout bij verwijderen oude logfile $($file.FullName): $($_.Exception.Message)")
            }
        }
        else
        {
            # files zijn gesorteerd op datum, dus zodra er een gevonden is die niet verwijderd
            # mag worden, dan moeten de volgende files in de lijst ook blijven staan.
            break 

        }

    } 
}

function Close-Log
{

    #Write-LogDebug "functie Afronden-Taak: errorcount = $Script:ErrorCount"

    if ($Script:ErrorCount -eq 0)
    {
        # dan zijn er deze run geen fouten geconstateerd: oude eigen errorfiles opruimen!
        #Schonen-TaskFiles $Script:ErrorFiles "uren" 0
    }

    if (Test-Path variable:script:MaxAgeDays) {
        Clean-LogFiles -Folder $script:logfolder -MaxAgeDays $script:MaxAgeDays -MinFileCount $script:MinFileCount
    } elseif (Test-Path variable:script:MaxAgeHours) {
        Clean-LogFiles -Folder $script:logfolder -MaxAgeHours $script:MaxAgeHours -MinFileCount $script:MinFileCount
    }
    

    Write-LogInfo("Einde van script $ScriptName door user $($ENV:username) op $($ENV:ComputerName)")
}

Export-ModuleMember -function `
Initialize-Log, `
Send-Log, `
Write-LogDebug, `
Write-LogInfo, `
Write-LogWarning, `
Write-LogError, `
Write-LogFatal, `
Write-LogException, `
Close-Log
