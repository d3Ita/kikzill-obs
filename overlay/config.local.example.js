/* ============================================================
   Exemple du fichier genere automatiquement par le script OBS.
   Tu n'as normalement RIEN a faire ici : ouvre OBS → Outils →
   Scripts → Kikzill Roulette et remplis les champs.

   Ce fichier n'est la que pour depanner (overlay ouvert dans un
   navigateur, hors d'OBS) : copie-le en config.local.js.
   config.local.js est ignore par Git, il contient un secret.
   ============================================================ */
window.KIKZILL_CONFIG = {
  channel: "kikzill",
  botUsername: "",
  botToken: "",
  announceInChat: true,

  triggerReward: "redeemed Roulette Warframe",
  triggerCommand: "!roulette",
  cooldownMs: 600000,

  spinWarframeMs: 6000,
  weaponDelayMs: 2200,
  spinWeaponMs: 4200,
  holdMs: 45000,

  suspended: false,
  placeMode: false,
  fireOnce: 0,
};
