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

    [bool] IsUpdated() {
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

    [string[]] UpdateFiles(<#[HashTable]$Latest, #> [HashTable]$SR)
    {
        #$msg = @('Updating files')
        #$msg += '  $Latest data:'
        #$msg += $Latest.keys | sort | % { "    {0,-15} ({1})    {2}" -f $_, $Latest[$_].GetType().Name, $Latest[$_] }
        #$msg += ''

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
        $sr = au_SearchReplace
        $sr.Keys | % {
            $fileName = $_
            $msg += "  $fileName"

            $fileContent = gc $fileName -Encoding UTF8
            $sr[ $fileName ].GetEnumerator() | % {
                $msg += '    {0} = {1} ' -f $_.name, $_.value
                if (!($fileContent -match $_.name)) { throw "Search pattern not found: '$($_.name)'" }
                $fileContent = $fileContent -replace $_.name, $_.value
            }

            $Utf8NoBomEncoding = New-Object System.Text.UTF8Encoding($False)
            [System.IO.File]::WriteAllLines((gi $fileName).FullName, $fileContent, $Utf8NoBomEncoding)
        }

        return $msg
    }

    # https://github.com/chocolatey/choco/wiki/CreatePackages#package-fix-version-notation
    [void] SetRemoteVersionChocoFix() {
        $date_format = 'yyyyMMdd'
        $d = (get-date).ToString($date_format)

        $v = [version]($this.NuspecVersion -replace '-.+')
        $rev = $v.Revision.ToString()
        try { $revdate = [DateTime]::ParseExact($rev, $date_format,[System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None) } catch {}
        if (($rev -ne -1) -and !$revdate) { return }

        $build = if ($v.Build -eq -1) {0} else {$v.Build}
        $this.RemoteVersion = '{0}.{1}.{2}.{3}' -f $v.Major, $v.Minor, $build, $d
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
        $choco_page = Invoke-WebRequest $choco_url
        $version    = $choco_page.AllElements | ? tagName -eq 'td' | ? title -eq 'Latest Version' | % InnerText
        $version    = $version.Replace($this.Name, '').Trim()

        [AUPackage]::TestVersion( $version )
        $this.ChocoVersion = $version
    }

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
