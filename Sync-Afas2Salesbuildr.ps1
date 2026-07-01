<#
.SYNOPSIS
    Dit script synchroniseert Afas Profit Organisaties en Contactpersonen naar SalesBuildr

.DESCRIPTION
    Dit script synchroniseert Afas Profit Organisaties en Contactpersonen naar SalesBuildr
    
.NOTES
    File Name        : Sync-Afas2Salesbuildr.ps1
    Author           : R. Glintmeijer
    Prerequisite     : PowerShell
    Reviewer         : 
    Date Review      : 


    RELEASES
        v1.0 [2025-06-18]   : Eerste versie met delta sync

#>


[CmdletBinding()]param()

# https://verkoop.promax.nl/public-api/swagger/

$ErrorActionPreference = 'Stop'

########### Init Logging Module ##############
if(!$PSScriptRoot) {
    $PSScriptRoot = Split-Path $MyInvocation.MyCommand.Path -Parent
}

########### Init Logging Module ##############
Import-Module "$PsScriptRoot\Modules\Logging.psm1"
Initialize-Log -Level 'INFO'
########### Init Logging Module ##############
########### Init Configuration Module ##############
Import-Module "$PsScriptRoot\Modules\Configuration.psm1"
########### Init Configuration Module ##############

Function Connect-Afas {
	param (
		[string]$Omgeving,
		[string]$AfasAPIToken
	)

	$Global:AfasOmgeving = $Omgeving
	$Global:AfasRestUrl = "https://$($Omgeving).rest.afas.online/profitrestservices"

	$encodedToken = [System.Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes($AfasAPIToken))
	$authValue = "AfasToken $encodedToken"

	$Global:AfasHeaders = @{
		Authorization = $authValue
	}
}

Function Invoke-AfasGetConnector
{
	param (	
		[string]$Connector
	)

	$result = @()
	$skip = 0
	$take = 100
	do {
		$url = "$($Global:AfasRestUrl)/connectors/$($Connector)?skip=$skip&take=$take"
		$response = Invoke-RestMethod -Uri $url -Headers $Global:AfasHeaders -Method Get
		
		# Output or process data
		$result += $response.rows

		# Move to the next page
		$skip += $take
	} while ($response.rows.Count -eq $take)

	return $result
}

Function Connect-Salesbuildr {
	param (
		[string]$Uri,
		[string]$ApiKey
	)

	$Global:SalesbuildrUri = $Uri
	$Global:SalesbuildrHeaders = @{
		"api-key" = $ApiKey
	}
}

Function Get-SalesbuildrCustomer {

# id                : RvVnmmk8BGNJjIUibuvQ
# name              : Test
# type              : customer
# parentCompanyId   : 
# accountManagerId  : 0Zljxre4GIdG8t6F5l88
# deliveryAddresses : {}
# labels            : 

	$result = Invoke-RestMethod -Uri "$($Global:SalesbuildrUri)/public-api/company?filters=type%3Acustomer" -Headers $Global:SalesbuildrHeaders -Method Get
	return $result.results
}

Function Get-SalesbuildrMSPContacts {

# id                 : gNB3TEfCuG1mXoHZLPTS
# firstName          : Leon
# middleName         :
# lastName           : Rodenburg
# email              : leon.rodenburg@promax.nl
# phone              :
# companyId          : jxPb8nrJh3cNJSrq7cT3
# companyName        : Promax
# externalIdentifier :

	$result = Invoke-RestMethod -Uri "$($Global:SalesbuildrUri)/public-api/contact?filters=companyType%3Amsp" -Headers $Global:SalesbuildrHeaders -Method Get

	return $result.results
}

