function monkey_patch_choco()
{
    $choco_tmp_path = "$Env:TEMP\chocolatey\au\chocolatey"
    sleep -milliseconds (get-random 500) #reduce probability multiple updateall threads entering here at the same time (#29)

    # copy choco modules once a day
    if (Test-Path $choco_tmp_path) {
        $ct = gi $choco_tmp_path | % CreationTime
        if (((get-date) - $ct).days -gt 1) { rm -recurse -force $choco_tmp_path } else { Write-Verbose 'chocolatey copy is recent, aborting monkey patching'; return }
    }

    Write-Verbose "Monkey patching chocolatey in: '$choco_tmp_path'"
    cp -recurse -force $env:chocolateyinstall\helpers $choco_tmp_path\helpers
    if (test-path $env:chocolateyinstall\extensions) { cp -recurse -force $env:chocolateyinstall\extensions $choco_tmp_path\extensions }

    $fun_path = "$choco_tmp_path\helpers\functions\get-chocolateywebfile.ps1"
    (gc $fun_path) -replace '^\s+return \$filefullpath\s*$', '  throw "au_break: $filefullpath"' | sc $fun_path -ea ignore

    $choco_tmp_path
}

