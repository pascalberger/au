class AUPackage {
    [string]   $Path
    [string]   $Name
    [bool]     $Updated
    [bool]     $Pushed
    [string]   $RemoteVersion
    [string]   $NuspecVersion
    [string[]] $Result
    [string]   $Error
    [string]   $NuspecPath
    [xml]      $NuspecXml

    AUPackage([string] $Path ){
        if ([String]::IsNullOrWhiteSpace( $Path )) { throw 'Package path can not be empty' }

        $this.Path = $Path
        $this.Name = Split-Path -Leaf $Path

        $this.NuspecPath = '{0}\{1}.nuspec' -f $this.Path, $this.Name
        if (!(gi $this.NuspecPath -ea ignore)) { throw 'No nuspec file found in the package directory' }

        $this.NuspecXml     = [AUPackage]::LoadNuspecFile( $this.NuspecPath )
        $this.NuspecVersion = $this.NuspecXml.package.metadata.version
    }

    static [xml] LoadNuspecFile( $NuspecPath ) {
        $nu = New-Object xml
        $nu.PSBase.PreserveWhitespace = $true
        $nu.Load($NuspecPath)
        return $nu
    }

    static [string] GetCommunityStatus($Package) {
        $package_url = 'https://chocolatey.org/packages/{0}/{1}' -f $Package.Name, $Package.Version
        $page = Invoke-WebRequest $package_url
        if (!$page) { return 'err page' }

        $tr = $page.AllElements | ? class -like '*versiontablerow*'
        if (!$tr) { return 'err vtable' }

        $version_row = $tr -match ("{0} {1}" -f $Package.NuspecXml.package.metadata.title, $Package.Version)
        if (!$version_row) { return 'err vrow' }

        $status = $version_row.innerText -split ' ' | select -last 1
        return $status
    }
}
