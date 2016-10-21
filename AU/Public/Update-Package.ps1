# Author: Miodrag Milic <miodrag.milic@gmail.com>
# Last Change: 21-Oct-2016.

<#
.SYNOPSIS
    Update automatic package

.DESCRIPTION
    This function is used to perform necessary updates to the specified files in the package.
    It shouldn't be used on its own but must be part of the script which defines two functions:

    - au_SearchReplace
      The function should return HashTable where keys are file paths and value is another HashTable
      where keys and values are standard search and replace strings
    - au_GetLatest
      Returns the HashTable where the script specifies information about new Version, new URLs and
      any other data. You can refer to this variable as the $Latest in the script.
      While Version is used to determine if updates to the package are needed, other arguments can
      be used in search and replace patterns or for whatever purpose.

    With those 2 functions defined, calling Update-Package will:

    - Call your au_GetLatest function to get the remote version and other information.
    - If remote version is higher then the nuspec version, function will:
        - Check the returned URLs, Versions and Checksums (if defined) for validity (unless NoCheckXXX variables are specified)
        - Download files and calculate checksum(s), (unless already defined or ChecksumFor is set to 'none')
        - Update the nuspec with the latest version
        - Do the necessary file replacements
        - Pack the files into the nuget package

    You can also define au_BeforeUpdate and au_AfterUpdate functions to integrate your code into the update pipeline.
.EXAMPLE
    PS> notepad update.ps1
    # The following script is used to update the package from the github releases page.
    # After it defines the 2 functions, it calls the Update-Package.
    # Checksums are automatically calculated for 32 bit version (the only one in this case)
    import-module au

    function global:au_SearchReplace {
        ".\tools\chocolateyInstall.ps1" = @{
            "(^[$]url32\s*=\s*)('.*')"          = "`$1'$($Latest.URL32)'"
            "(^[$]checksum32\s*=\s*)('.*')"     = "`$1'$($Latest.Checksum32)'"
            "(^[$]checksumType32\s*=\s*)('.*')" = "`$1'$($Latest.ChecksumType32)'"
        }
    }

    function global:au_GetLatest {
        $download_page = Invoke-WebRequest -Uri https://github.com/hluk/CopyQ/releases

        $re  = "copyq-.*-setup.exe"
        $url = $download_page.links | ? href -match $re | select -First 1 -expand href
        $version = $url -split '-|.exe' | select -Last 1 -Skip 2

        return @{ URL32 = $url; Version = $version }
    }

    Update-Package -ChecksumFor 32

.NOTES
    All function parameters accept defaults via global variables with prefix `au_` (example: $global:au_Force = $true).

.OUTPUTS
    PSCustomObject with type AUPackage.

.LINK
    Update-AUPackages
