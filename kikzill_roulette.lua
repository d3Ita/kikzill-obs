--[[ ============================================================
  Kikzill Roulette — pilotage depuis OBS
  ------------------------------------------------------------
  Installation : OBS → Outils → Scripts → + → choisir ce fichier.

  Le script ne dessine rien lui-meme. Il :
    - ecrit overlay/config.local.js a partir des champs ci-dessous ;
    - cree et pilote la source navigateur qui affiche overlay/index.html ;
    - suspend / reactive l'overlay (masquage dans toutes les scenes) ;
    - lance un tirage de test ;
    - verifie et installe les mises a jour depuis GitHub.

  Rien d'autre n'est a modifier a la main.
============================================================ ]]

local obs = obslua

------------------------------------------------------------------
-- Constantes
------------------------------------------------------------------

local REPO   = "d3Ita/kikzill-obs"
local BRANCH = "main"

-- Cles = noms des proprietes OBS. Une seule source de verite.
local DEFAULTS = {
  channel         = "",
  bot_username    = "",
  bot_token       = "",
  announce        = true,

  trigger_reward  = "redeemed Roulette Warframe",
  trigger_command = "!roulette",
  cooldown_min    = 10,

  spin_frame      = 6000,
  delay_weapon    = 2200,
  spin_weapon     = 4200,
  hold_sec        = 45,

  source_name     = "Kikzill Roulette",
  src_width       = 980,
  src_height      = 430,

  suspended       = false,
  place_mode      = false,
}

local S = {}                 -- valeurs courantes
local script_settings = nil  -- objet settings persistant (recu dans script_load)

local hk_suspend = obs.OBS_INVALID_HOTKEY_ID
local hk_test    = obs.OBS_INVALID_HOTKEY_ID

local poll_ticks_left = 0    -- scrutation du resultat de mise a jour

------------------------------------------------------------------
-- Statut affiche dans le panneau
------------------------------------------------------------------

local function set_status(msg)
  if script_settings ~= nil then
    obs.obs_data_set_string(script_settings, "status", msg)
  end
  obs.script_log(obs.LOG_INFO, msg)
end

------------------------------------------------------------------
-- Chemins
------------------------------------------------------------------

-- Renvoie le dossier du .lua, separateur final inclus.
-- Attention : OBS expose script_path() comme fonction GLOBALE, pas comme membre
-- du module obslua. On accepte les deux, au cas ou.
local function install_dir()
  local get = rawget(_G, "script_path") or obs.script_path
  if get == nil then
    obs.script_log(obs.LOG_ERROR, "[kikzill] script_path() introuvable : OBS trop ancien ?")
    return ""
  end
  return (get():gsub("\\", "/"))
end

local function overlay_dir()
  return install_dir() .. "overlay/"
end

