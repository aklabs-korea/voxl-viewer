// Scripts the app adds to voxl's page. They only watch the page and call into its own paths; the
// page alone sends voxl's commands, so held keys and buttons have one owner (voxl's keyboard.ts and
// pointer.ts).

enum Page {
    /// Tells the app when the page connects (hello), when its picture arrives and how it plays
    /// (voxl's once-a-second stats), and the AudioContext's state; and gives the app three calls:
    /// release every held key (the window-blur voxl already maps to release-all), show or hide the
    /// iPhone keyboard while #kbd keeps the focus, and set the audio session's type.
    static let watch = """
    (() => {
      const post = (m) => window.webkit.messageHandlers.viewer.postMessage(m);
      let picture = false;
      const seen = () => { if (!picture) { picture = true; post({ t: 'picture' }); } };
      addEventListener('playing', seen, true);
      const W = window.Worker;
      // Test builds: what the page sends voxl, for the test log. A key's letter is never kept.
      const trace = (d) => {
        if (/^k,/.test(d)) { const [, ks, down] = d.split(','); return +ks >= 0xff00 && +ks <= 0xffff ? d : `k,key,${down}`; }
        return /^(m|b|sp|r|v|au|cs),/.test(d) || d === 'r' ? d : d.split(',')[0];
      };
      if (W) window.Worker = class extends W {
        constructor(...args) {
          super(...args);
          if (window.voxlTrace) {
            const send = this.postMessage.bind(this);
            this.postMessage = (m, t) => {
              if (m && m.t === 'send' && typeof m.d === 'string' && !/^(a|po),/.test(m.d)) post({ t: 'sent', d: trace(m.d) });
              return t ? send(m, t) : send(m);
            };
          }
          this.addEventListener('message', (e) => {
            const m = e.data || {};
            if (m.t === 'hello') post({ t: 'hello', w: m.w, h: m.h, os: m.os || '', readOnly: !!m.readOnly });
            else if (m.t === 'status') post({ t: 'status', s: String(m.s) });
            else if (m.t === 'stats') {
              if (m.fps > 0) seen();
              post({ t: 'stats', fps: m.fps, kbps: m.kbps, decodeMs: m.decodeMs, pipeMs: m.pipeMs,
                     codec: String(m.codec || ''), queue: m.queue });
            } else if (m.t === 'log') post({ t: 'log', s: String(m.s) });
          });
        }
      };
      const AC = window.AudioContext;
      if (AC) window.AudioContext = class extends AC {
        constructor(...args) {
          super(...args);
          const report = () => post({ t: 'audio', s: this.state });
          this.addEventListener('statechange', report);
          report();
        }
      };
      window.voxlRelease = () => dispatchEvent(new Event('blur'));
      window.voxlKeyboard = (show) => {
        const k = document.getElementById('kbd');
        if (!k) return false;
        k.setAttribute('inputmode', show ? 'text' : 'none');
        k.blur();
        k.focus({ preventScroll: true });
        return document.activeElement === k;
      };
      window.voxlAudioSession = (type) => {
        if (navigator.audioSession) navigator.audioSession.type = type;
        return navigator.audioSession ? navigator.audioSession.type : 'none';
      };
    })();
    """