#>
function Update-Package {
    [CmdletBinding()]
    param(
        #Do not check URL and version for validity.
        [switch] $NoCheckUrl,

        #Do not check if latest returned version already exists in the Chocolatey community feed.
        #Ignored when Force is specified.
        [switch] $NoCheckChocoVersion,

        #Specify for which architectures to calculate checksum - all, 32 bit, 64 bit or none.
        [ValidateSet('all', '32', '64', 'none')]
        [string] $ChecksumFor='all',

        #Timeout for all web operations, by default 100 seconds.
        [int]    $Timeout,

        #Force package update even if no new version is found.
        [switch] $Force,

        #Do not show any Write-Host output.
        [switch] $NoHostOutput,

        #Output variable.
        [string] $Result
    )

    function get_checksum()
    {
        function invoke_installer() {
            if (!(Test-Path tools\chocolateyInstall.ps1)) { "  aborted, chocolateyInstall not found for this package" | result; return }

            Import-Module "$choco_tmp_path\helpers\chocolateyInstaller.psm1" -Force

            if ($ChecksumFor -eq 'none') { "Automatic checksum calculation is disabled"; return }
            if ($ChecksumFor -eq 'all')  { $arch = '32','64' } else { $arch = $ChecksumFor }

            $pkg_path = [System.IO.Path]::GetFullPath("$Env:TEMP\chocolatey\$($package.Name)\" + $global:Latest.Version) #https://github.com/majkinetor/au/issues/32

            $Env:ChocolateyPackageName         = "chocolatey\$($package.Name)"
            $Env:ChocolateyPackageVersion      = $global:Latest.Version
            $Env:ChocolateyAllowEmptyChecksums = 'true'
            foreach ($a in $arch) {
                $Env:chocolateyForceX86 = if ($a -eq '32') { 'true' } else { '' }
                try {
                    rm -force -recurse -ea ignore $pkg_path
                    .\tools\chocolateyInstall.ps1 | result
                } catch {
                    if ( "$_" -notlike 'au_break: *') { throw $_ } else {
                        $filePath = "$_" -replace 'au_break: '
                        if (!(Test-Path $filePath)) { throw "Can't find file path to checksum" }

                        $item = gi $filePath
                        $type = if ($global:Latest.ContainsKey('ChecksumType' + $a)) { $global:Latest.Item('ChecksumType' + $a) } else { 'sha256' }
                        $hash = (Get-FileHash $item -Algorithm $type | % Hash).ToLowerInvariant()

                        if (!$global:Latest.ContainsKey('ChecksumType' + $a)) { $global:Latest.Add('ChecksumType' + $a, $type) }
                        if (!$global:Latest.ContainsKey('Checksum' + $a)) {
                            $global:Latest.Add('Checksum' + $a, $hash)
                            "Package downloaded and hash calculated for $a bit version" | result
                        } else {
                            $expected = $global:Latest.Item('Checksum' + $a)
                            if ($hash -ne $expected) { throw "Hash for $a bit version mismatch: actual = '$hash', expected = '$expected'" }
                            "Package downloaded and hash checked for $a bit version" | result
                        }
                    }
                }
            }
        }

        function fix_choco {
            Sleep -Milliseconds (Get-Random 500) #reduce probability multiple updateall threads entering here at the same time (#29)

            # Copy choco modules once a day
            if (Test-Path $choco_tmp_path) {
                $ct = gi $choco_tmp_path | % creationtime
                if (((get-date) - $ct).Days -gt 1) { rm -recurse -force $choco_tmp_path } else { Write-Verbose 'Chocolatey copy is recent, aborting monkey patching'; return }
            }

            Write-Verbose "Monkey patching chocolatey in: '$choco_tmp_path'"
            cp -recurse -force $Env:ChocolateyInstall\helpers $choco_tmp_path\helpers
            if (Test-Path $Env:ChocolateyInstall\extensions) { cp -recurse -force $Env:ChocolateyInstall\extensions $choco_tmp_path\extensions }

            $fun_path = "$choco_tmp_path\helpers\functions\Get-ChocolateyWebFile.ps1"
            (gc $fun_path) -replace '^\s+return \$fileFullPath\s*$', '  throw "au_break: $fileFullPath"' | sc $fun_path -ea ignore
        }

        "Automatic checksum started" | result

        # Copy choco powershell functions to TEMP dir and monkey patch the Get-ChocolateyWebFile function
        $choco_tmp_path = "$Env:TEMP\chocolatey\au\chocolatey"
        fix_choco

        # This will set the new URLs before the files are downloaded but will replace checksums to empty ones so download will not fail
        #  because checksums are at that moment set for the previous version.
        # SkipNuspecFile is passed so that if things fail here, nuspec file isn't updated; otherwise, on next run
        #  AU will think that package is the most recent. 
        #
        # TODO: This will also leaves other then nuspec files updated which is undesired side effect (should be very rare)
        #
        $global:Silent = $true
        update_files -SkipNuspecFile | out-null
        $global:Silent = $false

        # Invoke installer for each architecture to download files
        invoke_installer
    }


    function result() {
        if ($global:Silent) { return }

        $input | % {
            $package.Result += $_
            if (!$NoHostOutput) { Write-Host $_ }
        }
    }

    if ($PSCmdlet.MyInvocation.ScriptName -eq '') {
        Write-Verbose 'Running outside of the script'
        if (!(Test-Path update.ps1)) { return "Current directory doesn't contain ./update.ps1 script" } else { return ./update.ps1 }
    } else { Write-Verbose 'Running inside the script' }

    # Assign parameters from global variables with the prefix `au_` if they are bound
    (gcm $PSCmdlet.MyInvocation.InvocationName).Parameters.Keys | % {
        if ($PSBoundParameters.Keys -contains $_) { return }
        $value = gv "au_$_" -Scope Global -ea Ignore | % Value
        if ($value -ne $null) {
            sv $_ $value
            Write-Verbose "Parameter $_ set from global variable au_${_}: $value"
        }
    }

    $package = [AUPackage]:new( $pwd )
    if ($Result) { sv -Scope Global -Name $Result -Value $package }

    $module = $MyInvocation.MyCommand.ScriptBlock.Module

    "{0} - checking updates using {1} version {2}" -f $package.Name, $module.Name, $module.Version | result

    try {
        $global:Latest = [AUPackage]::InitLatest()
        $res = au_GetLatest | select -Last 1
        if ($res -eq $null) { throw 'au_GetLatest returned nothing' }

        $res_type = $res.GetType()
        if ($res_type -ne [HashTable]) { throw "au_GetLatest doesn't return a HashTable result but $res_type" }

        $res.Keys | % { $global:Latest.Remove($_) }
        $global:Latest += $res
    } catch {
        throw "au_GetLatest failed`n$_"
    }

    [AUPackage]::SetRemoteVersion( $Latest.Version )
    $package.Name = $Latest.PackageName

    if (!$NoCheckUrl) {
        "URL check" | result
        $ulrs = $Latest.Keys | ? {$_ -like 'url*' }
        foreach ($url in $urls) { Test-URl $url $Timeout; "  $url" | result }
    }

    "nuspec version: " + $package.NuspecVersion | result
    "remote version: " + $package.RemoteVersion | result

    $package.Forced = $Force -and !$package.IsUpdated()
    if ( $package.IsUpdated() ) {
        if (!($NoCheckChocoVersion -or $Force)) {
            $choco_url = "https://chocolatey.org/packages/{0}/{1}" -f $package.Name, $package.RemoteVersion
            try {
                request $choco_url $Timeout | out-null
                "New version is available but it already exists in the Chocolatey community feed (disable using `$NoCheckChocoVersion`):`n  $choco_url" | result
                return $package
            } catch { }
        }
    } else {
        if (!$Force) {
            'No new version found' | result
            return $package
        }
        else {
            $package.SetRemoteVersionChocoFix()
            $Latest.Version = $package.RemoteVersion
            'No new version found, but update is forced' | result
        }
    }

    'New version is available' | result

    if ($ChecksumFor -ne 'none') { get_checksum } else { 'Automatic checksum skipped' | result }

    if (Test-Path Function:\au_BeforeUpdate) { & {'Running au_BeforeUpdate'; au_BeforeUpdate } | result }
    $package.UpdateFiles | result
    if (Test-Path Function:\au_AfterUpdate) { & { 'Running au_AfterUpdate'; au_AfterUpdate } | result }

    choco pack --limit-output | result
    'Package updated' | result
    $package.Updated = $true

    return $package
}

Set-Alias update Update-Package