-- Un chemin Windows devient file:///C:/... avec les caracteres speciaux encodes.
local function overlay_url()
  local path = overlay_dir() .. "index.html"
  path = path:gsub("[^%w%-%._~/:]", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
  if path:sub(1, 1) ~= "/" then path = "/" .. path end
  return "file://" .. path
end

-- Chemin Windows sans separateur final : "C:\dossier\" casserait le
-- decoupage des arguments de cmd.exe (l'antislash echappe le guillemet).
local function win_path(p)
  local w = p:gsub("/", "\\")
  return (w:gsub("\\+$", ""))
end

local function update_result_path()
  local tmp = os.getenv("TEMP") or os.getenv("TMP") or "."
  return (tmp:gsub("\\", "/")) .. "/kikzill_update_result.txt"
end

------------------------------------------------------------------
-- Ecriture de overlay/config.local.js
------------------------------------------------------------------

local function js_str(value)
  local v = tostring(value or "")
  v = v:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("[\r\n]", " ")
  return '"' .. v .. '"'
end

local function js_bool(value)
  return value and "true" or "false"
end

-- `extra.fireOnce` : horodatage unix pose pour declencher un tirage de test.
local function write_config(extra)
  local path = overlay_dir() .. "config.local.js"
  local file, err = io.open(path, "w")
  if not file then
    set_status("Impossible d'ecrire config.local.js : " .. tostring(err))
    return false
  end

  local channel = (S.channel or ""):gsub("^#", "")
  local token = S.bot_token or ""
  if token ~= "" and not token:match("^oauth:") then
    token = "oauth:" .. token
  end

  local lines = {
    "/* Genere par kikzill_roulette.lua - ne pas modifier a la main. */",
    "window.KIKZILL_CONFIG = {",
    "  channel: "        .. js_str(channel)            .. ",",
    "  botUsername: "    .. js_str(S.bot_username)     .. ",",
    "  botToken: "       .. js_str(token)              .. ",",
    "  announceInChat: " .. js_bool(S.announce)        .. ",",
    "",
    "  triggerReward: "  .. js_str(S.trigger_reward)   .. ",",
    "  triggerCommand: " .. js_str(S.trigger_command)  .. ",",
    "  cooldownMs: "     .. tostring(S.cooldown_min * 60000) .. ",",
    "",
    "  spinWarframeMs: " .. tostring(S.spin_frame)     .. ",",
    "  weaponDelayMs: "  .. tostring(S.delay_weapon)   .. ",",
    "  spinWeaponMs: "   .. tostring(S.spin_weapon)    .. ",",
    "  holdMs: "         .. tostring(S.hold_sec * 1000) .. ",",
    "",
    "  suspended: "      .. js_bool(S.suspended)       .. ",",
    "  placeMode: "      .. js_bool(S.place_mode)      .. ",",
    "  fireOnce: "       .. tostring((extra and extra.fireOnce) or 0) .. ",",
    "};",
    "",
  }

  file:write(table.concat(lines, "\n"))
  file:close()
  return true
end

------------------------------------------------------------------
-- Source navigateur
------------------------------------------------------------------

-- Recharge la page sans passer par le cache. Renvoie false si la source
-- n'existe pas encore.
local function refresh_overlay()
  local src = obs.obs_get_source_by_name(S.source_name)
  if src == nil then return false end

  local handler = obs.obs_source_get_proc_handler(src)
  local cd = obs.calldata_create()
  obs.proc_handler_call(handler, "refreshnocache", cd)
  obs.calldata_destroy(cd)
  obs.obs_source_release(src)
  return true
end

-- Masque ou reaffiche la source dans toutes les scenes. Combine a l'option
-- « couper la source quand elle est masquee », masquer coupe reellement la
-- connexion au chat : c'est la suspension.
local function set_overlay_visible(visible)
  local scenes = obs.obs_frontend_get_scenes()
  if scenes == nil then return 0 end

  local touched = 0
  for _, scene_src in ipairs(scenes) do
    local scene = obs.obs_scene_from_source(scene_src)
    local item = nil
    if obs.obs_scene_find_source_recursive ~= nil then
      item = obs.obs_scene_find_source_recursive(scene, S.source_name)
    end
    if item == nil then
      item = obs.obs_scene_find_source(scene, S.source_name)
    end
    if item ~= nil then
      obs.obs_sceneitem_set_visible(item, visible)
      touched = touched + 1
    end
  end

  obs.source_list_release(scenes)
  return touched
end

local function create_or_update_source()
  local settings = obs.obs_data_create()
  -- On passe par `url` (file:///...) et non par « fichier local » : c'est le seul
  -- mode ou la source lit bien l'URL qu'on lui donne.
  obs.obs_data_set_bool(settings, "is_local_file", false)
  obs.obs_data_set_string(settings, "url", overlay_url())
  obs.obs_data_set_int(settings, "width", S.src_width)
  obs.obs_data_set_int(settings, "height", S.src_height)
  obs.obs_data_set_bool(settings, "reroute_audio", false)
  obs.obs_data_set_bool(settings, "shutdown", true)             -- couper quand masquee
  obs.obs_data_set_bool(settings, "restart_when_active", false)

  local src = obs.obs_get_source_by_name(S.source_name)
  local created = false

  if src == nil then
    src = obs.obs_source_create("browser_source", S.source_name, settings, nil)
    created = true
  else
    obs.obs_source_update(src, settings)
  end
  obs.obs_data_release(settings)

  if src == nil then
    set_status("Creation de la source impossible : le module navigateur d'OBS est-il installe ?")
    return false
  end

  -- Ajout a la scene courante seulement si la source n'y est pas deja.
  local scene_src = obs.obs_frontend_get_current_scene()
  if scene_src ~= nil then
    local scene = obs.obs_scene_from_source(scene_src)
    if obs.obs_scene_find_source(scene, S.source_name) == nil then
      obs.obs_scene_add(scene, src)
    end
    obs.obs_source_release(scene_src)
  end

  obs.obs_source_release(src)
  return true, created
end

------------------------------------------------------------------
-- Actions des boutons
------------------------------------------------------------------

local function do_apply()
  if not write_config(nil) then return true end
  if refresh_overlay() then
    set_status("Reglages appliques, overlay recharge.")
  else
    set_status("Reglages enregistres. Source « " .. S.source_name ..
               " » introuvable : clique « Ajouter l'overlay a la scene ».")
  end
  return true
end

local function do_install_source()
  write_config(nil)
  local ok, created = create_or_update_source()
  if not ok then return true end
  refresh_overlay()
  if created then
    set_status("Source « " .. S.source_name .. " » ajoutee a la scene courante.")
  else
    set_status("Source « " .. S.source_name .. " » mise a jour (URL et dimensions).")
  end
  return true
end

local function do_toggle_suspend()
  S.suspended = not S.suspended
  if script_settings ~= nil then
    obs.obs_data_set_bool(script_settings, "suspended", S.suspended)
  end

  write_config(nil)
  local touched = set_overlay_visible(not S.suspended)
  refresh_overlay()

  if touched == 0 then
    set_status("Overlay " .. (S.suspended and "suspendu" or "reactive") ..
               " — mais la source n'est dans aucune scene.")
  elseif S.suspended then
    set_status("Overlay SUSPENDU : masque dans " .. touched ..
               " scene(s), deconnecte du chat.")
  else
    set_status("Overlay ACTIF : visible dans " .. touched .. " scene(s).")
  end
  return true
end

local function do_test_draw()
  if S.suspended then
    set_status("Overlay suspendu : reactive-le avant de lancer un test.")
    return true
  end

  write_config({ fireOnce = os.time() })
  set_overlay_visible(true)

  if refresh_overlay() then
    set_status("Tirage de test lance.")
  else
    set_status("Source introuvable : clique d'abord « Ajouter l'overlay a la scene ».")
  end
  return true
end

local function do_toggle_place()
  S.place_mode = not S.place_mode
  if script_settings ~= nil then
    obs.obs_data_set_bool(script_settings, "place_mode", S.place_mode)
  end

  write_config(nil)
  if S.place_mode then set_overlay_visible(true) end

  if refresh_overlay() then
    if S.place_mode then
      set_status("Mode positionnement ACTIF : place la source, puis reclique pour en sortir.")
    else
      set_status("Mode positionnement termine.")
    end
  else
    set_status("Source introuvable : clique d'abord « Ajouter l'overlay a la scene ».")
  end
  return true
end

------------------------------------------------------------------
-- Mises a jour
------------------------------------------------------------------

local read_update_result  -- declaration anticipee (utilisee par le timer)

read_update_result = function()
  poll_ticks_left = poll_ticks_left - 1
  local path = update_result_path()
  local file = io.open(path, "r")

  if file == nil then
    if poll_ticks_left <= 0 then
      obs.timer_remove(read_update_result)
      set_status("Mise a jour : aucune reponse (delai depasse). Voir le journal de scripts.")
    end
    return
  end

  local data = file:read("*a")
  file:close()
  os.remove(path)
  obs.timer_remove(read_update_result)

  local result = {}
  data = data:gsub("^\239\187\191", "")  -- BOM ecrit par PowerShell
  for line in data:gmatch("[^\r\n]+") do
    local key, value = line:match("^([%w_]+)=(.*)$")
    if key then result[key] = value end
  end

  set_status(result.message or "Mise a jour : reponse illisible.")

  if result.status == "updated" then
    refresh_overlay()
    set_status((result.message or "Mise a jour installee.") ..
               " Recharge le script (bouton ⟳ de la fenetre Scripts) pour finir.")
  end
end

local function launch_updater(action)
  local result = update_result_path()
  os.remove(result)

  local script = win_path(install_dir() .. "tools/update.ps1")
  local root   = win_path(install_dir())
  local out    = win_path(result)

  -- `start` rend la main tout de suite : l'interface d'OBS ne gele pas
  -- pendant le telechargement. Le resultat arrive par fichier.
  local cmd = string.format(
    'cmd /c start "" /min powershell -NoProfile -ExecutionPolicy Bypass ' ..
    '-File "%s" -Action %s -Root "%s" -Result "%s" -Repo "%s" -Branch "%s"',
    script, action, root, out, REPO, BRANCH)

  os.execute(cmd)

  obs.timer_remove(read_update_result)
  poll_ticks_left = 180          -- 180 x 1 s
  obs.timer_add(read_update_result, 1000)
end

local function do_check_update()
  set_status("Verification de la version en cours…")
  launch_updater("check")
  return true
end

local function do_install_update()
  set_status("Telechargement et installation en cours…")
  launch_updater("update")
  return true
end

local function do_open_folder()
  os.execute('cmd /c start "" "' .. win_path(install_dir()) .. '"')
  return true
end

------------------------------------------------------------------
-- Lecture des reglages
------------------------------------------------------------------

local function load_settings(settings)
  S.channel         = obs.obs_data_get_string(settings, "channel")
  S.bot_username    = obs.obs_data_get_string(settings, "bot_username")
  S.bot_token       = obs.obs_data_get_string(settings, "bot_token")
  S.announce        = obs.obs_data_get_bool(settings,   "announce")

  S.trigger_reward  = obs.obs_data_get_string(settings, "trigger_reward")
  S.trigger_command = obs.obs_data_get_string(settings, "trigger_command")
  S.cooldown_min    = obs.obs_data_get_int(settings,    "cooldown_min")

  S.spin_frame      = obs.obs_data_get_int(settings,    "spin_frame")
  S.delay_weapon    = obs.obs_data_get_int(settings,    "delay_weapon")
  S.spin_weapon     = obs.obs_data_get_int(settings,    "spin_weapon")
  S.hold_sec        = obs.obs_data_get_int(settings,    "hold_sec")

  S.source_name     = obs.obs_data_get_string(settings, "source_name")
  S.src_width       = obs.obs_data_get_int(settings,    "src_width")
  S.src_height      = obs.obs_data_get_int(settings,    "src_height")

  S.suspended       = obs.obs_data_get_bool(settings,   "suspended")
  S.place_mode      = obs.obs_data_get_bool(settings,   "place_mode")

  if S.source_name == nil or S.source_name == "" then
    S.source_name = DEFAULTS.source_name
  end
end

------------------------------------------------------------------
-- Interface OBS
------------------------------------------------------------------

function script_description()
  return [[
<h2>Kikzill Roulette — Warframe &amp; Arme</h2>
<p>Tire au sort une Warframe et une arme en direct, sur une récompense de
points de chaîne ou sur une commande du chat.</p>
<ol>
<li>Renseigne ta chaîne Twitch et, si tu veux que le bot annonce le résultat,
le compte du bot et son token.</li>
<li>Clique <b>Ajouter l'overlay à la scène</b>.</li>
<li>Place et redimensionne la source dans ta scène — le <b>mode positionnement</b>
la rend visible pendant que tu la déplaces.</li>
</ol>
<p>Token du bot : <a href="https://twitchapps.com/tmi/">twitchapps.com/tmi</a>.
Il reste sur ton PC, il n'est jamais envoyé ailleurs.</p>
]]
end

function script_defaults(settings)
  obs.obs_data_set_default_string(settings, "channel",         DEFAULTS.channel)
  obs.obs_data_set_default_string(settings, "bot_username",    DEFAULTS.bot_username)
  obs.obs_data_set_default_string(settings, "bot_token",       DEFAULTS.bot_token)
  obs.obs_data_set_default_bool(settings,   "announce",        DEFAULTS.announce)

  obs.obs_data_set_default_string(settings, "trigger_reward",  DEFAULTS.trigger_reward)
  obs.obs_data_set_default_string(settings, "trigger_command", DEFAULTS.trigger_command)
  obs.obs_data_set_default_int(settings,    "cooldown_min",    DEFAULTS.cooldown_min)

  obs.obs_data_set_default_int(settings,    "spin_frame",      DEFAULTS.spin_frame)
  obs.obs_data_set_default_int(settings,    "delay_weapon",    DEFAULTS.delay_weapon)
  obs.obs_data_set_default_int(settings,    "spin_weapon",     DEFAULTS.spin_weapon)
  obs.obs_data_set_default_int(settings,    "hold_sec",        DEFAULTS.hold_sec)

  obs.obs_data_set_default_string(settings, "source_name",     DEFAULTS.source_name)
  obs.obs_data_set_default_int(settings,    "src_width",       DEFAULTS.src_width)
  obs.obs_data_set_default_int(settings,    "src_height",      DEFAULTS.src_height)

  obs.obs_data_set_default_bool(settings,   "suspended",       DEFAULTS.suspended)
  obs.obs_data_set_default_bool(settings,   "place_mode",      DEFAULTS.place_mode)
end

function script_properties()
  local props = obs.obs_properties_create()

  obs.obs_properties_add_text(props, "status", "État", obs.OBS_TEXT_INFO)

  -- --- Twitch ---------------------------------------------------
  local twitch = obs.obs_properties_create()
  obs.obs_properties_add_text(twitch, "channel", "Chaîne Twitch", obs.OBS_TEXT_DEFAULT)
  obs.obs_properties_add_text(twitch, "bot_username", "Compte du bot", obs.OBS_TEXT_DEFAULT)
  obs.obs_properties_add_text(twitch, "bot_token", "Token OAuth du bot", obs.OBS_TEXT_PASSWORD)
  obs.obs_properties_add_bool(twitch, "announce", "Annoncer le résultat dans le chat")
  obs.obs_properties_add_group(props, "grp_twitch", "Connexion Twitch",
                               obs.OBS_GROUP_NORMAL, twitch)

  -- --- Declencheurs ---------------------------------------------
  local trig = obs.obs_properties_create()
  obs.obs_properties_add_text(trig, "trigger_reward",
      "Texte de la récompense", obs.OBS_TEXT_DEFAULT)
  obs.obs_properties_add_text(trig, "trigger_command",
      "Commande chat (vide = désactivée)", obs.OBS_TEXT_DEFAULT)
  obs.obs_properties_add_int_slider(trig, "cooldown_min",
      "Cooldown (minutes)", 0, 120, 1)
  obs.obs_properties_add_group(props, "grp_trigger", "Déclencheurs",
                               obs.OBS_GROUP_NORMAL, trig)

  -- --- Animation -------------------------------------------------
  local anim = obs.obs_properties_create()
  obs.obs_properties_add_int_slider(anim, "spin_frame",
      "Défilement Warframe (ms)", 1000, 15000, 100)
  obs.obs_properties_add_int_slider(anim, "delay_weapon",
      "Suspense avant l'arme (ms)", 0, 10000, 100)
  obs.obs_properties_add_int_slider(anim, "spin_weapon",
      "Défilement arme (ms)", 1000, 15000, 100)
  obs.obs_properties_add_int_slider(anim, "hold_sec",
      "Affichage du résultat (s)", 3, 180, 1)
  obs.obs_properties_add_group(props, "grp_anim", "Animation",
                               obs.OBS_GROUP_NORMAL, anim)

  -- --- Source ----------------------------------------------------
  local src = obs.obs_properties_create()
  obs.obs_properties_add_text(src, "source_name", "Nom de la source", obs.OBS_TEXT_DEFAULT)
  obs.obs_properties_add_int(src, "src_width",  "Largeur (px)", 320, 3840, 10)
  obs.obs_properties_add_int(src, "src_height", "Hauteur (px)", 200, 2160, 10)
  obs.obs_properties_add_group(props, "grp_source", "Source overlay",
                               obs.OBS_GROUP_NORMAL, src)

  -- --- Actions ---------------------------------------------------
  obs.obs_properties_add_button(props, "btn_apply",
      "✔  Appliquer les réglages", do_apply)
  obs.obs_properties_add_button(props, "btn_install",
      "➕  Ajouter l'overlay à la scène", do_install_source)
  obs.obs_properties_add_button(props, "btn_suspend",
      "⏸  Suspendre / réactiver l'overlay", do_toggle_suspend)
  obs.obs_properties_add_button(props, "btn_place",
      "📐  Mode positionnement (activer / quitter)", do_toggle_place)
  obs.obs_properties_add_button(props, "btn_test",
      "🎲  Tester un tirage", do_test_draw)

  -- --- Maintenance ------------------------------------------------
  local maint = obs.obs_properties_create()
  obs.obs_properties_add_button(maint, "btn_check",
      "🔎  Vérifier les mises à jour", do_check_update)
  obs.obs_properties_add_button(maint, "btn_update",
      "⬇  Installer la mise à jour", do_install_update)
  obs.obs_properties_add_button(maint, "btn_folder",
      "📂  Ouvrir le dossier d'installation", do_open_folder)
  obs.obs_properties_add_group(props, "grp_maint", "Maintenance",
                               obs.OBS_GROUP_NORMAL, maint)

  return props
end

function script_update(settings)
  load_settings(settings)
  write_config(nil)   -- le fichier suit les champs ; le rechargement reste manuel
end

function script_load(settings)
  script_settings = settings
  load_settings(settings)

  hk_suspend = obs.obs_hotkey_register_frontend(
      "kikzill_toggle_suspend",
      "Kikzill Roulette : suspendre / réactiver l'overlay",
      function(pressed) if pressed then do_toggle_suspend() end end)

  hk_test = obs.obs_hotkey_register_frontend(
      "kikzill_test_draw",
      "Kikzill Roulette : lancer un tirage de test",
      function(pressed) if pressed then do_test_draw() end end)

  local arr = obs.obs_data_get_array(settings, "hk_suspend")
  obs.obs_hotkey_load(hk_suspend, arr)
  obs.obs_data_array_release(arr)

  arr = obs.obs_data_get_array(settings, "hk_test")
  obs.obs_hotkey_load(hk_test, arr)
  obs.obs_data_array_release(arr)

  if S.suspended then
    set_status("Overlay SUSPENDU. Clique « Suspendre / réactiver » pour le relancer.")
  elseif (S.channel or "") == "" then
    set_status("Renseigne ta chaîne Twitch, puis clique « Ajouter l'overlay à la scène ».")
  else
    set_status("Prêt — chaîne #" .. S.channel .. ".")
  end
end

function script_save(settings)
  local arr = obs.obs_hotkey_save(hk_suspend)
  obs.obs_data_set_array(settings, "hk_suspend", arr)
  obs.obs_data_array_release(arr)

  arr = obs.obs_hotkey_save(hk_test)
  obs.obs_data_set_array(settings, "hk_test", arr)
  obs.obs_data_array_release(arr)
end

function script_unload()
  obs.timer_remove(read_update_result)
end
