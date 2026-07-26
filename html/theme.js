// v-ui | theme.js — included by every NUI page in the framework.
//
// A NUI page can only talk to the resource that owns it, so v-ui cannot message
// v-inventory's page directly. What it CAN do is regenerate `theme-vars.css`, which every
// page links; this script re-fetches that stylesheet when the theme changes so the new
// palette lands without anyone reopening a menu.
(function () {
  var LINK_ID = 'v-ui-vars';

  function ensureLink() {
    var l = document.getElementById(LINK_ID);
    if (!l) {
      l = document.createElement('link');
      l.id = LINK_ID;
      l.rel = 'stylesheet';
      l.href = 'https://cfx-nui-v-ui/theme-vars.css';
      document.head.appendChild(l);
    }
    return l;
  }

  // Stamp the OWNING resource onto <html> so the scoped block for this module applies.
  // A NUI page is served from the resource that owns it, so its own hostname is the name:
  //   https://cfx-nui-v-inventory/index.html  ->  v-inventory
  //   https://v-inventory/index.html          ->  v-inventory
  function stampModule() {
    var h = (location.hostname || '').replace(/^cfx-nui-/, '');
    if (h && h !== 'localhost') document.documentElement.setAttribute('data-vmod', h);
    return h;
  }

  function apply(version) {
    var l = ensureLink();
    // a new href is the only reliable way to make CEF drop a cached stylesheet
    l.href = 'https://cfx-nui-v-ui/theme-vars.css?v=' + (version || 0);
  }

  // The owning resource forwards v-ui's version to its own page.
  window.addEventListener('message', function (e) {
    var d = e.data || {};
    if (d.action === 'v-ui:theme') apply(d.version);
  });

  // A module may also declare its identity explicitly, which is useful when a page is
  // previewed outside the game: <html data-vmod="v-inventory">
  // The link is NOT created here. v-ui is optional, and on a server without it
  // `https://cfx-nui-v-ui/theme-vars.css` is a stylesheet request to a resource that does
  // not exist - one guaranteed failed fetch on every page load, for a palette nobody is
  // going to push. apply() creates it the moment a theme actually arrives, which is the
  // only moment it can be useful.
  function boot() {
    if (!document.documentElement.getAttribute('data-vmod')) stampModule();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
