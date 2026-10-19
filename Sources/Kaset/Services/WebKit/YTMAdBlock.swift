import Foundation

/// Strips ad payloads from YouTube Music InnerTube responses before the page sees them.
enum YTMAdBlock {
    static let script = #"""
/*
 * Aria ad-block — injected into music.youtube.com at DOCUMENT START (before the
 * page's own scripts) so the fetch hook is in place before any API call.
 *
 * Strategy: intercept InnerTube API responses and delete ad payloads
 * (`adPlacements`, `playerAds`, `adSlots`, ad renderers) so no ad is scheduled.
 *
 * SAFETY RULES (learned the hard way):
 *   - Only rebuild a Response when we ACTUALLY removed ad data. Every clean
 *     response is returned untouched — rebuilding clean queue responses with
 *     stale headers corrupts playback and makes songs auto-skip.
 *   - When we do rebuild, drop `content-length`/`content-encoding` so the body
 *     we return isn't misread as compressed/truncated.
 *   - NO seeking/auto-skipping of the <video>. That skipped real songs on
 *     false positives. Ad prevention is done purely by removing ad data.
 *
 * FRAGILITY: depends on YouTube's private response shape; no auto-updating list.
 */
(function () {
  "use strict";
  if (window.__ariaAdblock) return;
  window.__ariaAdblock = true;

  var BANNED_KEYS = [
    "adPlacements", "playerAds", "adSlots", "adBreakHeartbeatParams",
    "adEngagementPanels", "adsEngagementPanelContent", "playerAdParams"
  ];
  var AD_ITEM_KEYS = [
    "adSlotRenderer", "playerLegacyDesktopWatchAdsRenderer", "adRenderer",
    "instreamVideoAdRenderer", "mealbarPromoRenderer", "statementBannerRenderer"
  ];

  function adItemKey(v) {
    if (!v || typeof v !== "object") return null;
    for (var i = 0; i < AD_ITEM_KEYS.length; i++) {
      if (Object.prototype.hasOwnProperty.call(v, AD_ITEM_KEYS[i])) return AD_ITEM_KEYS[i];
    }
    return null;
  }

  // Recursively delete ad payloads; records what it removed in `removed`.
  function scrub(node, removed, depth) {
    if (!node || typeof node !== "object" || depth > 30) return;
    if (Array.isArray(node)) {
      for (var i = node.length - 1; i >= 0; i--) {
        var key = adItemKey(node[i]);
        if (key) { node.splice(i, 1); removed.push(key); continue; }
        scrub(node[i], removed, depth + 1);
      }
      return;
    }
    for (var b = 0; b < BANNED_KEYS.length; b++) {
      if (Object.prototype.hasOwnProperty.call(node, BANNED_KEYS[b])) {
        delete node[BANNED_KEYS[b]];
        removed.push(BANNED_KEYS[b]);
      }
    }
    for (var k in node) {
      if (Object.prototype.hasOwnProperty.call(node, k)) scrub(node[k], removed, depth + 1);
    }
  }

  function post(payload) {
    try { window.webkit.messageHandlers.aria.postMessage(payload); } catch (e) {}
  }
  function shortURL(u) {
    var q = u.indexOf("?");
    return q === -1 ? u : u.slice(0, q);
  }

  // ---- XMLHttpRequest interception -----------------------------------------
  // YouTube Music fetches the PLAYER response (which carries the ads) over XHR,
  // not fetch. We shadow the instance's responseText/response getters so that
  // when YTM reads them, it gets an ad-stripped copy. Reading at access-time
  // (rather than via a load listener) sidesteps event-ordering races with
  // YTM's own handlers. Only applied to ad-bearing endpoints.
  function shouldScrubXHR(u) {
    if (typeof u !== "string" || u.indexOf("/youtubei/v1/") === -1) return false;
    return u.indexOf("/player") !== -1 || u.indexOf("/next") !== -1 || u.indexOf("get_queue") !== -1;
  }

  function scrubTextCached(xhr, raw) {
    if (typeof raw !== "string" || raw.length === 0) return raw;
    if (xhr.__ariaRaw === raw) return xhr.__ariaOut;
    var out = raw;
    try {
      var data = JSON.parse(raw);
      var removed = [];
      scrub(data, removed, 0);
      if (removed.length) {
        out = JSON.stringify(data);
        post({ type: "adblock", how: "xhr", url: shortURL(xhr.__ariaURL || ""), removed: removed.slice(0, 10) });
      }
    } catch (e) {}
    xhr.__ariaRaw = raw; xhr.__ariaOut = out;
    return out;
  }

  try {
    var textDesc = Object.getOwnPropertyDescriptor(XMLHttpRequest.prototype, "responseText");
    var respDesc = Object.getOwnPropertyDescriptor(XMLHttpRequest.prototype, "response");
    var xopen = XMLHttpRequest.prototype.open;

    XMLHttpRequest.prototype.open = function (method, url) {
      try {
        if (shouldScrubXHR(url) && textDesc && textDesc.get && respDesc && respDesc.get) {
          this.__ariaURL = url;
          var xhr = this;
          Object.defineProperty(xhr, "responseText", {
            configurable: true,
            get: function () { return scrubTextCached(xhr, textDesc.get.call(xhr)); }
          });
          Object.defineProperty(xhr, "response", {
            configurable: true,
            get: function () {
              var rt = xhr.responseType;
              if (rt === "" || rt === "text") return scrubTextCached(xhr, respDesc.get.call(xhr));
              var val = respDesc.get.call(xhr);
              if (rt === "json" && val && typeof val === "object") {
                var removed = [];
                scrub(val, removed, 0);
                if (removed.length) post({ type: "adblock", how: "xhr-json", url: shortURL(xhr.__ariaURL || ""), removed: removed.slice(0, 10) });
              }
              return val;
            }
          });
        }
      } catch (e) {}
      return xopen.apply(this, arguments);
    };
  } catch (e) {}

  // ---- fetch hook ----------------------------------------------------------
  var TARGET = "/youtubei/v1/";
  var origFetch = window.fetch;
  if (typeof origFetch === "function") {
    window.fetch = function (input, init) {
      var p = origFetch.call(this, input, init);
      var url = "";
      try { url = (typeof input === "string") ? input : (input && input.url) || ""; } catch (e) {}
      if (url.indexOf(TARGET) === -1) return p;

      return p.then(function (res) {
        try {
          if (res.status !== 200) return res;
          var ct = (res.headers && res.headers.get("content-type")) || "";
          if (ct.indexOf("json") === -1) return res;
          return res.clone().json().then(function (data) {
            var removed = [];
            scrub(data, removed, 0);
            if (removed.length === 0) return res; // clean → untouched, zero risk
            var headers = new Headers(res.headers);
            headers.delete("content-length");
            headers.delete("content-encoding");
            post({ type: "adblock", url: shortURL(url), removed: removed.slice(0, 10) });
            return new Response(JSON.stringify(data), {
              status: 200, statusText: res.statusText, headers: headers
            });
          }).catch(function () { return res; });
        } catch (e) { return res; }
      });
    };
  }

  // ---- Cosmetic only: hide upsell nags (no playback interference) -----------
  function injectCSS() {
    var css =
      "ytmusic-mealbar-promo-renderer," +
      "ytmusic-statement-banner-renderer," +
      "ad-slot-renderer, ytmusic-ad-slot-renderer { display: none !important; }";
    var style = document.createElement("style");
    style.id = "aria-adblock-style";
    style.textContent = css;
    (document.head || document.documentElement).appendChild(style);
  }
  if (document.head || document.documentElement) injectCSS();
  else document.addEventListener("DOMContentLoaded", injectCSS, { once: true });
})();

"""#
}
