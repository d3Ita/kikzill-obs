# ============================================================
#  Kikzill Roulette - verification et installation des mises a jour
# ------------------------------------------------------------
#  Appele par kikzill_roulette.lua, jamais a la main.
#  Ecrit son resultat dans un fichier cle=valeur (-Result) que le
#  script Lua relit : pas de parseur JSON cote Lua.
#
#  Sortie :
#    status  = ok | uptodate | updated | error
#    local   = version installee
#    remote  = version publiee
#    update  = 1 si une mise a jour est disponible
#    message = texte affiche dans OBS
# ============================================================

param(
  [ValidateSet('check', 'update')] [string] $Action = 'check',
  [Parameter(Mandatory = $true)]  [string] $Root,
  [Parameter(Mandatory = $true)]  [string] $Result,
  [string] $Repo   = 'd3Ita/kikzill-obs',
  [string] $Branch = 'main'
)

$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$out = [ordered]@{
  status  = 'error'
  'local' = '?'
  remote  = '?'
  update  = '0'
  message = 'Echec inattendu.'
}

function Write-Result {
  $lines = foreach ($k in $out.Keys) { "$k=$($out[$k])" }
  $dir = Split-Path -Parent $Result
  if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  Set-Content -Path $Result -Value $lines -Encoding utf8
}

function Get-Version($path) {
  if (-not (Test-Path $path)) { return $null }
  try { return (Get-Content $path -Raw | ConvertFrom-Json).version } catch { return $null }
}

# Invoke-RestMethod ne reconnait pas du JSON precede d'un BOM : il rend alors une
# chaine brute, et .version vaut $null. On accepte les deux formes.
function Get-RemoteVersion($url) {
  $resp = Invoke-RestMethod -Uri $url -TimeoutSec 20
  if ($resp -is [string]) {
    $resp = $resp.TrimStart([char]0xFEFF) | ConvertFrom-Json
  }
  return $resp.version
}

try {
  # --- version installee ---
  $localVersion = Get-Version (Join-Path $Root 'version.json')
  if (-not $localVersion) { $localVersion = '0.0.0' }
  $out['local'] = $localVersion

  # --- version publiee (cache-bust : GitHub sert le raw en cache) ---
  $stamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $url = "https://raw.githubusercontent.com/$Repo/$Branch/version.json?t=$stamp"
  $remoteVersion = Get-RemoteVersion $url
  $out['remote'] = $remoteVersion

  # Sans cette garde, une version distante illisible passerait pour "identique"
  # a la locale : l'updater annoncerait "a jour" alors qu'il n'a rien lu.
  if (-not $remoteVersion) {
    throw "Version distante illisible : le depot repond, mais version.json est vide ou malforme."
  }

  $available = ($remoteVersion -and $remoteVersion -ne $localVersion)
  $out['update'] = if ($available) { '1' } else { '0' }

  if (-not $available) {
    $out['status']  = 'uptodate'
    $out['message'] = "Overlay a jour (v$localVersion)."
    Write-Result; exit 0
  }

  if ($Action -eq 'check') {
    $out['status']  = 'ok'
    $out['message'] = "Version $remoteVersion disponible (installee : $localVersion)."
    Write-Result; exit 0
  }

  # --- installation ---
  $work = Join-Path $env:TEMP ("kikzill_update_" + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $work -Force | Out-Null
  try {
    $zip = Join-Path $work 'source.zip'
    # -UseBasicParsing : sans lui, PowerShell 5.1 tente d'utiliser le moteur
    # d'Internet Explorer et echoue en mode non interactif (c'est le cas ici,
    # lance depuis OBS).
    Invoke-WebRequest -Uri "https://github.com/$Repo/archive/refs/heads/$Branch.zip" `
                      -OutFile $zip -TimeoutSec 300 -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $work -Force

    # L'archive GitHub contient un unique dossier <repo>-<branche>/
    $extracted = Get-ChildItem -Path $work -Directory | Select-Object -First 1
    if (-not $extracted) { throw "Archive vide ou illisible." }

    # config.local.js n'est pas dans le depot : Copy-Item ne peut pas l'ecraser.
    Copy-Item -Path (Join-Path $extracted.FullName '*') -Destination $Root -Recurse -Force

    $out['status']  = 'updated'
    $out['local']   = $remoteVersion
    $out['message'] = "Mise a jour installee : v$localVersion -> v$remoteVersion."
  }
  finally {
    Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
  }
}
catch {
  $out['status'] = 'error'
  $detail = $_.Exception.Message

  # Le 404 est le cas le plus frequent : depot prive, renomme, ou branche absente.
  # Le message brut de .NET n'aide personne, on dit ce qu'il faut verifier.
  $code = $null
  if ($_.Exception.Response) { $code = [int]$_.Exception.Response.StatusCode }
  if ($code -eq 404) {
    $out['message'] = "Depot introuvable ($Repo, branche $Branch). " +
                      "Il doit exister et etre PUBLIC pour que la mise a jour fonctionne."
  }
  elseif ($detail -match 'resol|resolve|distant|remote name|timed out|expire') {
    $out['message'] = "Pas de reponse de GitHub : verifie ta connexion internet."
  }
  else {
    $out['message'] = "Echec : $detail"
  }
}

Write-Result
