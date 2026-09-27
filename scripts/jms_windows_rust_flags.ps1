function Get-JmsWindowsRustFlags {
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    # Cargo splits RUSTFLAGS on whitespace; encoded flags preserve spaces in paths.
    $flags = @()
    if ($env:CARGO_ENCODED_RUSTFLAGS) {
        $flags += $env:CARGO_ENCODED_RUSTFLAGS.Split([char]31)
    } elseif ($env:RUSTFLAGS) {
        $flags += @($env:RUSTFLAGS -split '\s+' | Where-Object { $_ })
    }
    $roots = @(
        @{ Path = $env:USERPROFILE; Label = '/jms-build/profile' },
        @{ Path = $env:CARGO_HOME; Label = '/jms-build/cargo' },
        @{ Path = $env:PUB_CACHE; Label = '/jms-build/pub-cache' },
        @{ Path = $ProjectRoot; Label = '/jms-build/source' }
    ) | Where-Object { $_.Path } | Sort-Object { $_.Path.Length }
    foreach ($root in $roots) {
        foreach ($prefix in @($root.Path.TrimEnd('\', '/'), $root.Path.TrimEnd('\', '/').Replace('\', '/')) | Select-Object -Unique) {
            $flags += "--remap-path-prefix=$prefix=$($root.Label)"
        }
    }
    return $flags -join [char]31
}
