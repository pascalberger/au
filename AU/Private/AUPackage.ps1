class AUPackage {
    [string]   $Path
    [string]   $Name
    [bool]     $Updated
    [bool]     $Pushed
    [bool]     $Forced
    [string]   $RemoteVersion
    [string]   $NuspecVersion
    [string]   $ChocoVersion
    [string[]] $Result
    [string]   $Error
    [string]   $NuspecPath
    [xml]      $NuspecXml

    AUPackage([string] $Path ){
        if ([String]::IsNullOrWhiteSpace( $Path )) { throw 'Path can not be empty' }

        $this.Path = $Path
        $this.Name = Split-Path -Leaf $Path

        $nuspec_path = '{0}\{1}.nuspec' -f $this.Path, $this.Name
        $nuspec_file = gi $nuspec_path -ea ignore
        if (!$nuspec_file) { throw 'No nuspec file found in the package directory' }

        $this.NuspecXml     = [AUPackage]::LoadNuspecFile( $nuspec_file )
        $this.NuspecVersion = $this.NuspecXml.package.metadata.version
    }

    [bool] ShouldUpdate() {
        $remote_l = $this.RemoteVersion -replace '-.+'
        $nuspec_l = $this.NuspecVersion -replace '-.+'
        $remote_r = $this.RemoteVersion -replace '.+(?=(-.+)*)'
        $nuspec_r = $this.NuspecVersion -replace '.+(?=(-.+)*)'

        if ([version]$remote_l -eq [version]$nuspec_l) {
            if (!$remote_r -and $nuspec_r) { return $true }
            if ($remote_r -and !$nuspec_r) { return $false }
            return ($remote_r -gt $nuspec_r)
        }
        return ([version]$remote_l -gt [version]$nuspec_l)
    }

    [string[]] Update( [HashTable]$SearchReplace )
    {

        #Update nuspec id and version
        $msg += Split-Path $this.NuspecPath -Leaf

        $msg += "    setting id:  " + $this.PackageName
        $this.NuspecXml.package.metadata.id = $this.PackageName

        $m = "  updating version: {0} -> {1}" -f $this.NuspecVersion, $this.RemoteVersion
        if ($this.Forced) {
            $m = ($this.RemoteVersion -eq $this.NuspecVersion) {
                    "  version not changed as it already uses 'revision': {0}" -f $this.NuspecVersion
            } else {
                    "    using Chocolatey fix notation: {0} -> {1}" -f $this.NuspecVersion, $this.RemoteVersion
            }
        }
        $msg += $m

        $this.NuspecXml.package.metadata.version = $this.RemoteVersion
        $this.NuspecXml.Save( $this.NuspecPath )

        #Update other files
        $SearchReplace.Keys | % {
            $fileName = $_
            $msg += "  $fileName"

            $fileContent = gc $fileName -Encoding UTF8
            $SearchReplace[ $fileName ].GetEnumerator() | % {
                $msg += '    {0} = {1} ' -f $_.name, $_.value
                if (!($fileContent -match $_.name)) { throw "Search pattern not found: '$($_.name)'" }
                $fileContent = $fileContent -replace $_.name, $_.value
            }

            $Utf8NoBomEncoding = New-Object System.Text.UTF8Encoding($False)
            [System.IO.File]::WriteAllLines((gi $fileName).FullName, $fileContent, $Utf8NoBomEncoding)
        }

        $this.Updated = $true
        return $msg
    }

    [string] GetChocoUrl() {
        $choco_url = "https://chocolatey.org/packages/{0}/{1}" -f $this.Name, $this.RemoteVersion
        try {
            request $choco_url $global:Timeout | out-null
            return $choco_url
        } catch { }
    }


    # https://github.com/chocolatey/choco/wiki/CreatePackages#package-fix-version-notation
    [string] SetRemoteVersionChocoFix() {
        $date_format = 'yyyyMMdd'
        $d = (get-date).ToString($date_format)

        $v = [version]($this.NuspecVersion -replace '-.+')
        $rev = $v.Revision.ToString()
        try { $revdate = [DateTime]::ParseExact($rev, $date_format,[System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None) } catch {}
        if (($rev -ne -1) -and !$revdate) { return $this.NuspecVersion }

        $build = if ($v.Build -eq -1) {0} else {$v.Build}
        $this.RemoteVersion = '{0}.{1}.{2}.{3}' -f $v.Major, $v.Minor, $build, $d
        return $this.RemoteVersion
    }

    [void] SetRemoteVersion( [string] $Version )
    {
        [AUPackage]::TestVersion( $Version )
        $this.RemoteVersion = $Version
    }

    #TODO: This function requires IE engine
    [void] SetChocoVersion()
    {
        $choco_url  = "https://chocolatey.org/packages/" + $this.Name
        $choco_page = Invoke-WebRequest -TimeoutSec ($global:Timeout+0) $choco_url
        $version    = $choco_page.AllElements | ? tagName -eq 'td' | ? title -eq 'Latest Version' | % InnerText
        $version    = $version.Replace($this.Name, '').Trim()

        [AUPackage]::TestVersion( $version )
        $this.ChocoVersion = $version
    }

    function SetChecksum( $ChecksumFor )
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

        function monkey_patch_choco {
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
        monkey_patch_choco

        # This will set the new URLs before the files are downloaded but will replace checksums to empty ones so download will not fail
        #  because checksums are at that moment set for the previous version.
        # SkipNuspecFile is passed so that if things fail here, nuspec file isn't updated; otherwise, on next run
        #  AU will think that package is the most recent.
        #
        # TODO: This will also leaves other then nuspec files updated which is undesired side effect (should be very rare)
        #
        this.Update()

        # Invoke installer for each architecture to download files
        invoke_installer
    }

    # ======================= STATIC =========================

    static [void] TestVersion( $Version ) {
        $re = '^(\d{1,16})\.(\d{1,16})\.*(\d{1,16})*\.*(\d{1,16})*(-[^.-]+)*$'
        if ($Version -notmatch $re) { throw "Version doesn't match the pattern '$re': '$Version'" }
        for($i=1; $i -le 3; $i++) {
            if ([int32]::MaxValue -lt [int64]$Matches[$i]) { throw "Version component is too big: $($Matches[$i])" }
        }
    }

    static [xml] LoadNuspecFile( $NuspecPath ) {
        $nu = New-Object xml
        $nu.PSBase.PreserveWhitespace = $true
        $nu.Load($NuspecPath)
        return $nu
    }

    static [HashTable] InitLatest {
        return @{
            PackageName   = $this.Name
            NuspecVersion = $this.NuspecVersion
        }
    }
}
