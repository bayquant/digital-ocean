from fastapi import FastAPI
from fastapi.responses import HTMLResponse

app = FastAPI()

HTML = """
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<meta name="viewport" content="width=device-width, initial-scale=1.0"/>
<title>FastAPI on DigitalOcean</title>
<link href="https://fonts.googleapis.com/css2?family=Syne+Mono&family=Syne:wght@400;700;800&display=swap" rel="stylesheet"/>
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

  :root {
    --bg: #010b13;
    --surface: #0a1628;
    --teal: #00e5c0;
    --teal-dim: #00e5c022;
    --blue: #0076ff;
    --text: #c8ddf0;
    --muted: #3a5a72;
  }

  body {
    background: var(--bg);
    color: var(--text);
    font-family: 'Syne', sans-serif;
    min-height: 100vh;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    overflow: hidden;
    position: relative;
  }

  /* ── canvas background ── */
  canvas {
    position: fixed;
    inset: 0;
    z-index: 0;
    opacity: 0.55;
  }

  /* ── scanline overlay ── */
  body::after {
    content: '';
    position: fixed;
    inset: 0;
    background: repeating-linear-gradient(
      0deg,
      transparent,
      transparent 2px,
      rgba(0,0,0,0.08) 2px,
      rgba(0,0,0,0.08) 4px
    );
    pointer-events: none;
    z-index: 1;
  }

  /* ── card ── */
  .card {
    position: relative;
    z-index: 2;
    border: 1px solid var(--muted);
    background: rgba(10, 22, 40, 0.75);
    backdrop-filter: blur(18px);
    padding: 3rem 3.5rem;
    max-width: 560px;
    width: 90%;
    text-align: center;
    animation: cardIn 1s cubic-bezier(0.16,1,0.3,1) both;
  }

  @keyframes cardIn {
    from { opacity: 0; transform: translateY(32px) scale(0.97); }
    to   { opacity: 1; transform: translateY(0)   scale(1);    }
  }

  /* corner accents */
  .card::before, .card::after {
    content: '';
    position: absolute;
    width: 14px; height: 14px;
    border-color: var(--teal);
    border-style: solid;
  }
  .card::before { top: -1px; left: -1px; border-width: 2px 0 0 2px; }
  .card::after  { bottom: -1px; right: -1px; border-width: 0 2px 2px 0; }

  /* ── status pill ── */
  .status {
    display: inline-flex;
    align-items: center;
    gap: 0.5rem;
    font-family: 'Syne Mono', monospace;
    font-size: 0.7rem;
    letter-spacing: 0.15em;
    text-transform: uppercase;
    color: var(--teal);
    border: 1px solid var(--teal-dim);
    padding: 0.3rem 0.85rem;
    margin-bottom: 2rem;
    animation: fadeUp 0.8s 0.3s both;
  }

  .dot {
    width: 6px; height: 6px;
    border-radius: 50%;
    background: var(--teal);
    animation: pulse 2s ease-in-out infinite;
  }

  @keyframes pulse {
    0%, 100% { opacity: 1; transform: scale(1); }
    50%       { opacity: 0.4; transform: scale(0.7); }
  }

  /* ── heading ── */
  h1 {
    font-size: clamp(2rem, 5vw, 2.8rem);
    font-weight: 800;
    line-height: 1.1;
    letter-spacing: -0.02em;
    margin-bottom: 1rem;
    animation: fadeUp 0.8s 0.45s both;
  }

  h1 span {
    color: var(--teal);
  }

  /* ── subtitle ── */
  p.sub {
    font-size: 0.9rem;
    color: var(--muted);
    line-height: 1.6;
    margin-bottom: 2.5rem;
    animation: fadeUp 0.8s 0.6s both;
  }

  /* ── endpoint list ── */
  .endpoints {
    display: flex;
    flex-direction: column;
    gap: 0.6rem;
    animation: fadeUp 0.8s 0.75s both;
  }

  .ep {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    font-family: 'Syne Mono', monospace;
    font-size: 0.78rem;
    padding: 0.65rem 1rem;
    border: 1px solid #0e2236;
    background: rgba(0,229,192,0.03);
    transition: background 0.2s, border-color 0.2s;
    cursor: default;
    text-align: left;
  }

  .ep:hover {
    background: rgba(0,229,192,0.07);
    border-color: var(--muted);
  }

  .method {
    color: var(--teal);
    font-weight: 700;
    min-width: 36px;
  }

  .path { color: var(--text); }
  .desc { color: var(--muted); margin-left: auto; font-size: 0.7rem; }

  /* ── docs link ── */
  .docs-link {
    display: inline-block;
    margin-top: 2rem;
    font-family: 'Syne Mono', monospace;
    font-size: 0.75rem;
    letter-spacing: 0.1em;
    color: var(--blue);
    text-decoration: none;
    border-bottom: 1px solid transparent;
    transition: border-color 0.2s;
    animation: fadeUp 0.8s 0.9s both;
  }
  .docs-link:hover { border-color: var(--blue); }

  @keyframes fadeUp {
    from { opacity: 0; transform: translateY(12px); }
    to   { opacity: 1; transform: translateY(0); }
  }
</style>
</head>
<body>

<canvas id="c"></canvas>

<div class="card">
  <div class="status"><span class="dot"></span>System Online</div>

  <h1>Fast<span>API</span><br/>on Digital Ocean</h1>
  <p class="sub">Python backend deployed and running.<br/>All systems operational.</p>

  <div class="endpoints">
    <div class="ep"><span class="method">GET</span><span class="path">/</span><span class="desc">index</span></div>
    <div class="ep"><span class="method">GET</span><span class="path">/health</span><span class="desc">health check</span></div>
    <div class="ep"><span class="method">GET</span><span class="path">/items/{id}</span><span class="desc">fetch item</span></div>
  </div>

  <a class="docs-link" href="/docs">→ Open API Docs</a>
</div>

<script>
  const canvas = document.getElementById('c');
  const ctx = canvas.getContext('2d');

  let W, H, particles = [];

  function resize() {
    W = canvas.width  = window.innerWidth;
    H = canvas.height = window.innerHeight;
  }
  resize();
  window.addEventListener('resize', resize);

  class Particle {
    constructor() { this.reset(true); }
    reset(init) {
      this.x = Math.random() * W;
      this.y = init ? Math.random() * H : H + 10;
      this.r = Math.random() * 1.5 + 0.3;
      this.vy = -(Math.random() * 0.4 + 0.1);
      this.vx = (Math.random() - 0.5) * 0.15;
      this.alpha = Math.random() * 0.6 + 0.2;
      this.color = Math.random() > 0.5 ? '0,229,192' : '0,118,255';
    }
    update() {
      this.x += this.vx;
      this.y += this.vy;
      if (this.y < -10) this.reset(false);
    }
    draw() {
      ctx.beginPath();
      ctx.arc(this.x, this.y, this.r, 0, Math.PI * 2);
      ctx.fillStyle = `rgba(${this.color},${this.alpha})`;
      ctx.fill();
    }
  }

  for (let i = 0; i < 180; i++) particles.push(new Particle());

  /* wave layers */
  let t = 0;
  function drawWaves() {
    const layers = [
      { amp: 38, freq: 0.008, speed: 0.012, y: H * 0.72, alpha: 0.06, color: '0,229,192' },
      { amp: 28, freq: 0.012, speed: 0.018, y: H * 0.78, alpha: 0.08, color: '0,118,255' },
      { amp: 20, freq: 0.016, speed: 0.025, y: H * 0.82, alpha: 0.05, color: '0,229,192' },
    ];
    layers.forEach(l => {
      ctx.beginPath();
      ctx.moveTo(0, H);
      for (let x = 0; x <= W; x += 4) {
        const y = l.y + Math.sin(x * l.freq + t * l.speed * 60) * l.amp;
        ctx.lineTo(x, y);
      }
      ctx.lineTo(W, H); ctx.lineTo(0, H); ctx.closePath();
      ctx.fillStyle = `rgba(${l.color},${l.alpha})`;
      ctx.fill();
    });
  }

  function loop(ts) {
    t = ts / 1000;
    ctx.clearRect(0, 0, W, H);
    drawWaves();
    particles.forEach(p => { p.update(); p.draw(); });
    requestAnimationFrame(loop);
  }
  requestAnimationFrame(loop);
</script>
</body>
</html>
"""


@app.get("/", response_class=HTMLResponse)
def root():
    return HTML


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/items/{item_id}")
def get_item(item_id: int, q: str | None = None):
    return {"item_id": item_id, "q": q}
