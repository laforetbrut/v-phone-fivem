param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z0-9_-]+$')]
    [string]$Id,

    [Parameter(Mandatory = $true)]
    [string]$Label,

    [string]$Developer = 'iFruit Developer',

    [ValidateSet('social', 'finance', 'utilities', 'travel', 'work', 'duty', 'entertainment', 'health', 'essentials')]
    [string]$Category = 'utilities'
)

$projectRoot = Split-Path -Parent $PSScriptRoot
$appsRoot = Join-Path $projectRoot 'apps'
$target = Join-Path $appsRoot $Id

if (Test-Path -LiteralPath $target) {
    throw "L'application '$Id' existe deja dans $target"
}

New-Item -ItemType Directory -Path $target | Out-Null

$manifest = @"
PhoneApp {
    id        = '$Id',
    label     = '$Label',
    icon      = 'note',
    category  = '$Category',
    desc      = 'Decrivez votre application en une phrase.',
    developer = '$Developer',
    version   = '1.0.0',
    accent    = '#0A84FF',
    permissions = { 'storage', 'notifications' },
    features  = { 'Interface Clear Glass', 'Donnees persistantes' },
    keywords  = { '$Id' },
    optional  = true,
}
"@

$page = @"
<!doctype html>
<html lang="fr">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="light dark">
  <title>$Label</title>
  <link rel="stylesheet" href="../../html/style.css">
  <script src="../../html/sdk.js"></script>
</head>
<body>
  <main id="app" style="padding:14px"></main>
  <script>
    Phone.mount({
      host: 'app',
      title: '$Label',
      state: { ready: true },
      render({ ui }) {
        return ui.hero({
          appicon: 'note',
          eyebrow: '$Developer',
          title: '$Label',
          subtitle: 'Votre application iFruit est prete.'
        }) + ui.notice({
          icon: 'check',
          tone: 'success',
          title: 'Installation terminee',
          body: 'Commencez a construire dans apps/$Id/index.html'
        });
      }
    });
  </script>
</body>
</html>
"@

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $target 'app.lua'), $manifest, $utf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $target 'index.html'), $page, $utf8NoBom)

Write-Host "Application '$Label' creee dans $target"
Write-Host "Redemarrez v-phone, puis installez-la depuis le FruitStore."
