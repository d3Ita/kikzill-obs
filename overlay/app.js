/* ============================================================
   Kikzill Roulette — moteur de l'overlay (Warframe + Arme)
   ------------------------------------------------------------
   Aucun reglage a toucher ici : tout vient de config.local.js,
   genere par le script OBS (kikzill_roulette.lua).

   Parametres d'URL de depannage (le script OBS, lui, passe par config.local.js) :
     ?place=1        cadre de positionnement, rien d'autre
     ?fire=1         lance un tirage de test des le chargement
     ?channel=xxx    ecoute une autre chaine
   ============================================================ */
'use strict';

/* --- Taille de dessin. Tout le CSS est cale dessus. ---------- */
const STAGE = { w: 980, h: 430 };

/* --- Configuration ------------------------------------------- */

const DEFAULTS = {
  channel: '',
  botUsername: '',
  botToken: '',
  announceInChat: true,

  triggerReward: 'redeemed Roulette Warframe',
  triggerCommand: '!roulette',
  allowedAccounts: ['own3d', 'streamelements', 'streamlabs', 'nightbot'],

  spinWarframeMs: 6000,
  weaponDelayMs: 2200,
  spinWeaponMs: 4200,
  holdMs: 45000,
  cooldownMs: 600000,

  suspended: false,
  placeMode: false,
  fireOnce: 0,        // horodatage (s) pose par OBS pour un tirage de test
  debug: false,
};

const CFG = Object.assign({}, DEFAULTS, window.KIKZILL_CONFIG || {});

const params = new URLSearchParams(location.search);
const MODE_PLACE = CFG.placeMode === true || params.get('place') === '1';

// Le bouton « Tester un tirage » d'OBS pose un horodatage dans config.local.js.
// Il se perime tout seul : un redemarrage d'OBS ne relance donc pas de tirage.
const FIRE_NOW = params.has('fire')
  || (Number(CFG.fireOnce) > 0 && (Date.now() / 1000 - Number(CFG.fireOnce)) < 15);
if (params.has('channel')) CFG.channel = params.get('channel');

const log = (...a) => console.log('[kikzill]', ...a);

/* --- Rendu : mise a l'echelle de la scene --------------------- */

const stage = document.getElementById('stage');
const panel = document.getElementById('panel');

stage.style.width = STAGE.w + 'px';
stage.style.height = STAGE.h + 'px';

function fitStage() {
  const scale = Math.min(window.innerWidth / STAGE.w, window.innerHeight / STAGE.h);
  stage.style.transform = 'translate(-50%, -50%) scale(' + scale + ')';
}
fitStage();
window.addEventListener('resize', fitStage);

/* --- Petits utilitaires --------------------------------------- */

// Entier uniforme dans [0, max[, sans le biais du modulo de Math.random().
function randInt(max) {
  const buf = new Uint32Array(1);
  const limit = Math.floor(0x100000000 / max) * max;
  let n;
  do { crypto.getRandomValues(buf); n = buf[0]; } while (n >= limit);
  return n % max;
}

const wait = ms => new Promise(r => setTimeout(r, Math.max(0, ms)));

// Resout meme si l'image manque : un visuel casse ne doit jamais bloquer un tirage.
function preload(src) {
  return new Promise(resolve => {
    const img = new Image();
    img.onload = () => resolve(true);
    img.onerror = () => resolve(false);
    img.src = src;
  });
}

/* --- Un rail --------------------------------------------------- */

const STRIP_LENGTH = 64;   // vignettes generees par rail
const WINNER_INDEX = 55;   // position du gagnant dans la bande
const EASING = 'cubic-bezier(0.08, 0.82, 0.17, 1)';

class Reel {
  constructor(railId, trainId, items, imgDir) {
    this.rail = document.getElementById(railId);
    this.train = document.getElementById(trainId);
    this.items = items;
    this.imgDir = imgDir;
    this.winnerEl = null;

    if (!this.rail || !this.train) throw new Error('Rail introuvable : ' + railId);
    if (!items || !items.length) throw new Error('Liste vide pour ' + railId);
  }

  imageFor(name) {
    return this.imgDir + encodeURIComponent(name) + '.webp';
  }

  makeCell(name) {
    const cell = document.createElement('div');
    cell.className = 'wagon';

    const img = document.createElement('img');
    img.src = this.imageFor(name);
    img.alt = name;
    img.decoding = 'async';
    img.draggable = false;
    img.addEventListener('error', () => { img.style.visibility = 'hidden'; }, { once: true });

    const label = document.createElement('span');
    label.textContent = name;

    cell.append(img, label);
    return cell;
  }

