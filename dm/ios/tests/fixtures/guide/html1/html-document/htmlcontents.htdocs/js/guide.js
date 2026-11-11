// Placeholder guide's script: made up, written the way the console's guides are (see the fixture's README.md)
var guideLog = window.guideLog = [];
var log = function (s) { guideLog.push(s); };
var topic = 0;   // 0: the menu, 1 or 3: a topic shown on this page

// On the console every touch is cancelled: the page acts on onclick and the controller only
function TouchEventFunc(e) { e.preventDefault(); }
if (window.nx) {
  document.addEventListener('touchstart', TouchEventFunc, {passive: false});
  document.addEventListener('touchmove', TouchEventFunc, {passive: false});
  document.addEventListener('touchend', TouchEventFunc, {passive: false});
}

function show(n) {
  topic = n;
  var s = document.querySelectorAll('.section');
  for (var i = 0; i < s.length; i++) s[i].className = 'section' + (s[i].id === 'topic' + n ? ' is-shown' : '');
  document.getElementById('menu').style.display = n ? 'none' : '';
  document.getElementById('preview').style.display = n ? 'none' : '';
  log(n ? 'topic' + n : 'menu');
  assignButtons();
}
// The focused item's preview, set by its onfocus (the console's cursor is the focus)
function preview(n) { document.getElementById('preview').textContent = n === 9 ? 'Finish the guide' : 'Preview of topic ' + n; }
function menuSelect(n) {
  // Leaving for another page: the page fades out first, and only its load (setup) shows it again
  if (n === 2) { log('go topic2'); document.body.className = 'is-leaving'; location.href = 'topic2.html'; return; }
  if (n === 9) { log('end'); location.href = ' http://localhost/ '; return; }
  show(n);
}
function assignButtons() {
  if (!window.nx) return;
  nx.footer.setAssign('B', '', function () { if (topic) show(0); else { log('end applet'); nx.endApplet(); } });
  if (topic) {
    nx.footer.setAssign('L', '', function () { show(topic === 1 ? 3 : 1); });
    nx.footer.setAssign('R', '', function () { show(topic === 1 ? 3 : 1); });
  } else {
    nx.footer.unsetAssign('L');
    nx.footer.unsetAssign('R');
  }
}
document.onkeydown = function (e) {
  var items = Array.prototype.slice.call(document.querySelectorAll('.menu a'));
  var i = items.indexOf(document.activeElement);
  if (i < 0) return;   // the arrows move the focus from the focused item: nothing focused, nothing moves
  if (e.keyCode === 40) { e.preventDefault(); items[Math.min(items.length - 1, i + 1)].focus(); }
  else if (e.keyCode === 38) { e.preventDefault(); items[Math.max(0, i - 1)].focus(); }
};
function setup() {
  var imgs = document.querySelectorAll('img[data-src]');
  for (var i = 0; i < imgs.length; i++) imgs[i].src = imgs[i].getAttribute('data-src');
  document.body.setAttribute('data-ready', '1');
  document.body.className = '';
  log('ready');
  show(0);
}
if (window.nx) window.addEventListener('NXFirstPaintEndAfterLoad', setup);
else window.addEventListener('load', setup);
