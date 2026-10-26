// content.js — Injecté sur YouTube
// Détecte le blur/focus de la fenêtre, extrait l'ID vidéo, et communique avec le
// background (service worker) qui gère la WebSocket vers le daemon Swift.
// Robuste aux navigations SPA YouTube (l'élément <video> peut être recréé).

(() => {
  "use strict";

  const TAG = "[AutoPiP:content]";
  let isSyncing = false;     // bloque les actions START pendant une resync
  let pipActive = false;    // true si on a envoyé un START et qu'on attend un SYNC_TIME
  let lastSentTimestamp = 0;
  // Reste vrai quelques instants après le passage en arrière-plan, pour
  // l'onglet qui était vraiment affiché. Les autres onglets YouTube sont
  // déjà hidden depuis longtemps et ne lancent pas de PiP.
  let foregroundUntil = document.visibilityState === "visible" ? Infinity : 0;

  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "visible") foregroundUntil = Infinity;
    else if (foregroundUntil === Infinity) foregroundUntil = Date.now() + 500;
  });

  function isForegroundTab() {
    return document.visibilityState === "visible" || Date.now() < foregroundUntil;
  }

  function log(...args) {
    console.log(TAG, ...args);
  }

  function findVideo() {
    return document.querySelector("video") || null;
  }

  function extractVideoId() {
    try {
      const url = new URL(window.location.href);
      let v = url.searchParams.get("v");
      if (v) return v;
      const path = url.pathname.split("/").filter(Boolean);
      if (path[0] === "embed" && path[1]) return path[1];
      if (path[0] === "shorts" && path[1]) return path[1];
      if (url.hostname === "youtu.be" && path[0]) return path[0];
    } catch (_) {}
    const canonical = document.querySelector('link[rel="canonical"][href]');
    if (canonical) {
      const m = canonical.getAttribute("href").match(/[?&]v=([^&]+)/);
      if (m) return m[1];
    }
    return null;
  }

  function sendToBackground(message) {
    try {
      chrome.runtime.sendMessage(message, () => {
        if (chrome.runtime.lastError) {
          log("sendMessage:", chrome.runtime.lastError.message);
        }
      });
    } catch (err) {
      log("Erreur sendMessage:", err);
    }
  }

  function onWindowBlur() {
    if (!isForegroundTab()) {
      log("Blur ignoré (onglet YouTube en arrière-plan).");
      return;
    }
    if (isSyncing || pipActive) {
      log("Blur ignoré (SYNC_TIME en cours ou PiP déjà actif).");
      return;
    }
    const video = findVideo();
    if (!video) return;
    if (video.paused) {
      log("Blur: vidéo en pause — pas de START.");
      return;
    }
    const videoId = extractVideoId();
    if (!videoId) {
      log("Blur: impossible d'extraire videoId.");
      return;
    }
    const timestamp = Math.floor(video.currentTime || 0);
    lastSentTimestamp = timestamp;
    try { video.pause(); } catch (_) {}
    pipActive = true;
    log(`Blur → START videoId=${videoId} t=${timestamp}s`);
    sendToBackground({ type: "START", videoId, timestamp });
  }

  function onWindowFocus() {
    // Ne rien faire si aucun PiP n'a été demandé depuis cet onglet.
    if (!pipActive) {
      log("Focus ignoré (aucun PiP actif depuis cet onglet).");
      return;
    }
    if (isSyncing) {
      log("Focus ignoré (SYNC_TIME en cours).");
      return;
    }
    log("Focus → STOP");
    sendToBackground({ type: "STOP" });
  }

  chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
    if (!message || typeof message !== "object") return false;
    if (message.type === "SYNC_TIME") {
      if (!pipActive) {
        log("SYNC_TIME ignoré (cet onglet n'a pas ouvert le PiP).");
        sendResponse({ ok: false });
        return false;
      }
      applySyncTime(Number(message.timestamp), !!message.paused);
      sendResponse({ ok: true });
    } else if (message.type === "START_REJECTED") {
      log("START refusé par le background : onglet pas au premier plan.");
      pipActive = false;
      isSyncing = false;
      sendResponse({ ok: true });
    } else if (message.type === "NO_PIP") {
      // Le daemon n'avait pas de fenêtre PiP ouverte : on annule l'attente.
      log("NO_PIP reçu — annulation de l'attente SYNC_TIME.");
      pipActive = false;
      sendResponse({ ok: true });
    }
    return false;
  });

  function applySyncTime(timestamp, paused) {
    const video = findVideo();
    if (!video) {
      log("SYNC_TIME: aucune <video> trouvée.");
      isSyncing = false;
      pipActive = false;
      return;
    }
    if (!Number.isFinite(timestamp)) {
      log("SYNC_TIME: timestamp invalide:", timestamp);
      pipActive = false;
      return;
    }
    isSyncing = true;
    try {
      video.currentTime = timestamp;
      log(`SYNC_TIME appliqué: currentTime=${timestamp}s paused=${paused}`);
      if (paused) {
        // YouTube relance parfois la lecture quand l'onglet redevient visible
        // ou après un seek. On maintient la pause pendant un court instant.
        const keepPaused = () => {
          try { video.pause(); } catch (_) {}
        };
        keepPaused();
        video.addEventListener("play", keepPaused);
        setTimeout(keepPaused, 50);
        setTimeout(keepPaused, 250);
        setTimeout(() => {
          video.removeEventListener("play", keepPaused);
          keepPaused();
          isSyncing = false;
          pipActive = false;
        }, 700);
        return;
      }
      const playPromise = video.play();
      if (playPromise && typeof playPromise.then === "function") {
        playPromise
          .then(() => log("Reprise de la lecture après SYNC_TIME."))
          .catch((err) => log("Reprise impossible:", err?.message || err))
          .finally(() => {
            isSyncing = false;
            pipActive = false;
          });
      } else {
        isSyncing = false;
        pipActive = false;
      }
    } catch (err) {
      log("Erreur SYNC_TIME:", err?.message || err);
      isSyncing = false;
      pipActive = false;
    }
  }

  let lastVideo = null;
  function trackVideo() {
    const video = findVideo();
    if (video === lastVideo) return;
    lastVideo = video;
    log("Nouvelle <video> détectée.");
  }

  const videoObserver = new MutationObserver(() => { trackVideo(); });

  function startObserving() {
    videoObserver.observe(document.documentElement, {
      childList: true,
      subtree: true,
    });
    trackVideo();
  }

  function hookSPANavigation() {
    const pushState = history.pushState;
    const replaceState = history.replaceState;
    history.pushState = function (...args) {
      const ret = pushState.apply(this, args);
      window.dispatchEvent(new Event("autopip:locationchange"));
      return ret;
    };
    history.replaceState = function (...args) {
      const ret = replaceState.apply(this, args);
      window.dispatchEvent(new Event("autopip:locationchange"));
      return ret;
    };
    window.addEventListener("popstate", () => {
      window.dispatchEvent(new Event("autopip:locationchange"));
    });
    window.addEventListener("autopip:locationchange", () => {
      log("Navigation SPA détectée:", window.location.href);
      lastVideo = null;
      // Navigation = changement de vidéo : on réinitialise l'état PiP.
      pipActive = false;
      isSyncing = false;
      trackVideo();
    });
  }

  function init() {
    log("Content script chargé sur YouTube.");
    window.addEventListener("blur", onWindowBlur, { passive: true });
    window.addEventListener("focus", onWindowFocus, { passive: true });
    startObserving();
    hookSPANavigation();
  }

  init();
})();