  // Le gagnant est place a une position connue de la bande : le tirage est
  // donc uniforme sur toute la liste, l'animation ne fait que le montrer.
  prepare(winner) {
    const frag = document.createDocumentFragment();

    for (let i = 0; i < STRIP_LENGTH; i++) {
      const name = i === WINNER_INDEX ? winner : this.items[randInt(this.items.length)];
      const cell = this.makeCell(name);
      if (i === WINNER_INDEX) this.winnerEl = cell;
      frag.appendChild(cell);
    }

    this.train.style.transition = 'none';
    this.train.style.transform = 'translateX(0)';
    this.train.replaceChildren(frag);
    void this.train.offsetWidth;   // applique la position de depart tout de suite
  }

  spin(duration) {
    const target = this.winnerEl;
    const width = target.offsetWidth;
    // Leger decalage : le gagnant ne s'arrete jamais pile au pixel pres, tout
    // en restant sous le marqueur central.
    const jitter = (Math.random() - 0.5) * width * 0.7;
    const distance = target.offsetLeft + width / 2 - this.rail.clientWidth / 2 + jitter;

    this.rail.classList.add('spinning');

    return new Promise(resolve => {
      let done = false;
      const finish = () => {
        if (done) return;
        done = true;
        clearTimeout(safety);
        this.rail.classList.remove('spinning');
        target.classList.add('highlight');
        resolve();
      };

      // Filet : si transitionend ne part pas (source en pause, scene inactive),
      // on debloque quand meme.
      const safety = setTimeout(finish, duration + 400);
      this.train.addEventListener('transitionend', finish, { once: true });

      requestAnimationFrame(() => {
        this.train.style.transition = 'transform ' + duration + 'ms ' + EASING;
        this.train.style.transform = 'translateX(' + (-distance) + 'px)';
      });
    });
  }

  reset() {
    this.train.style.transition = 'none';
    this.train.style.transform = 'translateX(0)';
    this.train.replaceChildren();
    this.rail.classList.remove('spinning');
    this.winnerEl = null;
  }
}

/* --- Elements du resultat -------------------------------------- */

const result = document.getElementById('result');
const cardFrame = document.getElementById('card-warframe');
const imgFrame = document.getElementById('img-warframe');
const nameFrame = document.getElementById('name-warframe');
const cardWeapon = document.getElementById('card-weapon');
const imgWeapon = document.getElementById('img-weapon');
const nameWeapon = document.getElementById('name-weapon');

const reelFrame = new Reel('rail-warframe', 'train-warframe', window.WARFRAMES, 'img/warframes/');
const reelWeapon = new Reel('rail-weapon', 'train-weapon', window.WEAPONS, 'img/weapons/');

/* --- Deroulement d'un tirage ------------------------------------ */

let running = false;
let cooldownUntil = 0;

function showCard(card, img, label, name, src) {
  img.src = src;
  img.style.visibility = 'visible';
  label.textContent = name;
  card.classList.add('reveal');
}

async function draw(channel) {
  if (running) return;
  running = true;

  // Le resultat est tire avant l'animation : elle ne fait que le reveler.
  const winFrame = window.WARFRAMES[randInt(window.WARFRAMES.length)];
  const winWeapon = window.WEAPONS[randInt(window.WEAPONS.length)];
  log('tirage :', winFrame, '+', winWeapon);

  try {
    result.classList.remove('show');
    cardFrame.classList.remove('reveal');
    cardWeapon.classList.remove('reveal');
    imgFrame.style.visibility = 'hidden';
    imgWeapon.style.visibility = 'hidden';
    nameFrame.textContent = '…';
    nameWeapon.textContent = '…';

    reelFrame.prepare(winFrame);
    reelWeapon.prepare(winWeapon);

    // Les visuels du resultat se chargent pendant le spin : pas de « pop ».
    const artReady = Promise.all([
      preload(reelFrame.imageFor(winFrame)),
      preload(reelWeapon.imageFor(winWeapon)),
    ]);

    panel.classList.add('show');
    await new Promise(requestAnimationFrame);

    // Les deux rails partent ensemble, l'arme s'arrete plus tard.
    const spinFrame = reelFrame.spin(CFG.spinWarframeMs);
    const spinWeapon = wait(CFG.spinWarframeMs + CFG.weaponDelayMs - CFG.spinWeaponMs)
      .then(() => reelWeapon.spin(CFG.spinWeaponMs));

    await spinFrame;
    await artReady;
    showCard(cardFrame, imgFrame, nameFrame, winFrame, reelFrame.imageFor(winFrame));
    result.classList.add('show');

    await spinWeapon;
    showCard(cardWeapon, imgWeapon, nameWeapon, winWeapon, reelWeapon.imageFor(winWeapon));

    if (channel && CFG.announceInChat) {
      say(channel, 'La configuration : ' + winFrame + ' avec l\'arme ' + winWeapon + ' !');
    }

    await wait(CFG.holdMs);
  } catch (err) {
    console.error('[kikzill] tirage interrompu :', err);
  } finally {
    // Quoi qu'il arrive, l'overlay se referme et redevient utilisable.
    panel.classList.remove('show');
    result.classList.remove('show');
    await wait(600);   // duree du fondu CSS
    cardFrame.classList.remove('reveal');
    cardWeapon.classList.remove('reveal');
    reelFrame.reset();
    reelWeapon.reset();
    running = false;
  }
}

