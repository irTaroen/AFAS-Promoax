#requires -version 2
<#
.SYNOPSIS
  Deze functies importeren een XML scriptconfiguratie en gebruikt versleutelde wachtwoorden
.DESCRIPTION
  Zodra de XML file wordt ingelezen met Import-XMLConfig wordt er gezocht naar <secured_credential> tags. Deze tags moeten <username> en <cleartextpassword> bevatten.
  Het cleartext password wordt omgezet in een secure string en de XML file wordt opgeslagen. Daarna wordt het XML object teruggegeven.
  Belangrijk is dat het Import-XMLConfig commando het volledige pad nodig naar de XML, om deze te kunnen opslaan.
.NOTES
  Version:        1.0
  Author:         Robert Glintmeijer
  Creation Date:  04-07-2016
  Purpose/Change: Klaar gezet voor TFS, noodzaak voor absolute pad naar XML eruit gehaald door absolute pad te bepaken met Get-Item
  
.RELEASES
    v1.0 [04-07-2016]   : Initiele versie. En eventuele verdere uitleg.
	V1.1 [06-09-2019]   : Optie toegevoegd om het wachtwoord te vragen aan de gebruiker
  
.EXAMPLE

 Voorbeeld XML configuratie config.xml:

	<configuration>
		<!-- Meer XML -->
		<account>
			<!-- Meer XML -->
			<secured_credential>
				<description>Beschrijving van het wachtwoord</description>
				<username>rglintmeijer@d0.ib.lan</username>
				<cleartextpassword>HierHetWachtwoord</cleartextpassword>
			</secured_credential>
			<!-- Meer XML -->
		</account>
		<!-- Meer XML -->
	</configuration>

	
 Gebuik:
	# Include deze functies
	. ".\Functions-XMLConfig.ps1"
	
	$config = Import-XMLConfig -XMLConfigfilePath ".\config.xml"
	
	$config = $config.configuration
	
	# Voorbeeld om het credential te gebruiken:
	$cred = Get-PSCredential $config.account.secured_credential
	Invoke-Command -Computer <servernaam> -Credential $cred -ScriptBlock {Write-Output $env:computername}
	
#>


Function Import-XMLConfig {
	param (
		[ValidateScript({ Test-Path $_ -PathType Leaf })]
		[string]$XMLConfigfilePath = "..\config.xml"
	)
	
    $XMLConfig = [xml](Get-Content $XMLConfigfilePath)

    $currentuser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

    $modifiedXML = $false

    # Haal alle secured_credential objecten op
    $secured_credentials = $XMLConfig.SelectNodes("//secured_credential")
	foreach ($secured_credential in $secured_credentials) {
		If ($secured_credential.cleartextpassword.getType() -eq [System.String]) {
        	$cleartextpassword = $secured_credential.cleartextpassword
		} else {
			$cleartextpassword = $secured_credential.cleartextpassword.InnerText
		}
            
		# Haal <password encrypted_by="username" encrypted_on="computername"/> op.
		$password_for_currentuser = $secured_credential.SelectSingleNode("password[@encrypted_by='$currentuser' and @encrypted_on='$env:computername']")

        if ($cleartextpassword) {
			# Als er een clear text password is, encrypt deze en verwijder het clear text password

            # Als deze niet bestaat, maak deze dan aan
            if (!$password_for_currentuser) {
                $password_for_currentuser = $secured_credential.appendChild($XMLConfig.CreateElement("password"))
                $password_for_currentuser.SetAttribute("encrypted_by",$currentuser)
				$password_for_currentuser.SetAttribute("encrypted_on",$env:computername)
            }

            $password_for_currentuser.InnerText = (ConvertTo-SecureString -String $cleartextpassword -AsPlainText -Force | ConvertFrom-SecureString).ToString()
            $secured_credential.SelectSingleNode("cleartextpassword").InnerText = " "
            $modifiedXML = $true
        } else {
			# Als er geen clear text password is, vraag dan het wachtwoord aan de gebruiker
            if (!$password_for_currentuser) {
				$enterCredential = Get-Credential -Username $secured_credential.username -Message "Geef het wachtwoord op voor $($secured_credential.username).`r`n$($secured_credential.description)"
				If ($enterCredential -and $enterCredential.GetNetworkCredential().Password) {
					$password_for_currentuser = $secured_credential.appendChild($XMLConfig.CreateElement("password"))
					$password_for_currentuser.SetAttribute("encrypted_by",$currentuser)
					$password_for_currentuser.SetAttribute("encrypted_on",$env:computername)
					$password_for_currentuser.InnerText = (ConvertTo-SecureString -String $enterCredential.GetNetworkCredential().Password -AsPlainText -Force | ConvertFrom-SecureString).ToString()
					$secured_credential.SelectSingleNode("username").InnerText = $enterCredential.GetNetworkCredential().Username
					$secured_credential.SelectSingleNode("cleartextpassword").InnerText = " "
					$modifiedXML = $true
				} else {
					throw ("Error: Er is geen wachtwoord beschikbaar in {0} voor {1}. Vul het wachtwoord in tussen <cleartextpassword>HierHetWachtwoord</cleartextpassword> voor het account {2}" -f $XMLConfigfilePath, $currentuser, $secured_credential.username)
				}
            }
        }
    }


    if ($modifiedXML) {
		# Het absolute pad is nodig voor deze Save
		$XMLConfigfileFullPath = (Get-Item $XMLConfigfilePath).FullName
        Write-Verbose "Writing secured password to $XMLConfigfileFullPath"
        $XMLConfig.Save($XMLConfigfileFullPath)
    }

    return [xml]$XMLConfig
}

Function Get-PSCredential {
    param (
		[System.Xml.XmlElement]$SecuredCredential
	)

	# Voorbeelden:
	#$config = Import-XMLConfig <pad naar config.xml>
	#(Get-PSCredential -SecuredCredential $config.pad.naar.secured_credential)
	#(Get-PSCredential -SecuredCredential $config.pad.naar.secured_credential).GetNetworkCredential().Username
	#(Get-PSCredential -SecuredCredential $config.pad.naar.secured_credential).GetNetworkCredential().Password


	# Onder de currentuser wordt de encryptie gedaan
    $currentuser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name

    $Username = $SecuredCredential.username
    $SecurePassword = ConvertTo-SecureString $SecuredCredential.SelectSingleNode("password[@encrypted_by='$currentuser' and @encrypted_on='$env:computername']").InnerText

	$PSCredential = New-Object System.Management.Automation.PSCredential -ArgumentList $UserName, $SecurePassword
	return $PSCredential
}

Export-ModuleMember -function `
Import-XMLConfig, `
Get-PSCredential
