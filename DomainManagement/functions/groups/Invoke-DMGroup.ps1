﻿function Invoke-DMGroup {
    <#
		.SYNOPSIS
			Updates the group configuration of a domain to conform to the configured state.
		
		.DESCRIPTION
			Updates the group configuration of a domain to conform to the configured state.
		
		.PARAMETER Server
			The server / domain to work with.
		
		.PARAMETER Credential
			The credentials to use for this operation.

		.PARAMETER EnableException
			This parameters disables user-friendly warnings and enables the throwing of exceptions.
			This is less user friendly, but allows catching exceptions in calling scripts.

		.PARAMETER Confirm
			If this switch is enabled, you will be prompted for confirmation before executing any operations that change state.
		
		.PARAMETER WhatIf
			If this switch is enabled, no actions are performed but informational messages will be displayed that explain what would happen if the command were to run.
		
		.EXAMPLE
			PS C:\> Innvoke-DMGroup -Server contoso.com

			Updates the groups in the domain contoso.com to conform to configuration
	#>
    [CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Low')]
    param (
        [PSFComputer]
        $Server,
		
        [PSCredential]
        $Credential,

        [switch]
        $EnableException
    )
	
    begin {
        $parameters = $PSBoundParameters | ConvertTo-PSFHashtable -Include Server, Credential
        $parameters['Debug'] = $false
        Assert-ADConnection @parameters -Cmdlet $PSCmdlet
        Invoke-Callback @parameters -Cmdlet $PSCmdlet
        Assert-Configuration -Type Groups -Cmdlet $PSCmdlet
        $testResult = Test-DMGroup @parameters
        Set-DMDomainContext @parameters
    }
    process {
        foreach ($testItem in $testResult) {
            switch ($testItem.Type) {
                'ShouldDelete' {
                    Invoke-PSFProtectedCommand -ActionString 'Invoke-DMGroup.Group.Delete' -Target $testItem -ScriptBlock {
                        Remove-ADGroup @parameters -Identity $testItem.ADObject.ObjectGUID -ErrorAction Stop -Confirm:$false
                    } -EnableException $EnableException.ToBool() -PSCmdlet $PSCmdlet -Continue
                }
                'ConfigurationOnly' {
                    $targetOU = Resolve-String -Text $testItem.Configuration.Path
                    try { $null = Get-ADObject @parameters -Identity $targetOU -ErrorAction Stop }
                    catch { Stop-PSFFunction -String 'Invoke-DMGroup.Group.Create.OUExistsNot' -StringValues $targetOU, $testItem.Identity -Target $testItem -EnableException $EnableException -Continue }
                    Invoke-PSFProtectedCommand -ActionString 'Invoke-DMGroup.Group.Create' -Target $testItem -ScriptBlock {
                        $newParameters = $parameters.Clone()
                        $newParameters += @{
                            Name          = (Resolve-String -Text $testItem.Configuration.Name)
                            Description   = (Resolve-String -Text $testItem.Configuration.Description)
                            Path          = $targetOU
                            GroupCategory = $testItem.Configuration.Category
                            GroupScope    = $testItem.Configuration.Scope
                        }
                        New-ADGroup @newParameters
                    } -EnableException $EnableException.ToBool() -PSCmdlet $PSCmdlet -Continue
                }
                'MultipleOldGroups' {
                    Stop-PSFFunction -String 'Invoke-DMGroup.Group.MultipleOldGroups' -StringValues $testItem.Identity, ($testItem.ADObject.Name -join ', ') -Target $testItem -EnableException $EnableException -Continue -Tag 'group', 'critical', 'panic'
                }
                'Rename' {
                    Invoke-PSFProtectedCommand -ActionString 'Invoke-DMGroup.Group.Rename' -ActionStringValues (Resolve-String -Text $testItem.Configuration.Name) -Target $testItem -ScriptBlock {
                        Rename-ADObject @parameters -Identity $testItem.ADObject.ObjectGUID -NewName (Resolve-String -Text $testItem.Configuration.Name) -ErrorAction Stop
                    } -EnableException $EnableException.ToBool() -PSCmdlet $PSCmdlet -Continue
                }
                'Changed' {
                    if ($testItem.Changed -contains 'Path') {
                        $targetOU = Resolve-String -Text $testItem.Configuration.Path
                        try { $null = Get-ADObject @parameters -Identity $targetOU -ErrorAction Stop }
                        catch { Stop-PSFFunction -String 'Invoke-DMGroup.Group.Update.OUExistsNot' -StringValues $testItem.Identity, $targetOU -Target $testItem -EnableException $EnableException -Continue }

                        Invoke-PSFProtectedCommand -ActionString 'Invoke-DMGroup.Group.Move' -ActionStringValues $targetOU -Target $testItem -ScriptBlock {
                            $null = Move-ADObject @parameters -Identity $testItem.ADObject.ObjectGUID -TargetPath $targetOU -ErrorAction Stop
                        } -EnableException $EnableException.ToBool() -PSCmdlet $PSCmdlet -Continue
                    }
                    $changes = @{ }
                    if ($testItem.Changed -contains 'Description') { $changes['Description'] = (Resolve-String -Text $testItem.Configuration.Description) }
                    if ($testItem.Changed -contains 'Category') { $changes['GroupCategory'] = (Resolve-String -Text $testItem.Configuration.Category) }
					
                    if ($changes.Keys.Count -gt 0) {
                        Invoke-PSFProtectedCommand -ActionString 'Invoke-DMGroup.Group.Update' -ActionStringValues ($changes.Keys -join ", ") -Target $testItem -ScriptBlock {
                            $null = Set-ADObject @parameters -Identity $testItem.ADObject.ObjectGUID -ErrorAction Stop -Replace $changes
                        } -EnableException $EnableException.ToBool() -PSCmdlet $PSCmdlet -Continue
                    }
                    if ($testItem.Changed -contains 'Scope') {
						$targetScope = Resolve-String -Text $testItem.Configuration.Scope
						if ($targetScope -notin ([Enum]::GetNames([Microsoft.ActiveDirectory.Management.ADGroupScope]))) {
							Stop-PSFFunction -String 'Invoke-DMGroup.Group.InvalidScope' -StringValues $testItem, $targetScope -Continue -EnableException $EnableException -Target $testItem
						}

						Invoke-PSFProtectedCommand -ActionString 'Invoke-DMGroup.Group.Update.Scope' -ActionStringValues $testItem, $testItem.ADObject.GroupScope, $targetScope -Target $testItem -ScriptBlock {
							$null = Set-ADGroup @parameters -Identity $testItem.ADObject.ObjectGUID -GroupScope Universal -ErrorAction Stop
							$null = Set-ADGroup @parameters -Identity $testItem.ADObject.ObjectGUID -GroupScope $targetScope -ErrorAction Stop
                        } -EnableException $EnableException.ToBool() -PSCmdlet $PSCmdlet -Continue
                    }
                }
            }
        }
    }
}
