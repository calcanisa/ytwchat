(function () {
  'use strict';

  var year = document.querySelector('[data-year]');
  if (year) {
    year.textContent = String(new Date().getFullYear());
  }

  var targets = Array.prototype.slice.call(document.querySelectorAll('[data-decrypt]'));
  if (!targets.length) {
    return;
  }
  if (window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
    return;
  }

  var glyphs = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=';

  function scramble(text, revealed) {
    var out = '';
    for (var i = 0; i < text.length; i++) {
      var ch = text.charAt(i);
      if (i < revealed || ch === ' ') {
        out += ch;
      } else {
        out += glyphs.charAt(Math.floor(Math.random() * glyphs.length));
      }
    }
    return out;
  }

  var items = targets.map(function (el) {
    var text = el.textContent;
    var live = document.createElement('span');
    live.className = 'sr';
    live.textContent = text;
    var shown = document.createElement('span');
    shown.setAttribute('aria-hidden', 'true');
    shown.className = 'cipher';
    shown.textContent = scramble(text, 0);
    el.textContent = '';
    el.appendChild(live);
    el.appendChild(shown);
    return { text: text, shown: shown };
  });

  var start = null;
  var delay = 500;
  var stagger = 420;
  var duration = 900;

  function frame(now) {
    if (start === null) {
      start = now;
    }
    var done = true;
    items.forEach(function (item, index) {
      var t = (now - start - delay - index * stagger) / duration;
      if (t >= 1) {
        if (item.shown.className) {
          item.shown.className = '';
          item.shown.textContent = item.text;
        }
        return;
      }
      done = false;
      var revealed = t <= 0 ? 0 : Math.floor(item.text.length * t);
      item.shown.textContent = scramble(item.text, revealed);
    });
    if (!done) {
      window.requestAnimationFrame(frame);
    }
  }

  window.requestAnimationFrame(frame);
})();