/* --- Mode positionnement ---------------------------------------- */

if (MODE_PLACE) {
  document.getElementById('place-frame').hidden = false;
  panel.classList.add('show');
  nameFrame.textContent = 'Warframe';
  nameWeapon.textContent = 'Arme';
  reelFrame.prepare(window.WARFRAMES[0]);
  reelWeapon.prepare(window.WEAPONS[0]);
  log('mode positionnement : aucune connexion au chat.');
}

/* --- Connexion Twitch -------------------------------------------- */

let client = null;
let canSpeak = false;

function say(channel, message) {
  if (!canSpeak || !client) {
    log('(lecture seule) message non envoye :', message);
    return;
  }
  client.say(channel, message).catch(e => console.error('[kikzill] envoi impossible :', e));
}

function isAllowed(tags) {
  const login = (tags.username || '').toLowerCase();
  return Boolean(tags.mod)
    || 'broadcaster' in (tags.badges || {})
    || login === (CFG.channel || '').toLowerCase()
    || CFG.allowedAccounts.map(a => a.toLowerCase()).includes(login);
}

function connectTwitch() {
  if (typeof tmi === 'undefined') {
    console.error('[kikzill] vendor/tmi.min.js absent : pas de connexion au chat.');
    return;
  }

  const channel = (CFG.channel || '').replace(/^#/, '').trim();
  if (!channel) {
    console.warn('[kikzill] aucune chaine configuree : ouvre Outils → Scripts dans OBS.');
    return;
  }

  const token = (CFG.botToken || '').trim();
  canSpeak = Boolean(token && CFG.botUsername);

  const options = {
    options: { debug: Boolean(CFG.debug), skipUpdatingEmotesets: true },
    connection: { reconnect: true, secure: true },
    channels: [channel],
  };

  if (canSpeak) {
    options.identity = {
      username: CFG.botUsername,
      password: token.startsWith('oauth:') ? token : 'oauth:' + token,
    };
  }

  client = new tmi.Client(options);

  client.on('message', (chan, tags, message, self) => {
    if (self) return;

    const text = message.trim();
    const byReward = Boolean(CFG.triggerReward) && text.includes(CFG.triggerReward);
    const byCommand = Boolean(CFG.triggerCommand)
      && text.toLowerCase() === CFG.triggerCommand.toLowerCase();

    if (!byReward && !byCommand) return;
    if (!isAllowed(tags)) return;
    if (running) return;

    const left = cooldownUntil - Date.now();
    if (left > 0) {
      say(chan, 'La roulette est en cooldown encore ' + Math.ceil(left / 60000) + ' min.');
      return;
    }

    cooldownUntil = Date.now() + CFG.cooldownMs;
    draw(chan);
  });

  client.connect()
    .then(() => log('connecte au chat de #' + channel + (canSpeak ? '' : ' (lecture seule)')))
    .catch(err => console.error('[kikzill] connexion Twitch impossible :', err));
}

/* --- Demarrage ---------------------------------------------------- */

if (MODE_PLACE) {
  // on positionne la source, on ne touche pas au chat
} else if (CFG.suspended) {
  log('overlay suspendu depuis OBS : aucune connexion au chat.');
} else {
  connectTwitch();
}

// Tirage de test demande depuis OBS (bouton « Tester un tirage »).
if (FIRE_NOW && !MODE_PLACE) {
  log('tirage de test.');
  draw(null);
}