try {
	# Clear Error variable
	$Error.Clear()

	$config = Import-XMLConfig -XMLConfigfilePath "$PsScriptRoot\config.xml"
	$config = $config.configuration

	If (-Not (Test-Path -Path "$PSScriptRoot\work")) {
		New-Item -ItemType Directory -Path "$PSScriptRoot\work" | Out-Null
	}
	$StateFile = "$PSScriptRoot\work\LastSyncDate.xml"

	$LastSyncDate = Get-Date -Date "1-1-1970"
	If (Test-Path -Path $StateFile) {
		$LastSyncDate = Import-Clixml -Path $StateFile
	}


	Write-LogInfo "Synchroniseer wijzigingen vanuit Afas Profit sinds $($LastSyncDate)"
	#$VerbosePreference = 'Continue'
	
	$AfasAPIToken = (Get-PSCredential -SecuredCredential $config.afas.api.secured_credential).GetNetworkCredential().Password
	$SalesbuilrAPIkey = (Get-PSCredential -SecuredCredential $config.salesbuildr.api.secured_credential).GetNetworkCredential().Password

	Connect-Afas -Omgeving $config.afas.omgeving -AfasAPIToken $AfasAPIToken
	Connect-Salesbuildr -Uri $config.salesbuildr.api.url -ApiKey $SalesbuilrAPIkey

	# Ophalen accountmanagers met hun Id in SalesBuildr
	$AccountManagers = Get-SalesbuildrMSPContacts

	#################################################################
	#### Organisaties
	#################################################################

	Write-LogInfo "Ophalen Organisaties uit Afas Profit"

	# Ophalen Organisaties uit Afas
	$AfasOrganisaties = Invoke-AfasGetConnector -Connector "Salesbuildr_Organisaties" 

	# Filter alleen recent gewijzigde
	$AfasOrganisaties = $AfasOrganisaties | Where-Object Gewijzigd_op -gt $LastSyncDate

	foreach ($AfasOrganisatie in $AfasOrganisaties) {

		$ExternalIdentifier = "afas-Organisatie-$($AfasOrganisatie.Nummer)"

		# Map the country if found
		$SalesbuildrCountry = $null
		$CountryMapping = @($config.salesbuildr.countrymapping.country) | Where-Object afas -eq $AfasOrganisatie.Land
		If (!$CountryMapping) {
			$SalesbuildrCountry = $AfasOrganisatie.Land
		} else {
			$SalesbuildrCountry = $CountryMapping.salesbuildr
		}

		$AccountManager = $AccountManagers | Where-Object {(@($_.firstName,$_.middleName,$_.lastName) -join ' ' -replace '\s+',' ') -like $AfasOrganisatie.Accountmanager }
		If (!$AccountManager) {
			Write-LogWarning "[$($AfasOrganisatie.Naam)]: Geen accountmanager gevonden in SalesBuildr met naam '$($AfasOrganisatie.Accountmanager)'"
			$AccountManager = "" | Select-Object Id
			$AccountManager.Id = "gNB3TEfCuG1mXoHZLPTS"
		}

		$SalesbuildrCustomer = @{
			name             = $AfasOrganisatie.Naam
			number           = $AfasOrganisatie.Nummer
			type             = "customer"
			telephone        = $AfasOrganisatie.Telnr_werk
			accountManagerId = $AccountManager.Id
			address = @{
				street       = "$($AfasOrganisatie.Straat) $($AfasOrganisatie.Huisnummer)"
				city         = $AfasOrganisatie.Woonplaats
				zip          = $AfasOrganisatie.Postcode
				country      = $SalesbuildrCountry
				companyName  = $AfasOrganisatie.Naam
			}
			externalIdentifier = $ExternalIdentifier
		}

		$Body = $SalesbuildrCustomer | ConvertTo-Json
		Write-LogInfo "Organisatie bijwerken in SalesBuildr: $($AfasOrganisatie.Naam)"
		try {
			$Result = Invoke-WebRequest -Uri "$($Global:SalesbuildrUri)/public-api/company/ext/$($ExternalIdentifier)" -Headers $Global:SalesbuildrHeaders -Method Put -Body $Body -ContentType "application/json"
		} catch {
			Write-LogError $_.ErrorDetails.Message
		}
	}

	#################################################################
	#### Contacten
	#################################################################
	
	Write-LogInfo "Ophalen Contacten uit Afas Profit"

	# Ophalen Contacten uit Afas
	$AfasContacten = Invoke-AfasGetConnector -Connector "Salesbuildr_Contacten"

	# Filter alleen recent gewijzigde
	$AfasContacten = $AfasContacten | Where-Object Gewijzigd_op -gt $LastSyncDate



	foreach ($AfasContact in $AfasContacten) {

		$ExternalIdentifier = "afas-Persoon-$($AfasContact.Nummer)"

		# Split de voornaam en achternaam uit het veld Voornaam_voorvoegsel_achternaam
		$Voornaam,$Achternaam  = $AfasContact.Voornaam_voorvoegsel_achternaam -split ' ',2

		If ($null -eq $AfasContact."E-mail_werk") {
			Write-LogError "Contact in Afas heeft geen e-mail adres: $($AfasContact.Naam)"
			continue
		}

		$SalesbuildrContact = @{
			firstName            = $Voornaam
			middleName           = ""
			lastName             = $Achternaam
			phone                = $AfasContact."Telefoonnr._werk"
			email                = $AfasContact."E-mail_werk"
			companyExtId         = "afas-Organisatie-$($AfasContact.Organisatie)"
			isActive             = $true
		}

		$Body = $SalesbuildrContact | ConvertTo-Json
		Write-LogInfo "Contact bijwerken in SalesBuildr: $($AfasContact.Naam)"

		try {
			$Result = Invoke-WebRequest -Uri "$($Global:SalesbuildrUri)/public-api/contact/ext/$($ExternalIdentifier)" -Headers $Global:SalesbuildrHeaders -Method Put -Body $Body -ContentType "application/json"
		} catch {
			Write-LogError $_.ErrorDetails.Message
		}
	}



	# Voorbeeld:
		# Nummer              : 1000301
		# Omschrijving        : Organisatie
		# Naam                : Bergschenhoek Groep B.V.
		# Geblokkeerd         : False
		# Type_verkooprelatie : Actief Promax
		# Telnr_werk          : 010-5242600
		# E-mail_werk         : 
		# Straat              : Boterdorpseweg
		# Huisnummer          : 10
		# Toevoeging          : 
		# Postcode            : 2661 AC
		# Woonplaats          : Bergschenhoek
		# Land                : NL
		# Accountmanager      : Mandy van Aerde
		# Gewijzigd_op        : 16-5-2025 11:08:34
		# Aangemaakt_op       : 16-10-2013 18:26:34

	
	#Send-Log, `
	#Write-LogDebug, `
	#Write-LogInfo, `
	#Write-LogWarning, `
	#Write-LogError, `
	#Write-LogFatal, `
	#Write-LogException, `
	#Close-Log

	
	If (!$Error) {
		# Als er geen foutmeldingen waren, sla dan de huidige datum en tijd op als laatste sync
		Get-Date | Export-Clixml -Path $StateFile -Force
	} else {
		Write-LogError "$($StateFile) niet bijgewerkt omdat er een fout is opgetreden."
	}
} catch {
    Write-LogException $_
}



Send-Log -To $config.global.NotifyEmail -SmtpServer $config.global.NotifySmtpServer -BodyAsLogfile -OnlyOnError
Close-Log
