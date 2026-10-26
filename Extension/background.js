// background.js — Service Worker (Manifest V3)
// Gère la WebSocket vers le daemon Swift (ws://127.0.0.1:8765).
// Le service worker n'est PAS soumis à la CSP de la page YouTube, contrairement
// au content script. Les messages transitent entre content.js et background.js
// via chrome.runtime.

const WS_URL = "ws://127.0.0.1:8765";
const RECONNECT_BASE_DELAY_MS = 1000;
const RECONNECT_MAX_DELAY_MS = 15000;
const PING_INTERVAL_MS = 20000;

let ws = null;
let reconnectAttempts = 0;
let reconnectTimer = null;
let pingTimer = null;
let pipOwnerTabId = null;

// ─── Logging ────────────────────────────────────────────────────────────────
function log(...args) {
  console.log("[AutoPiP:bg]", ...args);
}

// ─── Connexion WebSocket avec reconnexion automatique ────────────────────────
function connectWebSocket() {
  if (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING)) {
    return;
  }
  log(`Connexion à ${WS_URL} (essai ${reconnectAttempts + 1})`);
  try {
    ws = new WebSocket(WS_URL);
  } catch (err) {
    log("Erreur création WebSocket:", err);
    scheduleReconnect();
    return;
  }

  ws.onopen = () => {
    log("WebSocket connecté au lecteur PiP.");
    reconnectAttempts = 0;
    startPing();
  };

  ws.onmessage = (event) => {
    let payload;
    try {
      payload = JSON.parse(event.data);
    } catch (err) {
      log("Message non-JSON ignoré:", event.data);
      return;
    }
    log("Message reçu du serveur:", payload);
    handleServerMessage(payload);
  };

  ws.onerror = (err) => {
    log("Erreur WebSocket:", err?.message || err);
  };

  ws.onclose = (event) => {
    log(`WebSocket fermé (code=${event?.code}).`);
    stopPing();
    ws = null;
    scheduleReconnect();
  };
}

function scheduleReconnect() {
  if (reconnectTimer) return;
  const delay = Math.min(
    RECONNECT_BASE_DELAY_MS * Math.pow(2, reconnectAttempts),
    RECONNECT_MAX_DELAY_MS
  );
  reconnectAttempts++;
  log(`Reconnexion dans ${delay} ms…`);
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connectWebSocket();
  }, delay);
}

function startPing() {
  stopPing();
  pingTimer = setInterval(() => {
    if (ws && ws.readyState === WebSocket.OPEN) {
      try {
        ws.send(JSON.stringify({ action: "PING", t: Date.now() }));
      } catch (err) {
        log("Erreur ping:", err);
      }
    }
  }, PING_INTERVAL_MS);
}

function stopPing() {
  if (pingTimer) {
    clearInterval(pingTimer);
    pingTimer = null;
  }
}

function send(payload) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    try {
      ws.send(JSON.stringify(payload));
      log("Envoyé au daemon:", payload);
      return true;
    } catch (err) {
      log("Erreur envoi:", err);
      return false;
    }
  }
  log("WebSocket non connecté — message en attente:", payload);
  return false;
}

// ─── Messages reçus du daemon Swift ──────────────────────────────────────────
function handleServerMessage(payload) {
  const action = payload?.action;
  if (action === "SYNC_TIME" || action === "NO_PIP") {
    const message = action === "SYNC_TIME"
      ? { type: "SYNC_TIME", timestamp: payload.timestamp, paused: !!payload.paused }
      : { type: "NO_PIP" };
    sendToPipOwner(message);
    pipOwnerTabId = null;
  }
}

function sendToPipOwner(message) {
  if (pipOwnerTabId == null) {
    log("Aucun onglet propriétaire du PiP — message ignoré:", message.type);
    return;
  }
  chrome.tabs.sendMessage(pipOwnerTabId, message).catch((err) => {
    log("Envoi au propriétaire du PiP impossible:", err?.message || err);
  });
}

// ─── Messages reçus du content script ────────────────────────────────────────
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || typeof message !== "object") return;

  if (message.type === "START") {
    const tabId = sender.tab?.id;
    const windowId = sender.tab?.windowId;
    chrome.tabs.query({ active: true, windowId }).then((tabs) => {
      if (tabId == null || tabs[0]?.id !== tabId) {
        log("START ignoré : onglet YouTube en arrière-plan", tabId);
        if (tabId != null) {
          chrome.tabs.sendMessage(tabId, { type: "START_REJECTED" }).catch(() => {});
        }
        sendResponse({ ok: false });
        return;
      }
      pipOwnerTabId = tabId;
      send({
        action: "START",
        videoId: message.videoId,
        timestamp: message.timestamp,
      });
      sendResponse({ ok: true });
    }).catch((err) => {
      log("START : query onglet actif impossible:", err);
      sendResponse({ ok: false });
    });
    return true;
  }

  if (message.type === "STOP") {
    const tabId = sender.tab?.id;
    if (pipOwnerTabId != null && tabId !== pipOwnerTabId) {
      log("STOP ignoré : ne vient pas de l'onglet du PiP", tabId);
      sendResponse({ ok: false });
      return false;
    }
    send({ action: "STOP" });
    sendResponse({ ok: true });
    return false;
  }

  if (message.type === "GET_WS_STATUS") {
    sendResponse({
      connected: !!(ws && ws.readyState === WebSocket.OPEN),
    });
    return false;
  }

  return false;
});

// ─── Démarrage ───────────────────────────────────────────────────────────────
chrome.runtime.onInstalled.addListener(() => {
  log("Extension installée. Démarrage du WebSocket.");
  connectWebSocket();
});

chrome.runtime.onStartup.addListener(() => {
  log("Brave a démarré. Démarrage du WebSocket.");
  connectWebSocket();
});

// Le service worker peut être réveillé à tout moment : on tente la connexion.
connectWebSocket();
