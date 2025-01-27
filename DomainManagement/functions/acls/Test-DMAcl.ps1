﻿function Test-DMAcl {
	<#
		.SYNOPSIS
			Tests whether the configured groups match a domain's configuration.
		
		.DESCRIPTION
			Tests whether the configured groups match a domain's configuration.
		
		.PARAMETER Server
			The server / domain to work with.
		
		.PARAMETER Credential
			The credentials to use for this operation.
		
		.EXAMPLE
			PS C:\> Test-DMGroup

			Tests whether the configured groups' state matches the current domain group setup.
	#>
	[CmdletBinding()]
	param (
		[PSFComputer]
		$Server,
		
		[PSCredential]
		$Credential
	)
	
	begin {
		$parameters = $PSBoundParameters | ConvertTo-PSFHashtable -Include Server, Credential
		$parameters['Debug'] = $false
		Assert-ADConnection @parameters -Cmdlet $PSCmdlet
		Invoke-Callback @parameters -Cmdlet $PSCmdlet
		Assert-Configuration -Type Acls, AclByCategory, AclDefaultOwner -Cmdlet $PSCmdlet
		Set-DMDomainContext @parameters

		#region Functions
		function New-Change {
			[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "")]
			[CmdletBinding()]
			param (
				$Type,
				$OldValue,
				$NewValue,
				[string]
				$Identity,
				$OldSID,
				$NewSID
			)

			$changeItem = [PSCustomObject]@{
				PSTypeName = 'DomainManagement.Acl.Change'
				Type       = $Type
				Old        = $OldValue
				New        = $NewValue
				Identity   = $Identity
				OldSID     = $OldSID
				NewSID     = $NewSID
			}
			Add-Member -InputObject $changeItem -MemberType ScriptMethod -Name ToString -Value { '{0}->{1}' -f $this.Type, $this.New } -Force -PassThru
		}
		function Get-ChangeByCategory {
			[CmdletBinding()]
			param (
				$ADObject,

				$Category,

				$ResultDefaults,

				$Parameters
			)

			$aclObject = Get-AdsAcl @Parameters -Path $ADObject -EnableException

			# Ensure Owner Name is present - may not always resolve
			$ownerSID = $aclObject.GetOwner([System.Security.Principal.SecurityIdentifier])
			$configuredSID = $Category.Owner | Resolve-String | Convert-Principal @parameters -OutputType SID

			[System.Collections.ArrayList]$changes = @()
			if ("$ownerSID" -ne "$configuredSID") {
				$null = $changes.Add((New-Change -Identity $ADObject -Type Owner -OldValue $aclObject.Owner -NewValue ($Category.Owner | Resolve-String) -OldSID $ownerSID -NewSID $configuredSID))
			}
			if ($Category.NoInheritance -ne $aclObject.AreAccessRulesProtected) {
				# If AdminCount -eq 1, then inheritance should be disabled, no matter the configuration
				if (-not ($aclObject.AreAccessRulesProtected -and $ADObject.AdminCount)) {
					$null = $changes.Add((New-Change -Identity $ADObject -Type NoInheritance -OldValue $aclObject.AreAccessRulesProtected -NewValue $Category.NoInheritance))
				}
			}

			if ($changes.Count) {
				New-TestResult @resultDefaults -Identity $ADObject -Configuration $Category -Type Update -Changed $changes.ToArray() -ADObject $aclObject
			}
		}
		#endregion Functions
	}
	process {
		#region processing configuration
		foreach ($aclDefinition in $script:acls.Values) {
			$resolvedPath = Resolve-String -Text $aclDefinition.Path

			$resultDefaults = @{
				Server        = $Server
				ObjectType    = 'Acl'
				Identity      = $resolvedPath
				Configuration = $aclDefinition
			}

			
			if (-not (Test-ADObject @parameters -Identity $resolvedPath)) {
				if ($aclDefinition.Optional) { continue }
				Write-PSFMessage -String 'Test-DMAcl.ADObjectNotFound' -StringValues $resolvedPath -Tag 'panic', 'failed' -Target $aclDefinition
				New-TestResult @resultDefaults -Type 'MissingADObject'
				Continue
			}

			try { $aclObject = Get-AdsAcl @parameters -Path $resolvedPath -EnableException }
			catch {
				if ($aclDefinition.Optional) { continue }
				Write-PSFMessage -String 'Test-DMAcl.NoAccess' -StringValues $resolvedPath -Tag 'panic', 'failed' -Target $aclDefinition -ErrorRecord $_
				New-TestResult @resultDefaults -Type 'NoAccess'
				Continue
			}
			# Ensure Owner Name is present - may not always resolve
			$ownerSID = $aclObject.GetOwner([System.Security.Principal.SecurityIdentifier])
			$configuredSID = $aclDefinition.Owner | Resolve-String | Convert-Principal @parameters -OutputType SID

			[System.Collections.ArrayList]$changes = @()
			if ("$ownerSID" -ne "$configuredSID") {
				$null = $changes.Add((New-Change -Identity $resolvedPath -Type Owner -OldValue $aclObject.Owner -NewValue ($aclDefinition.Owner | Resolve-String) -OldSID $ownerSID -NewSID $configuredSID))
			}
			if ($aclDefinition.NoInheritance -ne $aclObject.AreAccessRulesProtected) {
				$null = $changes.Add((New-Change -Identity $resolvedPath -Type NoInheritance -OldValue $aclObject.AreAccessRulesProtected -NewValue $aclDefinition.NoInheritance))
			}

			if ($changes.Count) {
				New-TestResult @resultDefaults -Type Update -Changed $changes.ToArray() -ADObject $aclObject
			}
		}
		#endregion processing configuration

		if ($script:contentMode.ExcludeComponents.ACLs) { return }

		#region check if all ADObjects are managed
		$foundADObjects = foreach ($searchBase in (Resolve-ContentSearchBase @parameters -NoContainer)) {
			Get-ADObject @parameters -LDAPFilter '(objectCategory=*)' -SearchBase $searchBase.SearchBase -SearchScope $searchBase.SearchScope -Properties AdminCount
		}
		
		$resolvedConfiguredPaths = $script:acls.Values.Path | Resolve-String
		$resultDefaults = @{
			Server     = $Server
			ObjectType = 'Acl'
		}

		$processed = @{ }
		foreach ($foundADObject in $foundADObjects) {
			# Prevent duplicate processing
			if ($processed[$foundADObject.DistinguishedName]) { continue }
			$processed[$foundADObject.DistinguishedName] = $true

			# Skip items that were defined in configuration, they were already processed
			if ($foundADObject.DistinguishedName -in $resolvedConfiguredPaths) { continue }
			
			if ($script:aclByCategory.Count -gt 0) {
				$category = Resolve-DMObjectCategory -ADObject $foundADObject @parameters
				if ($matchingCategory = $category | Where-Object Name -In $script:aclByCategory.Keys | Select-Object -First 1) {
					Get-ChangeByCategory -ADObject $foundADObject -Category $script:aclByCategory[$matchingCategory.Name] -ResultDefaults $resultDefaults -Parameters $parameters
					continue
				}
			}

			if ($script:aclDefaultOwner) { Get-ChangeByCategory -ADObject $foundADObject -Category $script:aclDefaultOwner[0] -ResultDefaults $resultDefaults -Parameters $parameters }
			else { New-TestResult @resultDefaults -Type ShouldManage -ADObject $foundADObject -Identity $foundADObject.DistinguishedName }
		}
		#endregion check if all ADObjects are managed
	}
}