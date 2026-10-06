$ErrorActionPreference='Stop'
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot '..\CompanionRuntime.psm1') -Force -DisableNameChecking
Import-Module (Join-Path $PSScriptRoot '..\GenerationIdentity.psm1') -Force -DisableNameChecking
$root=Join-Path $PSScriptRoot ('.fixtures\multi-settings-'+[Guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $root,(Join-Path $root 'keys'),(Join-Path $root 'tunnel-profile') -Force
$exe=Join-Path $root 'tunnel-client.exe';[IO.File]::WriteAllBytes($exe,[byte[]](1,2,3))
$passed=0
function Assert([bool]$value){if(!$value){throw 'assertion failed'}}
function Test([string]$name,[scriptblock]$body){& $body;$script:passed++;Write-Output "PASS $name"}
function Profile([string]$id,[bool]$enabled=$true){[pscustomobject]@{profileId=$id;alias=$id;tunnelId=('tunnel_'+$id);enabled=$enabled;keyFile=('keys\'+$id+'.dpapi')}}
function Settings($profiles){[pscustomobject]@{tunnelClient=[pscustomobject]@{executable=$exe;profileDir='tunnel-profile'};tunnels=@($profiles)}}
function Refuses($settings){$failed=$false;try{ConvertTo-CompanionTunnelConfiguration $settings $root|Out-Null}catch{$failed=$_.Exception.Message -like 'COMPANION_SETTINGS_INVALID:*'};Assert $failed}
try {
    Test 'Zero legacy and zero Advanced tunnels remain valid' {
        foreach($settings in @([pscustomobject]@{tunnel=[pscustomobject]@{enabled=$false}},[pscustomobject]@{tunnels=@()})){
            $cfg=ConvertTo-CompanionTunnelConfiguration $settings $root;Assert (@($cfg.tunnels).Count -eq 0)
        }
    }
    Test 'One default tunnel retains its existing key and stable legacy identity' {
        $cfg=ConvertTo-CompanionTunnelConfiguration ([pscustomobject]@{tunnel=[pscustomobject]@{enabled=$true;executable=$exe;profileDir='tunnel-profile';alias='default';tunnelId='tunnel_default'}}) $root
        Assert ($cfg.tunnels.Count -eq 1 -and $cfg.tunnels[0].profileId -ceq 'default' -and $cfg.tunnels[0].keyFile -ceq 'keys\runtime-key.dpapi')
    }
    Test 'Existing mixed-case underscore aliases remain stable when migrated to Advanced profiles' {
        $alias='Office_Default'
        $legacy=[pscustomobject]@{tunnel=[pscustomobject]@{enabled=$true;executable=$exe;profileDir='tunnel-profile';alias=$alias;tunnelId='tunnel_Office_Default'}}
        $before=ConvertTo-CompanionTunnelConfiguration $legacy $root
        $advanced=Settings @([pscustomobject]@{profileId=$alias;alias=$alias;tunnelId='tunnel_Office_Default';enabled=$true;keyFile=$before.tunnels[0].keyFile})
        $after=ConvertTo-CompanionTunnelConfiguration $advanced $root
        Assert ($after.tunnels[0].profileId -ceq $alias -and $after.tunnels[0].alias -ceq $alias -and $after.tunnels[0].keyPath -ceq $before.tunnels[0].keyPath)
        $duplicate=Settings @((Profile 'Office_Default'),(Profile 'office_default'))
        Refuses $duplicate
    }
    $profiles=@((Profile alpha),(Profile beta),(Profile gamma))
    Test 'Three profiles have separate current-user DPAPI runtime keys' {
        foreach($profile in $profiles){
            $key=ConvertTo-SecureString ('fixture-multi-'+$profile.profileId) -AsPlainText -Force
            [IO.File]::WriteAllText((Join-Path $root $profile.keyFile),(ConvertFrom-SecureString $key),[Text.Encoding]::ASCII)
        }
        $cfg=ConvertTo-CompanionTunnelConfiguration (Settings $profiles) $root
        Assert ($cfg.tunnels.Count -eq 3)
        foreach($profile in $cfg.tunnels){$plain=Get-PlainRuntimeKey $profile;try {Assert ($plain -ceq ('fixture-multi-'+$profile.profileId))}finally{$plain=$null}}
        Assert (@($cfg.tunnels|Select-Object -ExpandProperty keyPath -Unique).Count -eq 3)
    }
    foreach($field in @('profileId','alias','tunnelId','keyFile')){
        Test "Duplicate $field fails closed" {
            $items=@((Profile alpha),(Profile beta));$items[1].$field=$items[0].$field
            Refuses (Settings $items)
        }
    }
    Test 'Disabled profiles are listed and retained for stop while start filters them out' {
        $collection=ConvertTo-CompanionTunnelConfiguration (Settings @((Profile alpha),(Profile beta $false),(Profile gamma))) $root
        Assert (@(Get-ConfiguredTunnels $collection).Count -eq 2)
        Assert (@(Get-ConfiguredTunnels $collection -IncludeDisabled).Count -eq 3)
    }
    Test 'Mixed schemas unsafe paths and nonboolean flags fail closed' {
        $mixed=Settings $profiles;$mixed|Add-Member tunnel ([pscustomobject]@{enabled=$false});Refuses $mixed
        $item=Profile alpha;$item.keyFile='..\outside.dpapi';Refuses (Settings @($item))
        $item=Profile alpha;$item.enabled='false';Refuses (Settings @($item))
    }
    $settingsPath=Join-Path $root 'settings.json';[IO.File]::WriteAllText($settingsPath,'{}')
    $cfg=[pscustomobject]@{companionRoot=$root;settingsPath=$settingsPath;projectPath=$root;codexlessRoot=$root;nodeExe=$exe;nodeSha256=('a'*64);port=17691;launchScript=(Join-Path $root 'scripts\launch.mjs');tunnelExe=$exe;profileDir=(Join-Path $root 'tunnel-profile');tunnels=(ConvertTo-CompanionTunnelConfiguration (Settings $profiles) $root).tunnels;release=[pscustomobject]@{version='fixture';buildId=('b'*64);sourceRevision=('c'*40);manifestSha256=('d'*64);hostContractVersion='codexless-public-preview-v1'}}
    Test 'Credential rotation changes recovery generation without putting secrets in identity output' {
        $before=Get-CompanionGenerationContract $cfg
        $path=$cfg.tunnels[1].keyPath
        [IO.File]::WriteAllText($path,(ConvertFrom-SecureString (ConvertTo-SecureString 'fixture-multi-rotated' -AsPlainText -Force)),[Text.Encoding]::ASCII)
        $after=Get-CompanionGenerationContract $cfg
        Assert ($before.sha256 -cne $after.sha256)
        $failed=$false;try {Assert-CompanionGenerationContract $before $cfg}catch {$failed=$true};Assert $failed
        $raw=$after|ConvertTo-Json;Assert (@($after.PSObject.Properties).Count -eq 2);Assert ($raw -notmatch 'fixture|keyPath|DPAPI|runtime|secret')
    }
    Test 'Profile identity registration and enabled changes invalidate generation' {
        foreach($field in @('profileId','alias','tunnelId','enabled')){
            $before=Get-CompanionGenerationContract $cfg;$prior=$cfg.tunnels[0].$field
            $cfg.tunnels[0].$field=if($field -ceq 'enabled'){$false}else{'changed'}
            Assert ((Get-CompanionGenerationContract $cfg).sha256 -cne $before.sha256)
            $cfg.tunnels[0].$field=$prior
        }
    }
    Test 'DPAPI corruption produces sanitized profile-local diagnostics' {
        $profile=$cfg.tunnels[2];[IO.File]::WriteAllText($profile.keyPath,'fixture-invalid-ciphertext')
        $message='';try {Get-PlainRuntimeKey $profile|Out-Null}catch {$message=$_.Exception.Message}
        Assert ($message -like 'TUNNEL_CREDENTIAL_INVALID:*' -and $message -notmatch 'invalid-ciphertext')
        Assert ((Get-PlainRuntimeKey $cfg.tunnels[0]) -ceq 'fixture-multi-alpha')
    }
    Test 'Only finite completed connect parents can prove a degraded child launch' {
        $finite=[pscustomobject]@{Ok=$false;Code='NATIVE_EXIT_FAILED';ExitCode=1;ProcessId=900;CreatedAt='2026-10-03T00:00:00.0000000Z';ExitedAt='2026-10-03T00:00:02.0000000Z';LifetimeMayRemain=$false;TimedOut=$false;OutputOverflow=$false}
        Assert (Test-TunnelConnectCompleted $finite)
        foreach($field in @('TimedOut','OutputOverflow','LifetimeMayRemain')){
            $finite.$field=$true;Assert (!(Test-TunnelConnectCompleted $finite));$finite.$field=$false
        }
        foreach($code in @('NATIVE_TIMEOUT','NATIVE_OUTPUT_LIMIT','NATIVE_SECURITY_POLICY_UNSUPPORTED','NATIVE_UNAVAILABLE')){
            $finite.Code=$code;Assert (!(Test-TunnelConnectCompleted $finite))
        }
        $finite.Code='NATIVE_EXIT_FAILED';$finite.ExitedAt='2026-10-02T00:00:00.0000000Z';Assert (!(Test-TunnelConnectCompleted $finite))
    }
} finally {Remove-Item -LiteralPath $root -Recurse -Force}
Write-Output ("RESULT: {0}/{0} PASS; destination-local collection, real DPAPI, generation digest only; no live tunnel or task actions" -f $passed)