    /// The app's touches and key bar, fed into voxl's own paths: a pointer event or wheel on
    /// #surface for voxl's mouse code, a KeyboardEvent or paste on #kbd for its key code. Positions
    /// are fractions of the desktop. One-shot modifiers live here, so a soft-keyboard key or a click
    /// after the bar's ⌘ gets it once. Zoom scales #surface itself: voxl maps clicks through its
    /// on-screen box, and the picture stays as sharp as the stream.
    static let input = """
    (() => {
      const post = (m) => window.webkit.messageHandlers.viewer.postMessage(m);
      const surface = () => document.getElementById('surface');
      const kbd = () => document.getElementById('kbd');
      const MOD = { MetaLeft: 'Meta', AltLeft: 'Alt', ControlLeft: 'Control', ShiftLeft: 'Shift' };
      let armed = [], holding = null;
      const flags = (mods) => ({ metaKey: mods.includes('MetaLeft'), altKey: mods.includes('AltLeft'),
                                 ctrlKey: mods.includes('ControlLeft'), shiftKey: mods.includes('ShiftLeft') });
      const key = (type, k, code, mods) => kbd() && kbd().dispatchEvent(new KeyboardEvent(type,
        { key: k, code, bubbles: true, cancelable: true, ...flags(mods) }));
      const press = (mods) => mods.forEach((c, i) => key('keydown', MOD[c], c, mods.slice(0, i + 1)));
      const lift = (mods) => [...mods].reverse().forEach((c, i, r) => key('keyup', MOD[c], c, r.slice(i + 1)));
      const disarm = () => { if (armed.length) { armed = []; post({ t: 'armed', mods: [] }); } };
      window.voxlArm = (mods) => { armed = mods; };
      window.voxlTap = (k, code) => {
        letGo();
        const mods = armed; disarm();
        press(mods); key('keydown', k, code, mods); key('keyup', k, code, mods); lift(mods);
      };
      window.voxlChord = (mods, k, code) => { letGo(); press(mods); key('keydown', k, code, mods); key('keyup', k, code, mods); lift(mods); };
      // A soft-keyboard or hardware key after the bar's modifier: the modifier goes down first and up after it.
      const letGo = () => { if (holding) { const m = holding.mods; holding = null; lift(m); } };
      document.addEventListener('keydown', (e) => {
        if (!e.isTrusted) return;
        if (holding && e.code !== holding.code) letGo();
        if (!armed.length || MOD[e.code] || e.key === 'Meta' || e.key === 'Shift') return;
        holding = { code: e.code, mods: armed }; disarm(); press(holding.mods);
      }, true);
      document.addEventListener('keyup', (e) => {
        if (holding && e.code === holding.code) { const m = holding.mods; holding = null; lift(m); }
      });
      let clickMods = null;
      window.voxlMouse = (type, x, y, button) => {
        const s = surface(); if (!s) return;
        const r = s.getBoundingClientRect();
        const init = { clientX: r.left + x * r.width, clientY: r.top + y * r.height, pointerType: 'mouse',
                       pointerId: 1, isPrimary: true, bubbles: true, cancelable: true, button: button || 0 };
        if (type === 'move') s.dispatchEvent(new PointerEvent('pointermove', { ...init, button: -1 }));
        else if (type === 'down') {
          letGo();
          if (armed.length) { clickMods = armed; disarm(); press(clickMods); }
          s.dispatchEvent(new PointerEvent('pointerdown', init));
        } else if (type === 'up') {
          s.dispatchEvent(new PointerEvent('pointerup', init));
          if (clickMods) { lift(clickMods); clickMods = null; }
        }
      };
      window.voxlWheel = (x, y, dx, dy) => {
        const s = surface(); if (!s) return;
        const r = s.getBoundingClientRect();
        s.dispatchEvent(new WheelEvent('wheel', { clientX: r.left + x * r.width, clientY: r.top + y * r.height,
          deltaX: dx, deltaY: dy, deltaMode: 0, bubbles: true, cancelable: true }));
      };
      window.voxlZoom = (z, tx, ty) => {
        const s = surface(); if (!s) return;
        s.style.transformOrigin = '0 0';
        s.style.transform = z === 1 ? '' : `translate(${tx}px, ${ty}px) scale(${z})`;
      };
      window.voxlPaste = (text) => {
        const k = kbd(); if (!k) return;
        const dt = new DataTransfer();
        dt.setData('text/plain', text);
        k.dispatchEvent(new ClipboardEvent('paste', { clipboardData: dt, bubbles: true, cancelable: true }));
        window.voxlChord(['MetaLeft'], 'v', 'KeyV');
      };
      window.voxlFiles = () => { const b = document.getElementById('files-btn'); if (b) b.click(); };
      const release = window.voxlRelease;
      window.voxlRelease = () => { disarm(); holding = null; clickMods = null; if (release) release(); };
      // The Mac's pointer image, which voxl shows as a CSS cursor (touch screens draw none): the app draws it.
      addEventListener('DOMContentLoaded', () => {
        const s = surface(); if (!s) return;
        let last = '';
        new MutationObserver(() => {
          const c = s.style.cursor || '';
          if (c === last) return;
          last = c;
          const m = c.match(/url\\(\\s*["']?(data:[^"')]+)["']?\\s*\\)\\s+(\\d+)\\s+(\\d+)/);
          post(m ? { t: 'cursor', url: m[1], hx: +m[2], hy: +m[3] } : { t: 'cursor', none: c === 'none' });
        }).observe(s, { attributes: true, attributeFilter: ['style'] });
        // voxl's Files panel takes touches while it's open; the app's touch layer steps aside.
        const f = document.getElementById('files'), tools = document.getElementById('tools');
        const files = () => post({ t: 'files', open: !!f && f.classList.contains('open'),
                                   available: !!tools && tools.classList.contains('files') });
        for (const e of [f, tools]) if (e) new MutationObserver(files).observe(e, { attributes: true, attributeFilter: ['class'] });
      });
    })();
    """

    /// voxl writes the clipboard when the Mac's changes (Cmd+C there), but WebKit only lets a page
    /// write it during a tap or key press. So the page's writes come to the app.
    static let clipboard = """
    (() => {
      const clip = navigator.clipboard;
      if (!clip) return;
      const post = (m) => window.webkit.messageHandlers.clip.postMessage(m);
      clip.writeText = async (t) => post(String(t));
      const write = clip.write ? clip.write.bind(clip) : null;
      clip.write = async (items) => {
        for (const item of items) {
          if (item.types.includes('text/plain'))
            return post(await (await item.getType('text/plain')).text());
          if (item.types.includes('image/png')) {
            const blob = await item.getType('image/png');
            const url = await new Promise((done) => {
              const r = new FileReader();
              r.onload = () => done(String(r.result));
              r.readAsDataURL(blob);
            });
            return post({ png: url.slice(url.indexOf(',') + 1) });
          }
        }
        if (write) return write(items);
      };
    })();
    """

    /// voxl's toolbar sits over the picture and the app's touch layer covers it: the app has its own
    /// Files button, shows the iPhone keyboard itself (voxl's Keyboard button blurs #kbd, which takes
    /// hardware keys away), and iPhone has no Fullscreen API.
    static let style = """
    (() => {
      const s = document.createElement('style');
      s.textContent = '#tools { display: none !important; }';
      document.head.appendChild(s);
    })();
    """
}
