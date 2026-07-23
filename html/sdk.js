/* ============================================================
   v-phone — app SDK
   ============================================================

   Ship an app in one HTML file. No build step, no framework, no bundler:

     <link rel="stylesheet" href="https://cfx-nui-v-phone/style.css">
     <script src="https://cfx-nui-v-phone/sdk.js"><\/script>
     (the escaped slash above is deliberate: an unescaped closing script tag here
      would end any <script> tag it was pasted into)
     <script>
       Phone.ready(function (me) {
         Phone.title('Notes');
         Phone.ui.render(
           Phone.ui.group([
             Phone.ui.row({ title: 'My number', value: me.number }),
             Phone.ui.row({ title: 'Write one', chevron: true, data: { act: 'new' } }),
           ], { header: 'Notes' })
         );
         Phone.ui.on('[data-act="new"]', 'click', function () { Phone.toast('Hello'); });
       });
     <\/script>

   Two objects are exported:

     PhoneUI   the component kit. Always defined, and it is the SAME object the
               built-in apps draw themselves with — one definition, so a
               third-party app cannot drift out of looking native.

     Phone     the bridge to the phone and the server. Only defined inside an app
               frame, because outside one there is nothing to talk to.

   Every call returns a Promise. The phone answers on the same channel it was
   asked, so an app never has to wire up its own message plumbing.
*/
(function (root) {
  'use strict';

  // ══ Escaping ═══════════════════════════════════════════════
  // Everything the kit renders goes through this. An app that interpolates a
  // player's name into a template must not be able to inject markup with it.
  const esc = (s) => String(s ?? '').replace(/[&<>"]/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

  // ══ Icons ══════════════════════════════════════════════════
  const ICONS = {
    // The iFruit mark: a fruit with a stem and one leaf. It used to be a ball with a
    // lowercase i scrawled across it, which read as a bug icon at any size.
    fruit: 'M12 8.6c-1.1-1.3-2.9-1.8-4.4-1C5.4 8.6 4.4 11.1 5 13.8c.6 2.7 2.5 5.9 4.4 6.3.9.2 1.7-.4 2.6-.4s1.7.6 2.6.4c1.9-.4 3.8-3.6 4.4-6.3.6-2.7-.4-5.2-2.6-6.2-1.5-.8-3.3-.3-4.4 1ZM12 8.6V5.4M12.5 5.5c.3-1.9 1.9-3.1 3.9-3.2.1 2-1.5 3.3-3.9 3.2Z',
    phone: 'M6.5 2.5l3.2 5-2.2 2.2a13.5 13.5 0 0 0 6.8 6.8l2.2-2.2 5 3.2-2 4.2c-8.6.5-17.4-8.3-16.9-16.9z',
    messages: 'M12 3c-5 0-9 3.4-9 7.6 0 2.4 1.3 4.5 3.3 5.9l-.9 3.9 4.2-2.2c.8.2 1.6.3 2.4.3 5 0 9-3.4 9-7.9S17 3 12 3Z',
    contacts: 'M12 3a4 4 0 1 0 0 8 4 4 0 0 0 0-8ZM4 21a8 8 0 0 1 16 0',
    bank: 'M3 10h18L12 4 3 10ZM5 10v8M10 10v8M14 10v8M19 10v8M3 20h18',
    garage: 'M3 20V9l9-5 9 5v11M7 20v-7h10v7M7 16h10',
    wallet: 'M3 7h15a2 2 0 0 1 2 2v9H3zM3 7V5h13M17 12h3v3h-3z',
    jobs: 'M4 8h16v12H4zM9 8V6a2 2 0 0 1 2-2h2a2 2 0 0 1 2 2v2M4 13h16',
    settings: 'M12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6ZM19.4 13a7.6 7.6 0 0 0 0-2l2-1.5-2-3.4-2.4 1a7.6 7.6 0 0 0-1.7-1L14.9 3H9.1l-.4 2.6a7.6 7.6 0 0 0-1.7 1l-2.4-1-2 3.4L4.6 11a7.6 7.6 0 0 0 0 2l-2 1.5 2 3.4 2.4-1a7.6 7.6 0 0 0 1.7 1L9.1 21h5.8l.4-2.6a7.6 7.6 0 0 0 1.7-1l2.4 1 2-3.4Z',
    camera: 'M4 8h3l2-3h6l2 3h3v12H4zM12 10a4 4 0 1 0 0 8 4 4 0 0 0 0-8Z',
    hangup: 'M2 11c5.6-4.6 14.4-4.6 20 0l-2.4 3.4-4.2-1.2v-2.4a13 13 0 0 0-6.8 0v2.4l-4.2 1.2z',
    answer: 'M6.5 2.5l3.2 5-2.2 2.2a13.5 13.5 0 0 0 6.8 6.8l2.2-2.2 5 3.2-2 4.2c-8.6.5-17.4-8.3-16.9-16.9z',
    mute: 'M12 4v16l-5-4H3V8h4l5-4ZM17 9l4 6M21 9l-4 6',
    speaker: 'M12 4v16l-5-4H3V8h4l5-4ZM16 9a4 4 0 0 1 0 6M18.5 6.5a8 8 0 0 1 0 11',
    keypad: 'M6 5h.01M12 5h.01M18 5h.01M6 11h.01M12 11h.01M18 11h.01M6 17h.01M12 17h.01M18 17h.01',
    add: 'M12 5v14M5 12h14',
    chevron: 'M9 4l7 8-7 8',
    send: 'M4 12l16-8-6 8 6 8z',
    del: 'M9 6h11v12H9L3 12zM17 9l-5 6M12 9l5 6',
    moon: 'M20 14A8.5 8.5 0 0 1 10 4a8.5 8.5 0 1 0 10 10Z',
    sun: 'M12 6a6 6 0 1 0 0 12 6 6 0 0 0 0-12ZM12 1v2M12 21v2M4.2 4.2l1.4 1.4M18.4 18.4l1.4 1.4M1 12h2M21 12h2M4.2 19.8l1.4-1.4M18.4 5.6l1.4-1.4',
    wall: 'M4 5h16v14H4zM4 15l4-4 3 3 4-5 5 6',
    note: 'M5 3h9l5 5v13H5zM14 3v5h5M8 12h8M8 16h6',
    star: 'M12 3l2.7 5.9 6.3.7-4.7 4.3 1.3 6.3L12 17l-5.6 3.2 1.3-6.3L3 9.6l6.3-.7z',
    map: 'M9 4L3 6v14l6-2 6 2 6-2V4l-6 2zM9 4v14M15 6v14',
    cart: 'M4 6h16l-1.5 9H6zM6 15l-1 4h13M9 21h.01M17 21h.01',
    house: 'M4 11l8-7 8 7v9H4zM10 20v-6h4v6',
    shield: 'M12 3l7 3v5c0 5-3 8-7 10-4-2-7-5-7-10V6l7-3Z',
    fuel: 'M4 21V5a2 2 0 0 1 2-2h6a2 2 0 0 1 2 2v16M3 21h12M4 11h10M17 8l3 3v7a2 2 0 0 1-4 0V9',
    wrench: 'M14 6a4 4 0 0 0-5 5L4 16l4 4 5-5a4 4 0 0 0 5-5l-3 3-2-2 3-3a4 4 0 0 0-2-2Z',
    id: 'M3 5h18v14H3zM8 11a2 2 0 1 0 0-4 2 2 0 0 0 0 4ZM5 16c.6-2 5-2 6 0M14 9h4M14 13h4',
    calc: 'M5 3h14v18H5zM8 7h8M8 11h.01M12 11h.01M16 11h.01M8 15h.01M12 15h.01M16 15h4',
    trash: 'M4 7h16M9 7V4h6v3M6 7l1 14h10l1-14M10 11v6M14 11v6',
    store: 'M4 8h16l-1.5 12h-13zM4 8l2-4h12l2 4M9 12a3 3 0 0 0 6 0',
    heart: 'M12 20s-7-4.4-7-9.4A4.6 4.6 0 0 1 12 7a4.6 4.6 0 0 1 7 3.6c0 5-7 9.4-7 9.4Z',
    check: 'M20 6L9 17l-5-5',
    folder: 'M3 6h6l2 2h10v11H3z',
    cloud: 'M7 18a4 4 0 0 1 0-8 5.5 5.5 0 0 1 10.6 1.5A3.5 3.5 0 0 1 17 18Z',
    rain: 'M7 15a4 4 0 0 1 0-8 5.5 5.5 0 0 1 10.6 1.5A3.5 3.5 0 0 1 17 15M8 18l-1 3M12 18l-1 3M16 18l-1 3',
    snow: 'M7 15a4 4 0 0 1 0-8 5.5 5.5 0 0 1 10.6 1.5A3.5 3.5 0 0 1 17 15M8 19h.01M12 20h.01M16 19h.01',
    search: 'M11 4a7 7 0 1 0 0 14 7 7 0 0 0 0-14ZM20 20l-4-4',
    sparkles: 'M12 2l1.4 4.6L18 8l-4.6 1.4L12 14l-1.4-4.6L6 8l4.6-1.4L12 2ZM19 14l.8 2.2L22 17l-2.2.8L19 20l-.8-2.2L16 17l2.2-.8L19 14ZM5 13l.8 2.2L8 16l-2.2.8L5 19l-.8-2.2L2 16l2.2-.8L5 13Z',
    bleet: 'M21 6.2c-.7.3-1.4.5-2.1.6.8-.5 1.3-1.2 1.6-2-.7.4-1.5.7-2.3.9A3.3 3.3 0 0 0 12.6 8.3c-2.6-.1-5-1.4-6.6-3.4-.9 1.5-.5 3.4 1 4.4-.6 0-1.1-.2-1.6-.4 0 1.6 1.1 3 2.7 3.3-.5.1-1 .2-1.5.1.4 1.3 1.7 2.3 3.1 2.3-1.4 1.1-3.2 1.6-5 1.4 1.5 1 3.3 1.5 5.2 1.5 6.3 0 9.8-5.3 9.6-10 .7-.5 1.2-1.1 1.6-1.8z',
    snap: 'M4 8h3l2-3h6l2 3h3v12H4zM12 10a4 4 0 1 0 0 8 4 4 0 0 0 0-8Z',
    dot: 'M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8Z',
    airplane: 'M12 3c.9 0 1.4 1 1.4 2.2v4.1l7.1 4.2v2l-7.1-2.1v4l2.1 1.6v1.6L12 19.6 8.5 20.8v-1.6l2.1-1.6v-4L3.5 15.5v-2l7.1-4.2V5.2C10.6 4 11.1 3 12 3Z',
    cell: 'M17 3h2v18h-2zM12.5 7h2v14h-2zM8 11h2v10H8zM3.5 15h2v6h-2z',
    wifi: 'M12 4a15 15 0 0 1 10.5 4.3M12 4A15 15 0 0 0 1.5 8.3M5 11.5a10 10 0 0 1 14 0M8.3 15a5 5 0 0 1 7.4 0M12 19h.01',
    bt: 'M8 6l8 6-4 3V3l4 3-8 6',
    torch: 'M9 2h6v3l-1.5 2v13h-3V7L9 5zM9.5 11h5',
    focus: 'M20 14A8.5 8.5 0 0 1 10 4a8.5 8.5 0 1 0 10 10Z',
    bell: 'M6 16V10a6 6 0 0 1 12 0v6l2 2H4zM10 20a2 2 0 0 0 4 0',
    belloff: 'M6 16V10a6 6 0 0 1 9-5M18 12v4l2 2H8M10 20a2 2 0 0 0 4 0M3 3l18 18',
    play: 'M7 4l13 8-13 8z',
    pause: 'M8 4h3v16H8zM13 4h3v16h-3z',
    xmark: 'M6 6l12 12M18 6L6 18',
    more: 'M5 12h.01M12 12h.01M19 12h.01',
    refresh: 'M20 7v5h-5M4 17v-5h5M18.3 9A7 7 0 0 0 6 6.7L4 9M5.7 15A7 7 0 0 0 18 17.3l2-2.3',
    location: 'M12 21s7-6.2 7-12A7 7 0 1 0 5 9c0 5.8 7 12 7 12ZM12 6.5a2.5 2.5 0 1 0 0 5 2.5 2.5 0 0 0 0-5Z',
    copy: 'M8 8h12v12H8zM4 4h12v4M4 4v12h4',
    warning: 'M12 3 2.5 20h19L12 3ZM12 9v5M12 17h.01',
    images: 'M8 3h10a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2ZM4 7v12a2 2 0 0 0 2 2h12M10 9a1.4 1.4 0 1 0 0 2.8 1.4 1.4 0 0 0 0-2.8ZM20 15l-4-4-6 6',
    airdrop: 'M12 20a1 1 0 0 0 .9-1.5l-.9-1.6-.9 1.6A1 1 0 0 0 12 20ZM7.5 13.5a6.4 6.4 0 0 1 9 0M4.7 10.7a10.3 10.3 0 0 1 14.6 0M12 8.5a1.6 1.6 0 1 0 0-3.2 1.6 1.6 0 0 0 0 3.2Z',
    share: 'M12 3l4 4M12 3L8 7M12 3v13M6 12H5a2 2 0 0 0-2 2v5a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-5a2 2 0 0 0-2-2h-1',
    landscape: 'M3 8a2 2 0 0 1 2-2h11a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2zM19 10l2.5 2-2.5 2M21.5 12H15',
    callout: 'M6.5 2.5l3.2 5-2.2 2.2a13.5 13.5 0 0 0 6.8 6.8l2.2-2.2 5 3.2-2 4.2c-8.6.5-17.4-8.3-16.9-16.9zM15 3h6v6M21 3l-7 7',
    callin: 'M6.5 2.5l3.2 5-2.2 2.2a13.5 13.5 0 0 0 6.8 6.8l2.2-2.2 5 3.2-2 4.2c-8.6.5-17.4-8.3-16.9-16.9zM21 3l-7 7M14 3v7h7',
    callmissed: 'M6.5 2.5l3.2 5-2.2 2.2a13.5 13.5 0 0 0 6.8 6.8l2.2-2.2 5 3.2-2 4.2c-8.6.5-17.4-8.3-16.9-16.9zM14 3l7 7M21 3l-7 7',
    voicemail: 'M7 9a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7ZM17 9a3.5 3.5 0 1 0 0 7 3.5 3.5 0 0 0 0-7ZM7 16h10',
    lockshut: 'M8 10V7a4 4 0 0 1 8 0v3M6.5 10h11A1.5 1.5 0 0 1 19 11.5v8A1.5 1.5 0 0 1 17.5 21h-11A1.5 1.5 0 0 1 5 19.5v-8A1.5 1.5 0 0 1 6.5 10ZM12 14v3',
    lockopen: 'M9 10V7a4 4 0 0 1 7.7-1.5M6.5 10h11A1.5 1.5 0 0 1 19 11.5v8A1.5 1.5 0 0 1 17.5 21h-11A1.5 1.5 0 0 1 5 19.5v-8A1.5 1.5 0 0 1 6.5 10ZM12 14v3',
    cipher: 'M12 2.5l7 3v5.8c0 4.6-2.8 7.8-7 10.2-4.2-2.4-7-5.6-7-10.2V5.5l7-3ZM9 11h6v5H9zM10 11V9a2 2 0 0 1 4 0v2',
    faceid: 'M8 3H5a2 2 0 0 0-2 2v3M16 3h3a2 2 0 0 1 2 2v3M8 21H5a2 2 0 0 1-2-2v-3M16 21h3a2 2 0 0 0 2-2v-3M9 9h.01M15 9h.01M12 9v4h-2M8.5 16c2 1.6 5 1.6 7 0',
    timer: 'M9 2h6M12 5v2M12 12l3-2M12 6a7 7 0 1 0 7 7 7 7 0 0 0-7-7Z',
    mail: 'M3 6h18v12H3zM3 7l9 6 9-6',
    reply: 'M9 5L3 11l6 6M3 11h10a8 8 0 0 1 8 8',
    // Two arrows chasing each other: a post sent round again.
    repost: 'M4 9V8a3 3 0 0 1 3-3h10l-3-3M20 15v1a3 3 0 0 1-3 3H7l3 3M17 5l3 3M7 19l-3-3',
    home: 'M4 11.2 12 4l8 7.2M6.5 10v9.2h4.2V15h2.6v4.2h4.2V10',
    star2: 'M12 3l2.7 5.9 6.3.7-4.7 4.3 1.3 6.3L12 17l-5.6 3.2 1.3-6.3L3 9.6l6.3-.7z',
  };
  const FILLED = { phone: 1, messages: 1, hangup: 1, answer: 1, send: 1, star: 1 };

  const svg = (n) => {
    const d = ICONS[n] || ICONS.dot;
    return FILLED[n]
      ? '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true" focusable="false"><path d="' + d + '"/></svg>'
      : '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" aria-hidden="true" focusable="false" ' +
        'stroke-linecap="round" stroke-linejoin="round"><path d="' + d + '"/></svg>';
  };

  // ══ Component kit ══════════════════════════════════════════
  // Every helper returns an HTML STRING. An app is a template, not a component
  // tree, because somebody writing their first app should not have to learn a
  // framework before they can draw a list.
  const UI = {
    esc: esc,
    svg: svg,
    icons: ICONS,

    /** A grouped, inset list. `rows` is an array of UI.row() strings. */
    group: function (rows, opts) {
      const o = opts || {};
      return (o.header ? '<div class="grouphead">' + esc(o.header) + '</div>' : '') +
        '<div class="group">' + (Array.isArray(rows) ? rows.join('') : rows) + '</div>' +
        (o.footer ? '<div class="groupfoot">' + esc(o.footer) + '</div>' : '');
    },

    /**
     * One row. Everything is optional except `title`.
     *   icon / avatar   leading tile, or a circle with the first letter
     *   subtitle        second line
     *   value           trailing text; `tone: 'pos' | 'neg'`, `mono: true`
     *   badge / time    trailing pill or timestamp
     *   toggle          an iOS switch (true / false)
     *   chevron         the disclosure arrow
     *   data            { k: v } becomes data-k="v", for your click handler
     */
    row: function (o) {
      const lead = o.appicon
        ? UI.appIcon(o.appicon, 'appx')
        : o.icon
          ? '<span class="ricon"' + (o.tint ? ' style="background:' + esc(o.tint) + '"' : '') + '>' + svg(o.icon) + '</span>'
          : (o.avatar ? '<span class="rav">' + esc(String(o.avatar).slice(0, 1).toUpperCase()) + '</span>' : '');
      const tail =
        (o.badge ? '<span class="rbadge">' + esc(o.badge) + '</span>' : '') +
        (o.time ? '<span class="rtime">' + esc(o.time) + '</span>' : '') +
        (o.value !== undefined ? '<span class="rval ' + (o.tone || '') + ' ' + (o.mono ? 'num' : '') + '">' + esc(o.value) + '</span>' : '') +
        (o.toggle !== undefined ? '<span class="sw ' + (o.toggle ? 'on' : '') + '"><i></i></span>' : '') +
        (o.chevron ? '<span class="rchev">' + svg('chevron') + '</span>' : '');
      let attrs = '';
      const data = o.data || {};
      for (const k in data) attrs += ' data-' + k + '="' + esc(data[k]) + '"';
      if (o.toggle !== undefined) {
        attrs += ' role="switch" aria-checked="' + (o.toggle ? 'true' : 'false') + '"';
      }
      return '<button class="row ' + (lead ? 'lead' : '') + '" type="button"' + attrs + '>' + lead +
        '<span class="rmain"><span class="rt">' + esc(o.title) + '</span>' +
        (o.subtitle ? '<span class="rs">' + esc(o.subtitle) + '</span>' : '') +
        '</span>' + tail + '</button>';
    },

    /**
     * A distinctive app summary. It is intentionally generic enough for built-in and
     * drop-in apps: the active app supplies the colour through the phone shell.
     */
    hero: function (o) {
      o = o || {};
      const lead = o.appicon
        ? UI.appIcon(o.appicon, 'heroicon')
        : (o.icon ? '<span class="heroicon ricon">' + svg(o.icon) + '</span>' : '');
      return '<section class="apphero">' +
        '<div class="herohead">' + lead +
          '<div class="herocopy">' +
            (o.eyebrow ? '<div class="heroeyebrow">' + esc(o.eyebrow) + '</div>' : '') +
            (o.title ? '<div class="herotitle">' + esc(o.title) + '</div>' : '') +
          '</div>' +
        '</div>' +
        (o.value !== undefined ? '<div class="herovalue">' + esc(o.value) + '</div>' : '') +
        (o.subtitle ? '<div class="herosub">' + esc(o.subtitle) + '</div>' : '') +
      '</section>';
    },

    bigNumber: function (label, value, sub) {
      return '<div class="bignum"><div class="bl">' + esc(label) + '</div>' +
        '<div class="bv">' + esc(value) + '</div>' +
        (sub ? '<div class="bs">' + esc(sub) + '</div>' : '') + '</div>';
    },

    /** style: '' (accent) | 'tinted' | 'plain' | 'destructive' */
    button: function (label, id, style) {
      return '<button class="bigbtn ' + (style || '') + '" id="' + esc(id) + '" type="button">' +
        esc(label) + '</button>';
    },

    field: function (id, placeholder, value, attrs) {
      return '<input class="field" id="' + esc(id) + '" placeholder="' + esc(placeholder) +
        '" aria-label="' + esc(placeholder) + '" value="' + esc(value || '') + '" ' + (attrs || '') + ' />';
    },

    empty: function (text, icon) {
      return '<div class="empty" role="status">' + (icon ? svg(icon) : '') + '<div>' + esc(text) + '</div></div>';
    },

    /** Replace the app body. Inside a frame this is the document body. */
    render: function (html) {
      const host = document.getElementById('appbody') || document.body;
      host.innerHTML = html;
      return host;
    },

    /** Delegate an event to everything matching a selector, now and after a re-render. */
    on: function (selector, event, handler) {
      const host = document.getElementById('appbody') || document.body;
      host.addEventListener(event, function (e) {
        const el = e.target.closest ? e.target.closest(selector) : null;
        if (el && host.contains(el)) handler(e, el);
      });
    },

    /** A free-form Clear Glass card. */
    card: function (content, opts) {
      const o = opts || {};
      const title = o.title ? '<div class="uicard-title">' + esc(o.title) + '</div>' : '';
      const subtitle = o.subtitle ? '<div class="uicard-subtitle">' + esc(o.subtitle) + '</div>' : '';
      return '<section class="uicard ' + esc(o.tone || '') + '">' + title + subtitle +
        '<div class="uicard-body">' + (content || '') + '</div></section>';
    },

    /** Responsive tiles; pass UI.tile() strings. */
    grid: function (items, opts) {
      const o = opts || {};
      return '<div class="uigrid" style="--ui-cols:' + Math.max(1, Math.min(4, Number(o.columns) || 2)) + '">' +
        (Array.isArray(items) ? items.join('') : (items || '')) + '</div>';
    },

    tile: function (o) {
      o = o || {};
      let attrs = '';
      const data = o.data || {};
      for (const key in data) attrs += ' data-' + key + '="' + esc(data[key]) + '"';
      return '<button class="uitile" type="button"' + attrs + '>' +
        (o.icon ? '<span class="uitile-icon">' + svg(o.icon) + '</span>' : '') +
        '<span class="uitile-title">' + esc(o.title || '') + '</span>' +
        (o.value !== undefined ? '<strong>' + esc(o.value) + '</strong>' : '') +
        (o.subtitle ? '<small>' + esc(o.subtitle) + '</small>' : '') + '</button>';
    },

    tabs: function (items, current, id) {
      return '<div class="seg uitabs" id="' + esc(id || '') + '" role="tablist">' +
        (items || []).map(function (item) {
          return '<button type="button" role="tab" aria-selected="' + (item.id === current) +
            '" class="' + (item.id === current ? 'on' : '') + '" data-tab="' + esc(item.id) + '">' +
            (item.icon ? svg(item.icon) : '') + '<span>' + esc(item.label) + '</span></button>';
        }).join('') + '</div>';
    },

    search: function (id, placeholder, value) {
      return '<label class="uisearch">' + svg('search') +
        '<input id="' + esc(id) + '" type="search" value="' + esc(value || '') +
        '" placeholder="' + esc(placeholder || 'Search') + '" aria-label="' +
        esc(placeholder || 'Search') + '"></label>';
    },

    textarea: function (id, placeholder, value, attrs) {
      return '<textarea class="field uitextarea" id="' + esc(id) + '" placeholder="' +
        esc(placeholder || '') + '" aria-label="' + esc(placeholder || '') + '" ' +
        (attrs || '') + '>' + esc(value || '') + '</textarea>';
    },

    progress: function (value, max, label) {
      const total = Math.max(1, Number(max) || 100);
      const current = Math.max(0, Math.min(total, Number(value) || 0));
      const percent = Math.round((current / total) * 100);
      return '<div class="uiprogress" role="progressbar" aria-valuemin="0" aria-valuemax="' +
        total + '" aria-valuenow="' + current + '">' +
        (label ? '<div><span>' + esc(label) + '</span><b>' + percent + '%</b></div>' : '') +
        '<i><span style="width:' + percent + '%"></span></i></div>';
    },

    chip: function (label, tone, data) {
      let attrs = '';
      for (const key in (data || {})) attrs += ' data-' + key + '="' + esc(data[key]) + '"';
      return '<button class="uichip ' + esc(tone || '') + '" type="button"' + attrs + '>' +
        esc(label) + '</button>';
    },

    notice: function (o) {
      o = o || {};
      return '<div class="uinotice ' + esc(o.tone || '') + '">' +
        (o.icon ? '<span>' + svg(o.icon) + '</span>' : '') +
        '<div><b>' + esc(o.title || '') + '</b>' +
        (o.body ? '<small>' + esc(o.body) + '</small>' : '') + '</div></div>';
    },

    spinner: function (label) {
      return '<div class="uispinner" role="status"><i></i><span>' + esc(label || 'Loading') + '</span></div>';
    },

    skeleton: function (lines) {
      return '<div class="uiskeleton" aria-hidden="true">' +
        Array.from({ length: Math.max(1, Math.min(8, Number(lines) || 3)) }, function (_, index) {
          return '<i style="width:' + (index % 3 === 2 ? 62 : (index % 2 ? 82 : 96)) + '%"></i>';
        }).join('') + '</div>';
    },
  };

  // ══ App icon tiles ═══════════════════════════════════════════
  // An iOS app icon is a vivid gradient squircle with a FILLED white glyph. The
  // stroke set above is for rows and buttons; drawing it on a flat tint is what
  // made the home screen read as a web page rather than a phone. One table, so a
  // third-party app gets the same treatment just by naming an icon.
  const G = {
    // Envelope: the flap and the body as one solid shape, centred on the box.
    mail: 'M3.2 7.6a2.6 2.6 0 0 1 2.6-2.4h12.4a2.6 2.6 0 0 1 2.6 2.4L12 13.2 3.2 7.6zm0 2.2 8.3 5.3a1 1 0 0 0 1 0l8.3-5.3v6.6a2.6 2.6 0 0 1-2.6 2.6H5.8a2.6 2.6 0 0 1-2.6-2.6V9.8z',
    // Photos: two stacked frames with a sun and a ridge, solid.
    images: 'M8.4 3.2h10A2.4 2.4 0 0 1 20.8 5.6v9.2a2.4 2.4 0 0 1-2.4 2.4h-10A2.4 2.4 0 0 1 6 14.8V5.6a2.4 2.4 0 0 1 2.4-2.4zm2 3.1a1.5 1.5 0 1 0 0 3 1.5 1.5 0 0 0 0-3zm8.4 8.5v-2.3l-3-2.9-4.2 4.2-1.6-1.4-1.6 1.5v.9a.9.9 0 0 0 .9.9h8.6a.9.9 0 0 0 .9-.9zM4.2 7.4v9.9a3.5 3.5 0 0 0 3.5 3.5h9.9a2.4 2.4 0 0 1-2.2 1.4H7.4A3.6 3.6 0 0 1 3.8 18.6V9.6a2.4 2.4 0 0 1 .4-2.2z',

    phone: 'M20 15.6c-1.2 0-2.4-.2-3.5-.6a1 1 0 0 0-1 .3l-2.2 2.2a15.2 15.2 0 0 1-6.6-6.6L8.9 8.7a1 1 0 0 0 .2-1A11.4 11.4 0 0 1 8.5 4.2a1 1 0 0 0-1-1H4a1 1 0 0 0-1 1 17 17 0 0 0 17 17 1 1 0 0 0 1-1v-3.5a1 1 0 0 0-1-1.1z',
    messages: 'M12 3C6.5 3 2 6.9 2 11.7c0 2.6 1.3 5 3.4 6.6-.1 1.1-.6 2.3-1.6 3.3-.2.2 0 .7.4.7 1.9-.1 3.6-.9 5-1.8.9.2 1.8.3 2.8.3 5.5 0 10-3.9 10-8.8S17.5 3 12 3z',
    contacts: 'M12 11.5a4.25 4.25 0 1 0 0-8.5 4.25 4.25 0 0 0 0 8.5zm0 2.1c-4.6 0-8.3 2.3-8.3 5.2v1a1 1 0 0 0 1 1h14.6a1 1 0 0 0 1-1v-1c0-2.9-3.7-5.2-8.3-5.2z',
    bank: 'M12 2 2.5 7.6v1.9h19V7.6L12 2zM4 11h3v6.5H4V11zm6.5 0h3v6.5h-3V11zm6.5 0h3v6.5h-3V11zM3 19.5h18V22H3v-2.5z',
    garage: 'M6.3 6.6A2.4 2.4 0 0 1 8.6 5h6.8a2.4 2.4 0 0 1 2.3 1.6l1.3 3.5c.9.3 1.5 1.2 1.5 2.1v5.3a1 1 0 0 1-1 1h-1a1 1 0 0 1-1-1v-.9h-11v.9a1 1 0 0 1-1 1h-1a1 1 0 0 1-1-1v-5.3c0-1 .6-1.8 1.5-2.1l1.3-3.5zM8 7.2l-1 2.8h10l-1-2.8a.9.9 0 0 0-.9-.6H8.9a.9.9 0 0 0-.9.6zM7.1 14.7a1.3 1.3 0 1 0 0-2.6 1.3 1.3 0 0 0 0 2.6zm9.8 0a1.3 1.3 0 1 0 0-2.6 1.3 1.3 0 0 0 0 2.6z',
    wallet: 'M4 5.5A2.5 2.5 0 0 1 6.5 3h11A2.5 2.5 0 0 1 20 5.5V7H6.2a.85.85 0 0 0 0 1.7H21a1 1 0 0 1 1 1v8.8a2.5 2.5 0 0 1-2.5 2.5h-13A2.5 2.5 0 0 1 4 18.5v-13zm12.8 10.2a1.45 1.45 0 1 0 0-2.9 1.45 1.45 0 0 0 0 2.9z',
    jobs: 'M9.5 3h5A1.5 1.5 0 0 1 16 4.5V6h3.5A1.5 1.5 0 0 1 21 7.5V11H3V7.5A1.5 1.5 0 0 1 4.5 6H8V4.5A1.5 1.5 0 0 1 9.5 3zm.5 3h4V4.8h-4V6zM3 12.5h7v1.8h4v-1.8h7v6a2.5 2.5 0 0 1-2.5 2.5h-13A2.5 2.5 0 0 1 3 18.5v-6z',
    map: 'M20.7 3.3a.9.9 0 0 1 .2 1L13.6 21a.9.9 0 0 1-1.7-.1l-1.8-6.1-6.1-1.8A.9.9 0 0 1 4 11.3L19.7 3.1a.9.9 0 0 1 1 .2z',
    music: 'M19.7 3.1a1 1 0 0 1 .8 1v11.2a3.1 3.1 0 1 1-1.8-2.8V7.4l-8.4 1.9v8.4a3.1 3.1 0 1 1-1.8-2.8V6.6a1 1 0 0 1 .8-1l10.4-2.5z',
    house: 'M11.35 3.5a1 1 0 0 1 1.3 0l8.2 7.1a.8.8 0 0 1-.55 1.4H19v7.5a1.5 1.5 0 0 1-1.5 1.5H14v-6h-4v6H6.5A1.5 1.5 0 0 1 5 19.5V12H3.7a.8.8 0 0 1-.55-1.4l8.2-7.1z',
    shield: 'M12 2.3 19.5 5v6.1c0 4.9-3.2 8.5-7.5 10.6C7.7 19.6 4.5 16 4.5 11.1V5L12 2.3z',
    calc: 'M6.5 2h11A2.5 2.5 0 0 1 20 4.5v15a2.5 2.5 0 0 1-2.5 2.5h-11A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2zM7 5v3.4h10V5H7zm0 6v2.2h2.6V11H7zm3.7 0v2.2h2.6V11h-2.6zm3.7 0v2.2H17V11h-2.6zM7 16v2.2h2.6V16H7zm3.7 0v2.2h2.6V16h-2.6zm3.7 0v2.2H17V16h-2.6z',
    heart: 'M12 20.7C7.1 17.2 3.5 14 3.5 10.2 3.5 7.6 5.5 5.6 8 5.6c1.5 0 3 .7 4 2 1-1.3 2.5-2 4-2 2.5 0 4.5 2 4.5 4.6 0 3.8-3.6 7-8.5 10.5z',
    check: 'M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zm-1.3 14.3-4-4 1.7-1.7 2.3 2.3 5-5 1.7 1.7-6.7 6.7z',
    camera: 'M9.2 3.8a1.8 1.8 0 0 0-1.5.8l-.9 1.3H4.5A2.5 2.5 0 0 0 2 8.4v9.2a2.5 2.5 0 0 0 2.5 2.5h15a2.5 2.5 0 0 0 2.5-2.5V8.4a2.5 2.5 0 0 0-2.5-2.5h-2.3l-.9-1.3a1.8 1.8 0 0 0-1.5-.8H9.2zM12 8.6a4.5 4.5 0 1 1 0 9 4.5 4.5 0 0 1 0-9zm0 1.8a2.7 2.7 0 1 0 0 5.4 2.7 2.7 0 0 0 0-5.4z',
    store: 'M8.2 8V7a3.8 3.8 0 1 1 7.6 0v1h2.7a1 1 0 0 1 1 .93l-.75 10.5A2.4 2.4 0 0 1 16.36 21H7.64a2.4 2.4 0 0 1-2.39-1.57L4.5 8.93A1 1 0 0 1 5.5 8h2.7zm1.8 0h4V7a2 2 0 1 0-4 0v1z',
    settings: 'M13.9 2.2l.4 2.4a7.6 7.6 0 0 1 2 1.2l2.3-.9 1.9 3.3-1.9 1.6a7.6 7.6 0 0 1 0 2.4l1.9 1.6-1.9 3.3-2.3-.9a7.6 7.6 0 0 1-2 1.2l-.4 2.4h-3.8l-.4-2.4a7.6 7.6 0 0 1-2-1.2l-2.3.9-1.9-3.3 1.9-1.6a7.6 7.6 0 0 1 0-2.4L3.5 8.2l1.9-3.3 2.3.9a7.6 7.6 0 0 1 2-1.2l.4-2.4h3.8zM12 8.6a3.4 3.4 0 1 0 0 6.8 3.4 3.4 0 0 0 0-6.8z',
    note: 'M6.8 12.2h10.4v1.7H6.8zM6.8 16.1h7.2v1.7H6.8z',
    cipher: 'M12 2.2 20 5.4v6.1c0 5-3.2 8.4-8 10.5-4.8-2.1-8-5.5-8-10.5V5.4L12 2.2zm0 5.1A2.7 2.7 0 0 0 9.3 10v1H8.2v5.8h7.6V11h-1.1v-1A2.7 2.7 0 0 0 12 7.3zm0 1.6c.7 0 1.2.5 1.2 1.2v.9h-2.4v-.9c0-.7.5-1.2 1.2-1.2z',
  };
  const GREEN = 'linear-gradient(180deg,#67E585,#0CBE3C)';
  const GREY = 'linear-gradient(180deg,#9DA0A6,#606268)';
  const TILES = {
    phone: { bg: GREEN, d: G.phone },
    messages: { bg: GREEN, d: G.messages },
    contacts: { bg: GREY, d: G.contacts },
    bank: { bg: 'linear-gradient(180deg,#2ECC71,#0B8F43)', d: G.bank },
    garage: { bg: 'linear-gradient(180deg,#54B9FF,#0A63D6)', d: G.garage },
    wallet: { bg: 'linear-gradient(180deg,#3A3A3C,#141416)', d: G.wallet },
    jobs: { bg: 'linear-gradient(180deg,#7D7AFF,#4B48D6)', d: G.jobs },
    map: { bg: 'linear-gradient(135deg,#A5E8B8 0%,#F2F7F4 48%,#A9D3FF 100%)', d: G.map, fill: '#0A84FF' },
    music: { bg: 'linear-gradient(180deg,#FB5C74,#F5233B)', d: G.music },
    house: { bg: 'linear-gradient(180deg,#49C6D8,#0E8FA6)', d: G.house },
    shield: { bg: 'linear-gradient(180deg,#3C82F6,#0A48C4)', d: G.shield },
    calc: { bg: 'linear-gradient(180deg,#3A3A3C,#141416)', d: G.calc, fill: '#FF9F0A' },
    heart: { bg: '#FFFFFF', d: G.heart, fill: '#FF2D55' },
    check: { bg: '#FFFFFF', d: G.check, fill: '#FF9500' },
    camera: { bg: 'linear-gradient(180deg,#8E8E93,#3A3A3C)', d: G.camera },
    store: { bg: 'linear-gradient(180deg,#31A5FF,#0A6CFF)', d: G.store },
    settings: { bg: GREY, d: G.settings },
    note: { bg: 'linear-gradient(180deg,#FFD44D 0%,#FFD44D 24%,#FFFFFF 24%)', d: G.note, fill: '#C2C3C8' },
    bleet: { bg: 'linear-gradient(180deg,#5BC9F8,#1D9BF0)',
      d: 'M21 6.2c-.7.3-1.4.5-2.1.6.8-.5 1.3-1.2 1.6-2-.7.4-1.5.7-2.3.9A3.3 3.3 0 0 0 12.6 8.3c-2.6-.1-5-1.4-6.6-3.4-.9 1.5-.5 3.4 1 4.4-.6 0-1.1-.2-1.6-.4 0 1.6 1.1 3 2.7 3.3-.5.1-1 .2-1.5.1.4 1.3 1.7 2.3 3.1 2.3-1.4 1.1-3.2 1.6-5 1.4 1.5 1 3.3 1.5 5.2 1.5 6.3 0 9.8-5.3 9.6-10 .7-.5 1.2-1.1 1.6-1.8z' },
    snap: { bg: 'linear-gradient(180deg,#63D2FF,#0A84D6)', d: G.camera },
    hush: { bg: 'linear-gradient(180deg,#FF5E9C,#FF2D55)', d: G.heart },
    cipher: { bg: 'radial-gradient(circle at 28% 16%,#7CF7D4 0%,#14B89A 28%,#073B46 72%,#04161D 100%)', d: G.cipher },
    mail: { bg: 'linear-gradient(180deg,#5AC8FA,#0A63D6)', d: G.mail, fill: '#fff' },
    images: { bg: 'linear-gradient(135deg,#FF3B30 0%,#FF9500 20%,#FFCC00 40%,#34C759 60%,#0A84FF 80%,#5E5CE6 100%)', d: G.images, fill: '#fff' },
  };

  /** The coloured app tile. `cls` adds context classes ('appx' inside a row). */
  UI.appIcon = function (name, cls) {
    const t = TILES[name];
    const open = '<span class="ic ' + (cls || '') + '" aria-hidden="true" style="background:' +
      (t ? t.bg : GREY) + '">';
    if (!t) return open + svg(name) + '</span>';
    return open + '<svg viewBox="0 0 24 24" fill="' + (t.fill || '#fff') + '"><path d="' +
      t.d + '"/></svg></span>';
  };

  root.PhoneUI = UI;

  // ══ Bridge ═════════════════════════════════════════════════
  // Only inside an app frame. Outside one, `Phone` is deliberately undefined
  // rather than a stub that silently does nothing.
  if (root.parent === root) return;

  let seq = 0;
  const pending = {};
  const listeners = {};
  let context = null;

  function dispatch(name, payload) {
    (listeners[name] || []).slice().forEach(function (handler) {
      try { handler(payload); } catch (error) { setTimeout(function () { throw error; }, 0); }
    });
  }

  root.addEventListener('message', function (e) {
    // A sandboxed app has an opaque origin, so source identity is the reliable boundary.
    // Only the phone window that owns this frame may resolve its requests.
    if (e.source !== root.parent) return;
    const d = e.data || {};
    if (d.__phone === 'event') {
      if (d.name === 'theme' && document.body) {
        document.body.classList.toggle('dark', d.payload && d.payload.dark === true);
      }
      dispatch(d.name, d.payload || {});
      dispatch('*', { name: d.name, payload: d.payload || {} });
      return;
    }
    if (d.__phone !== 'reply' || !pending[d.id]) return;
    const request = pending[d.id];
    delete pending[d.id];
    clearTimeout(request.timer);
    request.resolve(d.payload);
  });

  function send(op, data) {
    return new Promise(function (resolve) {
      const id = ++seq;
      // A phone that went away must not leave the app waiting for ever.
      const timer = setTimeout(function () {
        if (pending[id]) { delete pending[id]; resolve({ error: 'timeout' }); }
      }, 10000);
      pending[id] = { resolve: resolve, timer: timer };
      root.parent.postMessage({ __phone: 'sdk', id: id, op: op, data: data || {} }, '*');
    });
  }

  const Phone = {
    ui: UI,
    version: '2.0.0',

    /** Runs once the phone has answered with who this player is. */
    ready: function (fn) {
      send('me').then(function (me) {
        document.body.classList.add('inframe');
        context = me || {};
        document.body.classList.toggle('dark', context.dark === true);
        fn(context);
        dispatch('ready', context);
      });
    },

    context: function () { return context || {}; },
    can: function (permission) {
      const allowed = (context && context.permissions) || [];
      return !allowed.length || allowed.indexOf(permission) !== -1;
    },

    on: function (name, handler) {
      if (typeof handler !== 'function') return function () {};
      (listeners[name] = listeners[name] || []).push(handler);
      return function () { Phone.off(name, handler); };
    },
    once: function (name, handler) {
      const stop = Phone.on(name, function (payload) { stop(); handler(payload); });
      return stop;
    },
    off: function (name, handler) {
      if (!listeners[name]) return;
      listeners[name] = listeners[name].filter(function (entry) { return entry !== handler; });
    },

    /** The title drawn in the phone's navigation bar. */
    title: function (text) { return send('title', { title: text }); },
    close: function () { return send('close'); },
    navigation: {
      action: function (label, icon, handler) {
        if (typeof handler === 'function') {
          listeners.navigation = [handler];
        }
        return send('navAction', { label: label, icon: icon });
      },
      clear: function () {
        listeners.navigation = [];
        return send('navAction', {});
      },
    },

    /** A transient message at the bottom of the screen. */
    toast: function (text) { return send('toast', { text: text }); },

    /** A banner at the top, and an entry in the lock-screen stack. */
    notify: function (title, body) { return send('notify', { title: title, body: body }); },

    /** The red count on this app's home-screen icon. 0 clears it. */
    badge: function (count) { return send('badge', { count: count }); },

    /**
     * Call one of YOUR OWN server callbacks.
     *
     *   Phone.request('save', { text })   ->  V.Callback('notes:save', ...)
     *
     * The full name is composed in Lua as `<yourAppId>:<method>` and the app id
     * comes from the phone, not from this message. An app therefore cannot reach
     * `v-banking:withdraw` by asking for it: there is no way to spell it. If your
     * app needs another module, call that module from your own server callback,
     * where you can check whatever you like first.
     */
    request: function (method, data) { return send('request', { method: method, payload: data }); },

    /** Fire one of your own server events, named `<yourAppId>:<event>`. */
    emit: function (event, data) { return send('emit', { event: event, payload: data }); },

    /** Per app, per character, persisted server-side. */
    storage: {
      get: function (key) { return send('storage', { op: 'get', key: key }); },
      set: function (key, value) { return send('storage', { op: 'set', key: key, value: value }); },
      all: function () { return send('storage', { op: 'all' }); },
      remove: function (key) { return send('storage', { op: 'remove', key: key }); },
      clear: function () { return send('storage', { op: 'clear' }); },
      getJSON: function (key, fallback) {
        return send('storage', { op: 'get', key: key }).then(function (result) {
          if (!result || result.value == null || result.value === '') return fallback;
          try { return JSON.parse(result.value); } catch { return fallback; }
        });
      },
      setJSON: function (key, value) {
        return send('storage', { op: 'set', key: key, value: value });
      },
    },

    /** The player's own contact list, read only. */
    contacts: function () { return send('contacts'); },
    photos: function () { return send('photos'); },
    pick: {
      contact: function (options) { return send('picker', { kind: 'contact', options: options || {} }); },
      photo: function (options) { return send('picker', { kind: 'photo', options: options || {} }); },
    },

    location: function () { return send('location'); },
    waypoint: function (x, y, label) {
      return send('waypoint', { x: x, y: y, label: label });
    },
    open: function (app, data) { return send('open', { app: app, data: data || {} }); },
    share: function (payload) { return send('share', payload || {}); },
    confirm: function (options) { return send('confirm', options || {}); },
    actions: function (options) { return send('actions', options || {}); },
    haptic: function (style) { return send('haptic', { style: style || 'light' }); },

    /** Send a message as the player. Goes through the same path the Messages app uses. */
    message: function (number, body) { return send('message', { number: number, body: body }); },

    /** Start a call. Routed and validated by the server, exactly like the dialler. */
    call: function (number) { return send('call', { number: number }); },
  };

  /**
   * Tiny optional runtime for one-file apps. It owns state, error/loading views and
   * delegates data-action clicks, while the app remains plain HTML and JavaScript.
   */
  Phone.mount = function (options) {
    const config = options || {};
    const host = document.getElementById(config.host || 'app') ||
      document.getElementById('appbody') || document.body;
    let state = Object.assign({}, config.state || {});
    let appContext = {};
    let busy = false;

    function paint() {
      try {
        host.innerHTML = config.render
          ? config.render({ state: state, context: appContext, ui: UI, busy: busy })
          : '';
      } catch (error) {
        host.innerHTML = UI.notice({
          icon: 'warning', tone: 'error', title: 'Application error',
          body: error && error.message ? error.message : String(error),
        });
      }
    }

    const app = {
      getState: function () { return state; },
      setState: function (patch) {
        state = Object.assign({}, state, typeof patch === 'function' ? patch(state) : patch);
        paint();
        return state;
      },
      render: paint,
      run: function (task) {
        busy = true; paint();
        return Promise.resolve().then(task).finally(function () { busy = false; paint(); });
      },
    };

    host.addEventListener('click', function (event) {
      const target = event.target.closest && event.target.closest('[data-action]');
      if (!target || !host.contains(target)) return;
      const handler = config.actions && config.actions[target.dataset.action];
      if (handler) handler({ event: event, target: target, app: app, state: state, context: appContext });
    });

    Phone.ready(function (ctx) {
      appContext = ctx;
      if (config.title) Phone.title(config.title);
      Promise.resolve(config.load ? config.load({ app: app, context: ctx, ui: UI }) : null)
        .then(function (initial) {
          if (initial && typeof initial === 'object') state = Object.assign({}, state, initial);
          paint();
        })
        .catch(function (error) {
          host.innerHTML = UI.notice({
            icon: 'warning', tone: 'error', title: 'Unable to load',
            body: error && error.message ? error.message : String(error),
          });
        });
    });
    Phone.on('resume', function () {
      if (config.resume) config.resume({ app: app, context: appContext });
    });
    Phone.on('refresh', function () {
      if (config.refresh) config.refresh({ app: app, context: appContext });
      else paint();
    });
    return app;
  };

  root.iFruitAppKit = { version: Phone.version, UI: UI, mount: Phone.mount };

  root.Phone = Phone;
})(window);
