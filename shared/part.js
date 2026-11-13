// The part of the screen a viewer shows. Every app adds this to voxl's page and calls
// voxlPart([x, y, w, h]) with the part as fractions of the screen (0 to 1), or voxlPart(null)
// for the whole screen. voxl's #surface is zoomed so the part fills the window, centered, and
// clipped to it; voxl maps clicks through #surface's box on screen, so they land where they
// show. The stream doesn't change: the page zooms into the picture it already gets.
//
// The pointer stays in the part: a move outside it (over the black around it, or while a
// button is held) goes to the part's nearest edge, and a press or wheel there does nothing.
(() => {
  if (window !== window.top) return;
  let part = null;
  const surface = () => document.getElementById('surface');

  const apply = () => {
    const s = surface();
    if (!s) return;
    if (!part) {
      s.style.transform = s.style.transformOrigin = s.style.clipPath = '';
      return;
    }
    const W = s.offsetWidth, H = s.offsetHeight;
    if (!W || !H) return;
    const [x, y, w, h] = part;
    const z = Math.min(innerWidth / (w * W), innerHeight / (h * H));
    const tx = (innerWidth - w * W * z) / 2 - s.offsetLeft - z * x * W;
    const ty = (innerHeight - h * H * z) / 2 - s.offsetTop - z * y * H;
    s.style.transformOrigin = '0 0';
    s.style.transform = `translate(${tx}px, ${ty}px) scale(${z})`;
    s.style.clipPath = `inset(${y * H}px ${(1 - x - w) * W}px ${(1 - y - h) * H}px ${x * W}px)`;
  };

  window.voxlPart = (p) => {
    part = Array.isArray(p) && p.length === 4 && p[2] > 0 && p[3] > 0 ? p.map(Number) : null;
    apply();
  };

  // voxl lays #surface out again when the window or the stream's size changes: after it does.
  addEventListener('resize', () => requestAnimationFrame(apply));
  addEventListener('DOMContentLoaded', () => {
    const s = surface();
    if (s && window.ResizeObserver) new ResizeObserver(apply).observe(s);
  });

  // The part's box on screen.
  const box = () => {
    const s = surface();
    if (!part || !s) return null;
    const r = s.getBoundingClientRect();
    return {
      left: r.left + part[0] * r.width,
      top: r.top + part[1] * r.height,
      right: r.left + (part[0] + part[2]) * r.width,
      bottom: r.top + (part[1] + part[3]) * r.height,
    };
  };
  const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
  const keep = (e) => {
    const s = surface(), b = box();
    if (!b || e.voxlPart || ![s, document.body, document.documentElement].includes(e.target)) return;
    if (e.clientX >= b.left && e.clientX < b.right && e.clientY >= b.top && e.clientY < b.bottom) return;
    e.stopImmediatePropagation();
    e.preventDefault();
    // A release still goes, a touch's too, so no button stays held on the remote.
    if (!(e.type === 'pointermove' || e.type === 'pointerup')) return;
    const c = new PointerEvent(e.type, {
      clientX: clamp(e.clientX, b.left, b.right - 1), clientY: clamp(e.clientY, b.top, b.bottom - 1),
      pointerId: e.pointerId, pointerType: e.pointerType, isPrimary: e.isPrimary,
      button: e.button, buttons: e.buttons, bubbles: true, cancelable: true,
      ctrlKey: e.ctrlKey, shiftKey: e.shiftKey, altKey: e.altKey, metaKey: e.metaKey,
    });
    c.voxlPart = true;
    s.dispatchEvent(c);
  };
  for (const type of ['pointermove', 'pointerdown', 'pointerup', 'mousedown', 'wheel', 'contextmenu'])
    addEventListener(type, keep, { capture: true, passive: false });
})();
