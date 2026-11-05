# Brave Auto PiP

Lecteur Picture-in-Picture pour YouTube, au-dessus des autres applications macOS — y compris en plein écran et sur les autres bureaux.

Quand Brave passe en arrière-plan, la vidéo en cours quitte l’onglet et continue dans une petite fenêtre flottante. Au retour dans Brave, la lecture reprend au même endroit.

## Comment ça marche

```text
Onglet YouTube  →  extension Brave  →  WebSocket local  →  fenêtre PiP macOS
     pause              ws://127.0.0.1:8765                  youtube-nocookie
```

1. L’extension détecte que Brave perd le focus et qu’une vidéo YouTube est en lecture.
2. Elle met cette vidéo en pause et envoie l’identifiant ainsi que la position au daemon.
3. Le daemon ouvre une fenêtre sans bordure, toujours au-dessus, et charge le lecteur YouTube.
4. Quand Brave revient au premier plan, la fenêtre se ferme et l’onglet reprend à la bonne seconde.

Seul l’onglet réellement affiché est pris en compte. Un second onglet YouTube, ouvert mais sans lecture, n’est pas lancé.

## Prérequis

- macOS 12 ou plus récent
- [Brave](https://brave.com)
- Xcode ou les outils de ligne de commande Swift (`xcode-select --install`)

## Installation

### Daemon

```bash
cd MacDaemon
swift run
```

L’icône PiP apparaît dans la barre des menus. Le processus ne se place pas dans le Dock.

Une seconde copie s’arrête d’elle-même : un seul daemon peut écouter le port `8765`.

#### Lancement automatique (LaunchAgent)

Pour que le daemon tourne en permanence via le binaire release :

```bash
cd MacDaemon && swift build -c release
```

Puis installer `com.brave.pipplayer.plist` (pointant vers `.build/release/BravePiPPlayer`) dans `~/Library/LaunchAgents`, avec `RunAtLoad` et `KeepAlive` à `true`, et charger l’agent :

```bash
launchctl load ~/Library/LaunchAgents/com.brave.pipplayer.plist
```

Le daemon redémarre tout seul s’il est tué. Après un rebuild du binaire, il faut le redémarrer (`pkill -x BravePiPPlayer`) pour que la nouvelle version prenne effet.

### Extension

1. Ouvrir `brave://extensions`.
2. Activer le mode développeur.
3. Choisir **Charger l’extension non empaquetée** et sélectionner le dossier `Extension`.

Après une mise à jour de l’extension, la recharger depuis cette page.

## Utilisation

Lancer une vidéo YouTube, puis passer sur une autre application. La fenêtre PiP s’affiche.

| Action | Effet |
| --- | --- |
| Survol de la fenêtre | Affiche les contrôles : barres du PiP et chrome YouTube (titre, gros bouton pause). Tout fade après 3 secondes. |
| Barre du haut | Déplace la fenêtre. |
| Barre du bas | Pause, −10 s, +10 s, déplacement dans la vidéo. |
| Croix, en haut à droite | Ferme le PiP et laisse la vidéo en pause dans Brave. |
| Fenêtre, à côté de la croix | Ferme le PiP, ramène Brave et continue la lecture. |
| Retour sur l’onglet YouTube | Ferme le PiP et reprend la vidéo dans l’état où elle était (lecture ou pause). |
| Autre onglet Brave | Le PiP reste ouvert, au-dessus de Brave. |

Le menu de la barre des menus contient **Activer**, **Relancer** et **Quitter**.

## Détails utiles

- Le lecteur utilise `youtube-nocookie.com`. La fenêtre ne partage pas la session Brave : YouTube Premium et les extensions du navigateur n’y sont pas disponibles.
- Un script dans la fenêtre accélère et saute les publicités vidéo quand elles apparaissent.
- Le chrome YouTube (titre, gros bouton pause) fade en même temps que les barres du PiP : le daemon bascule une classe CSS sur la page, avec des durées identiques (0,18 s / 0,22 s) et `visibility: hidden` forcé en fin de fade pour qu'aucune animation YouTube ne puisse retarder la disparition.
- Aucune permission d’accessibilité n’est demandée.

## Dépannage

**Le PiP ne s’ouvre pas.** Vérifier que le daemon affiche `WebSocket listener prêt sur le port 8765`, puis recharger l’extension. Dans `brave://extensions`, la console du service worker doit indiquer `WebSocket connecté`.

**Le port est déjà pris.**

```bash
pkill -9 -x BravePiPPlayer
rmdir /tmp/bravepip-relaunch.exclusive 2>/dev/null
cd MacDaemon && swift run
```

**Les contrôles du PiP ne disparaissent pas après 3 secondes** (ou le comportement semble être resté à une ancienne version). Le daemon tourne sur un binaire obsolète : le reconstruire puis le redémarrer.

```bash
cd MacDaemon
swift build -c release
pkill -x BravePiPPlayer   # relancé aussitôt par l'agent com.brave.pipplayer
```

**Une erreur WebSocket s’affiche alors que Brave vient de démarrer.** L’extension réessaie toute seule. L’erreur disparaît une fois le daemon lancé.

## Structure

```text
Extension/          manifeste, service worker, script YouTube
MacDaemon/          application Swift (Network.framework, WKWebView)
```

Le dossier `MacDaemon/.build` est un cache de compilation local. Il n’a pas à être versionné.
