# Kikzill Roulette pour OBS

Tire au sort une **Warframe** et une **arme** en direct, déclenché par une récompense
de points de chaîne ou par une commande du chat.

Tout se pilote depuis OBS : un panneau de réglages, un overlay déplaçable dans la
scène, un bouton pour suspendre, un bouton pour mettre à jour.

---

## Sommaire

- [Installation](#installation)
- [Configuration](#configuration)
- [Placer l'overlay dans la scène](#placer-loverlay-dans-la-scène)
- [Suspendre l'overlay](#suspendre-loverlay)
- [Mise à jour](#mise-à-jour)
- [Raccourcis clavier](#raccourcis-clavier)
- [Modifier les listes](#modifier-les-listes)
- [En cas de problème](#en-cas-de-problème)
- [Structure du dépôt](#structure-du-dépôt)

---

## Installation

1. Télécharge le dépôt : **Code → Download ZIP**, puis décompresse-le où tu veux
   (par exemple `Documents\kikzill-obs`). Ne le laisse pas dans le dossier
   *Téléchargements* : c'est là qu'il vivra et qu'il se mettra à jour.
2. Dans OBS : **Outils → Scripts → `+`**, et choisis `kikzill_roulette.lua`.
3. Remplis les champs (voir ci-dessous), puis clique
   **➕ Ajouter l'overlay à la scène**.

C'est tout — pas de compilation, pas de serveur à lancer.

> Prérequis : OBS 28 ou plus récent, avec le module **source navigateur**
> (installé par défaut sous Windows).

---

## Configuration

| Champ | À quoi ça sert |
|:---|:---|
| **Chaîne Twitch** | la chaîne dont on écoute le chat, sans le `#` |
| **Compte du bot** | le compte qui annoncera le résultat dans le chat |
| **Token OAuth du bot** | généré sur [twitchapps.com/tmi](https://twitchapps.com/tmi/) |
| **Annoncer le résultat** | décoche pour un overlay totalement muet |
| **Texte de la récompense** | le message que poste ton bot de points de chaîne |
| **Commande chat** | `!roulette` par défaut, vide pour la désactiver |
| **Cooldown** | délai minimum entre deux tirages, en minutes |

Laisse **compte du bot** et **token** vides pour un mode lecture seule : l'overlay
réagit toujours au chat, il n'écrit simplement rien dedans.

Le token est écrit dans `overlay/config.local.js`, **sur ton PC uniquement**. Ce
fichier est ignoré par Git : il ne peut pas partir dans le dépôt par accident.

Après avoir modifié un champ, clique **✔ Appliquer les réglages** pour que
l'overlay recharge sa configuration.

### Déclenchement

Un tirage part quand un message du chat :

- contient le **texte de la récompense** (c'est ton bot de points de chaîne qui le
  poste : OWN3D, StreamElements, Streamlabs, Nightbot…), **ou**
- est exactement la **commande chat**.

Dans les deux cas l'auteur doit être le streamer, un modérateur, ou l'un des bots
reconnus. Les viewers ne peuvent pas déclencher la roulette avec la commande.

---

## Placer l'overlay dans la scène

L'overlay est une source navigateur classique : tu la déplaces et la
redimensionnes à la souris dans ta scène. Comme elle est invisible au repos,
clique **📐 Mode positionnement** : l'overlay s'affiche en permanence avec un
cadre, tu le places tranquillement, puis tu recliques pour en sortir.

Le contenu se met à l'échelle tout seul : agrandis ou réduis la source, rien ne
se déforme et rien n'est coupé.

---

## Suspendre l'overlay

**⏸ Suspendre / réactiver l'overlay** masque la source dans **toutes** les scènes
et coupe sa connexion au chat. Pendant une suspension, une récompense ou un
`!roulette` ne déclenche rien du tout.

Reclique pour réactiver. L'état est retenu entre deux démarrages d'OBS — si tu
retrouves un overlay muet, regarde la ligne **État** en haut du panneau.

---

## Mise à jour

- **🔎 Vérifier les mises à jour** compare ta version à celle publiée ici.
- **⬇ Installer la mise à jour** télécharge et remplace les fichiers.

Le téléchargement tourne en arrière-plan : OBS ne gèle pas. Ta configuration
(`overlay/config.local.js`) n'est jamais touchée.

> GitHub garde `version.json` en cache environ **5 minutes**. Juste après avoir
> publié une nouvelle version, *Vérifier* peut donc encore répondre « à jour » :
> c'est normal, réessaie quelques minutes plus tard.

Après une installation, recharge le script avec le bouton **⟳** de la fenêtre
*Scripts* pour prendre en compte la nouvelle version de `kikzill_roulette.lua`.

---

## Raccourcis clavier

Deux raccourcis sont disponibles dans **Paramètres → Raccourcis clavier** :

- *Kikzill Roulette : suspendre / réactiver l'overlay*
- *Kikzill Roulette : lancer un tirage de test*

Ils ne sont associés à aucune touche par défaut, à toi de choisir.

---

## Modifier les listes

Les listes vivent dans [`overlay/data/`](overlay/data/) :

- `warframes.js` — les Warframes tirables
- `weapons.js` — les armes tirables

Pour ajouter une entrée : mets le nom dans la liste **et** l'image
`Nom.webp` dans `overlay/img/warframes/` ou `overlay/img/weapons/`. Le nom doit
être identique au caractère près. Une image manquante ne casse rien : seul le nom
s'affiche.

Les visuels sont en WebP 320 px (~8 Mo au total au lieu de 72 Mo en PNG), ce qui
rend les mises à jour rapides. Pour en régénérer depuis des PNG :

```bash
python tools/convert_images.py <dossier_png> overlay/img/weapons
```

---

## En cas de problème

**Rien ne se passe quand la récompense est utilisée.**
Vérifie que le *texte de la récompense* correspond bien à ce que poste ton bot,
au caractère près. Le plus simple : regarde le message réel dans ton chat.

**Comment voir ce qui se passe ?**
Clic droit sur la source → **Interagir**, puis `F12` ouvre la console. L'overlay y
écrit tout ce qu'il fait, préfixé `[kikzill]`. Les messages du script Lua, eux,
sont dans le journal de la fenêtre *Scripts*.

**L'overlay reste vide.**
Normal au repos : il ne s'affiche que pendant un tirage. Utilise
**🎲 Tester un tirage** pour vérifier.

**Le bot n'écrit pas dans le chat.**
Token expiré (ils expirent), ou *compte du bot* vide. Régénère-le sur
[twitchapps.com/tmi](https://twitchapps.com/tmi/) et clique *Appliquer*.

---

## Structure du dépôt

```
kikzill_roulette.lua        le script à charger dans OBS (config, overlay, MAJ)
version.json                version installée, lue par l'updater
overlay/
  index.html                la page affichée par la source navigateur
  app.js                    moteur du tirage + connexion au chat Twitch
  style.css                 habillage
  config.local.js           généré par le script OBS — jamais commité
  data/                     listes des Warframes et des armes
  img/                      vignettes WebP
  vendor/tmi.min.js         client IRC Twitch
tools/
  update.ps1                vérification et installation des mises à jour
  convert_images.py         conversion PNG → WebP des vignettes
```
