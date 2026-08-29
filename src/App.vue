<script setup>
import { ref, reactive, computed, onMounted, onBeforeUnmount } from 'vue'

/* ================= 数据 ================= */
const points = ref([]) // { t, lon, lat, lon0, lat0 }
const loaded = ref(false)
const errorMsg = ref('')
const showLine = ref(true)

/* ================= 视图窗口 =================
 * 直角坐标系，原点在页面左下角：
 *   s  : 像素 / 度（比例尺）
 *   ox : 窗口左边缘对应的经度
 *   oy : 窗口下边缘对应的纬度
 *   屏幕坐标: x = (lon - ox) * s ; y = (lat - oy) * s（y 向上）
 */
const view = reactive({ s: 1, ox: 0, oy: 0 })
const fitS = ref(1) // 初始适配比例尺（点的大小以此为基准缩放）
const zoomRatio = computed(() => (fitS.value > 0 ? view.s / fitS.value : 1))
const scaleText = computed(() => {
  if (!loaded.value) return '—'
  const deg = 1 / view.s
  return `1 px ≈ ${deg >= 0.001 ? deg.toFixed(3) : deg.toFixed(6)}° · ${zoomRatio.value.toFixed(2)}×`
})

/* ================= 交互状态 ================= */
const hovered = ref(-1)
const dragged = ref(-1)
const tipPos = reactive({ x: 0, y: 0 })
const tipText = computed(() => {
  const i = dragged.value >= 0 ? dragged.value : hovered.value
  if (i < 0) return ''
  const p = points.value[i]
  if (!p) return ''
  const edit = dragged.value >= 0
  const lon = `<b>${p.lon.toFixed(7)}</b>${edit ? `<span class="dim">（原 ${p.lon0.toFixed(7)}）</span>` : ''}`
  const lat = `<b>${p.lat.toFixed(7)}</b>${edit ? `<span class="dim">（原 ${p.lat0.toFixed(7)}）</span>` : ''}`
  return `第 ${i + 1} 点${p.t ? `<span class="dim"> · ${p.t}</span>` : ''}<br>经度 ${lon}<br>纬度 ${lat}`
})

/* ================= 画布 ================= */
const wrapRef = ref(null)
const canvasRef = ref(null)
let W = 0
let H = 0
let dpr = 1
let panning = false
let lastX = 0
let lastY = 0
let fitted = false
let rafId = 0
let ro = null
const pointers = new Map()
let pinch = null

/* 蓝白配色 + 柔和亮色点缀 */
const C = {
  axis: '#1d4ed8',
  tick: '#3b6fb5',
  grid: '#e6f0fc',
  line: '#7fb4ec',
  point: '#2563eb',
  hover: '#3b82f6',
  ring: '#bfdbfe',
  drag: '#fb923c',
  dragRing: '#fed7aa',
  guide: '#93c5fd',
}

const sMin = () => Math.max(1e-3, fitS.value * 0.5)
const sMax = () => fitS.value * 50

/* 平移边界：以当前所有点的外接矩形为准，各边留 25% 跨度余量，
 * 保证窗口始终与数据区相交——缩放后也不会把数据整体拖出视野太远，
 * 可拖动范围随点坐标动态变化（拖动点移远时边界会自动扩大） */
const WORLD = { minLon: 0, maxLon: 0, minLat: 0, maxLat: 0 }

function updateWorldBounds() {
  let minLon = Infinity
  let maxLon = -Infinity
  let minLat = Infinity
  let maxLat = -Infinity
  for (const p of points.value) {
    if (p.lon < minLon) minLon = p.lon
    if (p.lon > maxLon) maxLon = p.lon
    if (p.lat < minLat) minLat = p.lat
    if (p.lat > maxLat) maxLat = p.lat
  }
  WORLD.minLon = minLon
  WORLD.maxLon = maxLon
  WORLD.minLat = minLat
  WORLD.maxLat = maxLat
}

function clampView() {
  if (!points.value.length || W <= 0 || H <= 0) return
  updateWorldBounds()
  const spanLon = Math.max(WORLD.maxLon - WORLD.minLon, 1e-6)
  const spanLat = Math.max(WORLD.maxLat - WORLD.minLat, 1e-6)
  const padLon = spanLon * 0.25
  const padLat = spanLat * 0.25
  view.ox = Math.min(Math.max(view.ox, WORLD.minLon - padLon - W / view.s), WORLD.maxLon + padLon)
  view.oy = Math.min(Math.max(view.oy, WORLD.minLat - padLat - H / view.s), WORLD.maxLat + padLat)
}

function niceStep(raw) {
  const p = Math.pow(10, Math.floor(Math.log10(raw)))
  const n = raw / p
  return (n >= 5 ? 5 : n >= 2 ? 2 : 1) * p
}

function pointRadius() {
  const k = fitS.value > 0 ? view.s / fitS.value : 1
  return Math.min(13, Math.max(2.5, 5 * k))
}

function hitTest(cx, cy) {
  const r = Math.max(pointRadius() + 2, 8)
  let best = -1
  let bestD = Infinity
  const pts = points.value
  for (let i = 0; i < pts.length; i++) {
    const p = pts[i]
    const dx = (p.lon - view.ox) * view.s - cx
    const dy = (p.lat - view.oy) * view.s - (H - cy)
    const d = dx * dx + dy * dy
    if (d <= r * r && d < bestD) {
      bestD = d
      best = i
    }
  }
  return best
}

function scheduleDraw() {
  if (!rafId) rafId = requestAnimationFrame(() => {
    rafId = 0
    draw()
  })
}

/* ================= 绘制 ================= */
function draw() {
  const c = canvasRef.value
  if (!c) return
  const ctx = c.getContext('2d')
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
  ctx.clearRect(0, 0, W, H)
  drawGrid(ctx)
  if (showLine.value && points.value.length > 1) drawTrack(ctx)
  drawPoints(ctx)
  drawAxes(ctx)
}

function drawGrid(ctx) {
  ctx.font = '11px "Segoe UI", "Microsoft YaHei", system-ui, sans-serif'
  ctx.fillStyle = C.tick
  ctx.strokeStyle = C.grid
  ctx.lineWidth = 1

  // X 轴（经度）刻度
  const stepLon = niceStep(90 / view.s)
  const decLon = Math.max(0, Math.min(9, Math.ceil(-Math.log10(stepLon) - 1e-9)))
  ctx.textAlign = 'center'
  ctx.textBaseline = 'top'
  for (let i = Math.ceil(view.ox / stepLon); ; i++) {
    const lon = i * stepLon
    const x = (lon - view.ox) * view.s
    if (x > W + 1) break
    if (x >= -1) {
      ctx.beginPath()
      ctx.moveTo(x, 0)
      ctx.lineTo(x, H)
      ctx.stroke()
      if (x >= 44 && x <= W - 44) ctx.fillText(lon.toFixed(decLon) + '°', x, H - 17)
    }
  }

  // Y 轴（纬度）刻度
  const stepLat = niceStep(90 / view.s)
  const decLat = Math.max(0, Math.min(9, Math.ceil(-Math.log10(stepLat) - 1e-9)))
  ctx.textAlign = 'left'
  ctx.textBaseline = 'middle'
  for (let j = Math.ceil(view.oy / stepLat); ; j++) {
    const lat = j * stepLat
    const y = (lat - view.oy) * view.s
    if (y > H + 1) break
    if (y >= -1) {
      ctx.beginPath()
      ctx.moveTo(0, H - y)
      ctx.lineTo(W, H - y)
      ctx.stroke()
      if (y >= 26) {
        const cy = Math.min(H - 8, H - y)
        ctx.fillText(lat.toFixed(decLat) + '°', 7, cy)
      }
    }
  }
}

function drawTrack(ctx) {
  ctx.strokeStyle = C.line
  ctx.lineWidth = 1.5
  ctx.lineJoin = 'round'
  ctx.lineCap = 'round'
  ctx.beginPath()
  const pts = points.value
  for (let i = 0; i < pts.length; i++) {
    const p = pts[i]
    const x = (p.lon - view.ox) * view.s
    const y = H - (p.lat - view.oy) * view.s
    if (i === 0) ctx.moveTo(x, y)
    else ctx.lineTo(x, y)
  }
  ctx.stroke()
}

function drawPoints(ctx) {
  const r0 = pointRadius()
  const pts = points.value
  for (let i = 0; i < pts.length; i++) {
    if (i === dragged.value) continue // 拖动中的点最后画
    const p = pts[i]
    const x = (p.lon - view.ox) * view.s
    const y = (p.lat - view.oy) * view.s
    if (x < -r0 - 4 || x > W + r0 + 4 || y < -r0 - 4 || y > H + r0 + 4) continue
    const isHover = i === hovered.value
    const r = isHover ? r0 + 1.5 : r0
    ctx.beginPath()
    ctx.arc(x, H - y, r, 0, Math.PI * 2)
    ctx.fillStyle = isHover ? C.hover : C.point
    ctx.fill()
    ctx.strokeStyle = isHover ? C.ring : '#ffffff'
    ctx.lineWidth = 1.5
    ctx.stroke()
  }

  // 拖动中的点：柔和亮色 + 指向坐标轴的参考虚线
  if (dragged.value >= 0 && pts[dragged.value]) {
    const p = pts[dragged.value]
    const x = (p.lon - view.ox) * view.s
    const y = H - (p.lat - view.oy) * view.s
    ctx.save()
    ctx.strokeStyle = C.guide
    ctx.setLineDash([4, 4])
    ctx.lineWidth = 1
    ctx.beginPath()
    ctx.moveTo(x, y)
    ctx.lineTo(x, H)
    ctx.stroke()
    ctx.beginPath()
    ctx.moveTo(x, y)
    ctx.lineTo(0, y)
    ctx.stroke()
    ctx.restore()
    ctx.beginPath()
    ctx.arc(x, y, r0 + 2, 0, Math.PI * 2)
    ctx.fillStyle = C.drag
    ctx.fill()
    ctx.strokeStyle = '#ffffff'
    ctx.lineWidth = 2
    ctx.stroke()
    ctx.strokeStyle = C.dragRing
    ctx.lineWidth = 1
    ctx.beginPath()
    ctx.arc(x, y, r0 + 4.5, 0, Math.PI * 2)
    ctx.stroke()
  }
}

function drawAxes(ctx) {
  // X 轴固定在页面下边缘，Y 轴固定在页面左边缘
  ctx.strokeStyle = C.axis
  ctx.lineWidth = 1.5
  ctx.beginPath()
  ctx.moveTo(0, H - 0.75)
  ctx.lineTo(W, H - 0.75)
  ctx.stroke()
  ctx.beginPath()
  ctx.moveTo(0.75, 0)
  ctx.lineTo(0.75, H)
  ctx.stroke()
}

/* ================= 视图操作 ================= */
function fitView() {
  const pts = points.value
  if (!pts.length || W <= 0 || H <= 0) return
  let minLon = Infinity
  let maxLon = -Infinity
  let minLat = Infinity
  let maxLat = -Infinity
  for (const p of pts) {
    if (p.lon < minLon) minLon = p.lon
    if (p.lon > maxLon) maxLon = p.lon
    if (p.lat < minLat) minLat = p.lat
    if (p.lat > maxLat) maxLat = p.lat
  }
  const spanLon = Math.max(maxLon - minLon, 1e-6)
  const spanLat = Math.max(maxLat - minLat, 1e-6)
  const pad = 0.06
  const s = Math.min(W / (spanLon * (1 + pad * 2)), H / (spanLat * (1 + pad * 2)))
  view.s = s
  view.ox = (minLon + maxLon) / 2 - W / (2 * s)
  view.oy = (minLat + maxLat) / 2 - H / (2 * s)
  fitS.value = s
  fitted = true
  clampView()
  scheduleDraw()
}

function resetCoords() {
  for (const p of points.value) {
    p.lon = p.lon0
    p.lat = p.lat0
  }
  dragged.value = -1
  scheduleDraw()
}

function resetView() {
  fitView()
}

function zoomAt(cx, cy, sNew) {
  sNew = Math.min(sMax(), Math.max(sMin(), sNew))
  const wx = view.ox + cx / view.s
  const wy = view.oy + (H - cy) / view.s
  view.s = sNew
  view.ox = wx - cx / sNew
  view.oy = wy - (H - cy) / sNew
  clampView()
  scheduleDraw()
}

function zoomIn() {
  zoomAt(W / 2, H / 2, view.s * 1.3)
}

function zoomOut() {
  zoomAt(W / 2, H / 2, view.s / 1.3)
}

/* ================= 指针交互 ================= */
function updateCursor() {
  const c = canvasRef.value
  if (!c) return
  if (!loaded.value) c.style.cursor = 'default'
  else if (dragged.value >= 0 || panning) c.style.cursor = 'grabbing'
  else if (hovered.value >= 0) c.style.cursor = 'pointer'
  else c.style.cursor = 'grab'
}

function moveTip(x, y) {
  tipPos.x = Math.min(Math.max(x + 14, 4), Math.max(4, W - 185))
  tipPos.y = Math.min(Math.max(y + 16, 4), Math.max(4, H - 88))
}

function beginPinch() {
  const [a, b] = [...pointers.values()]
  const mx = (a.x + b.x) / 2
  const my = (a.y + b.y) / 2
  pinch = {
    d: Math.max(1, Math.hypot(b.x - a.x, b.y - a.y)),
    s0: view.s,
    wx: view.ox + mx / view.s,
    wy: view.oy + (H - my) / view.s,
  }
}

function updatePinch() {
  const [a, b] = [...pointers.values()]
  const d = Math.max(1, Math.hypot(b.x - a.x, b.y - a.y))
  const sNew = Math.min(sMax(), Math.max(sMin(), (pinch.s0 * d) / pinch.d))
  const mx = (a.x + b.x) / 2
  const my = (a.y + b.y) / 2
  view.s = sNew
  view.ox = pinch.wx - mx / sNew
  view.oy = pinch.wy - (H - my) / sNew
  clampView()
  scheduleDraw()
}

function onPointerDown(e) {
  if (e.button !== 0) return
  const c = canvasRef.value
  c.setPointerCapture(e.pointerId)
  pointers.set(e.pointerId, { x: e.offsetX, y: e.offsetY })
  if (pointers.size === 2) {
    panning = false
    hovered.value = -1
    beginPinch()
    updateCursor()
    return
  }
  const hit = hitTest(e.offsetX, e.offsetY)
  if (hit >= 0) {
    dragged.value = hit
    hovered.value = hit
    moveTip(e.offsetX, e.offsetY)
  } else {
    panning = true
    hovered.value = -1
  }
  lastX = e.offsetX
  lastY = e.offsetY
  updateCursor()
}

function onPointerMove(e) {
  const x = e.offsetX
  const y = e.offsetY
  if (pointers.has(e.pointerId)) pointers.set(e.pointerId, { x, y })
  if (pinch && pointers.size >= 2) {
    updatePinch()
    return
  }
  if (dragged.value >= 0) {
    const p = points.value[dragged.value]
    p.lon = view.ox + x / view.s
    p.lat = view.oy + (H - y) / view.s
    moveTip(x, y)
  } else if (panning) {
    view.ox -= (x - lastX) / view.s
    view.oy += (y - lastY) / view.s
    clampView()
  } else if (loaded.value) {
    hovered.value = hitTest(x, y)
    if (hovered.value >= 0) moveTip(x, y)
    updateCursor()
  }
  lastX = x
  lastY = y
  scheduleDraw()
}

function onPointerUp(e) {
  pointers.delete(e.pointerId)
  if (pinch && pointers.size < 2) pinch = null
  if (pointers.size < 2) {
    panning = false
    dragged.value = -1
    hovered.value = loaded.value ? hitTest(e.offsetX, e.offsetY) : -1
    if (hovered.value >= 0) moveTip(e.offsetX, e.offsetY)
  }
  updateCursor()
  scheduleDraw()
}

function onPointerLeave() {
  if (!panning && dragged.value < 0) {
    hovered.value = -1
    updateCursor()
    scheduleDraw()
  }
}

function onWheel(e) {
  e.preventDefault()
  const f = Math.exp(-e.deltaY * 0.0016)
  zoomAt(e.offsetX, e.offsetY, view.s * f)
}

function onKey(e) {
  if (e.target && (e.target.tagName === 'INPUT' || e.target.tagName === 'TEXTAREA')) return
  if (e.key === '+' || e.key === '=') zoomIn()
  else if (e.key === '-' || e.key === '_') zoomOut()
}

/* ================= 尺寸 / 数据 ================= */
function resize() {
  const wrap = wrapRef.value
  const c = canvasRef.value
  if (!wrap || !c) return
  dpr = Math.max(1, window.devicePixelRatio || 1)
  W = wrap.clientWidth
  H = wrap.clientHeight
  c.width = Math.round(W * dpr)
  c.height = Math.round(H * dpr)
  if (points.value.length && !fitted) fitView()
  else {
    clampView()
    scheduleDraw()
  }
}

function parseCsv(text) {
  const lines = text.split(/\r?\n/).filter((l) => l.trim() !== '')
  const pts = []
  for (let k = 1; k < lines.length; k++) {
    const c = lines[k].split(',')
    if (c.length < 7) continue
    const lon = parseFloat(c[5])
    const lat = parseFloat(c[6])
    if (Number.isFinite(lon) && Number.isFinite(lat)) {
      pts.push({ t: c[0].trim(), lon, lat, lon0: lon, lat0: lat })
    }
  }
  return pts
}

async function loadData() {
  try {
    const res = await fetch(import.meta.env.BASE_URL + 'track-data.csv')
    if (!res.ok) throw new Error('HTTP ' + res.status)
    const text = await res.text()
    points.value = parseCsv(text)
    if (!points.value.length) throw new Error('未解析到有效数据')
    loaded.value = true
    fitView()
    updateCursor()
  } catch (err) {
    errorMsg.value = '数据加载失败：' + err.message
  }
}

onMounted(() => {
  resize()
  const c = canvasRef.value
  c.addEventListener('pointerdown', onPointerDown)
  c.addEventListener('pointermove', onPointerMove)
  c.addEventListener('pointerup', onPointerUp)
  c.addEventListener('pointercancel', onPointerUp)
  c.addEventListener('pointerleave', onPointerLeave)
  c.addEventListener('wheel', onWheel, { passive: false })
  window.addEventListener('keydown', onKey)
  ro = new ResizeObserver(() => resize())
  ro.observe(wrapRef.value)
  loadData()
})

onBeforeUnmount(() => {
  const c = canvasRef.value
  c.removeEventListener('pointerdown', onPointerDown)
  c.removeEventListener('pointermove', onPointerMove)
  c.removeEventListener('pointerup', onPointerUp)
  c.removeEventListener('pointercancel', onPointerUp)
  c.removeEventListener('pointerleave', onPointerLeave)
  c.removeEventListener('wheel', onWheel)
  window.removeEventListener('keydown', onKey)
  if (ro) ro.disconnect()
  if (rafId) cancelAnimationFrame(rafId)
})
</script>

<template>
  <div class="stage" ref="wrapRef">
    <canvas ref="canvasRef"></canvas>

    <aside class="panel">
      <div class="panel-head">
        <span class="logo">◉</span>
        <div>
          <div class="title">雷达航迹可视化</div>
          <div class="sub">架次一 · 雷达 1 航迹（0719） · {{ points.length }} 个点</div>
        </div>
      </div>

      <label class="switch">
        <input type="checkbox" v-model="showLine" />
        <span class="track"></span>
        <span>显示航迹连线</span>
      </label>

      <div class="legend">X 轴 = 经度 · Y 轴 = 纬度</div>

      <div class="btn-row">
        <button class="btn primary" :disabled="!loaded" @click="resetCoords">恢复坐标</button>
        <button class="btn" :disabled="!loaded" @click="resetView">恢复视野</button>
      </div>

      <div class="zoom-row">
        <button class="icon-btn" :disabled="!loaded" @click="zoomOut" title="缩小">−</button>
        <span class="scale">{{ scaleText }}</span>
        <button class="icon-btn" :disabled="!loaded" @click="zoomIn" title="放大">＋</button>
      </div>

      <div class="hint">
        滚轮：以光标为中心缩放<br />
        按住左键拖空白处：平移画面<br />
        按住圆点拖动：调整该点经纬度
      </div>
    </aside>

    <div class="tip" v-show="tipText" :style="{ left: tipPos.x + 'px', top: tipPos.y + 'px' }" v-html="tipText"></div>

    <div class="load" v-if="!loaded">{{ errorMsg || '正在加载数据…' }}</div>
  </div>
</template>

<style>
.stage {
  position: fixed;
  inset: 0;
  background: #fff;
}

canvas {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  display: block;
  touch-action: none;
  user-select: none;
  -webkit-user-select: none;
  -webkit-tap-highlight-color: transparent;
}

.panel {
  position: absolute;
  top: 14px;
  right: 14px;
  z-index: 10;
  width: 232px;
  padding: 14px 14px 12px;
  background: rgba(255, 255, 255, 0.94);
  border: 1px solid #cfe3fb;
  border-radius: 14px;
  box-shadow: 0 8px 28px rgba(29, 78, 216, 0.1);
  color: #1e3a5f;
  display: flex;
  flex-direction: column;
  gap: 10px;
  backdrop-filter: blur(6px);
}

.panel-head {
  display: flex;
  align-items: center;
  gap: 10px;
}

.logo {
  width: 34px;
  height: 34px;
  flex: none;
  border-radius: 10px;
  background: linear-gradient(135deg, #3b82f6, #1d4ed8);
  color: #fff;
  display: flex;
  align-items: center;
  justify-content: center;
  font-size: 15px;
}

.title {
  font-size: 14.5px;
  font-weight: 600;
}

.sub {
  font-size: 11.5px;
  color: #6b8ab8;
  margin-top: 2px;
}

.switch {
  display: flex;
  align-items: center;
  gap: 8px;
  font-size: 12.5px;
  cursor: pointer;
  user-select: none;
}

.switch input {
  display: none;
}

.switch .track {
  width: 30px;
  height: 17px;
  flex: none;
  border-radius: 9px;
  background: #dbeafe;
  position: relative;
  transition: background 0.15s;
}

.switch .track::after {
  content: '';
  position: absolute;
  top: 2px;
  left: 2px;
  width: 13px;
  height: 13px;
  border-radius: 50%;
  background: #fff;
  box-shadow: 0 1px 3px rgba(0, 0, 0, 0.2);
  transition: left 0.15s;
}

.switch input:checked + .track {
  background: #1d4ed8;
}

.switch input:checked + .track::after {
  left: 15px;
}

.legend {
  font-size: 11px;
  color: #6b8ab8;
}

.btn-row {
  display: flex;
  gap: 8px;
}

.btn {
  flex: 1;
  padding: 7px 0;
  font-size: 12.5px;
  border-radius: 8px;
  border: 1px solid #bfdbfe;
  background: #eff6ff;
  color: #1d4ed8;
  cursor: pointer;
  transition: all 0.12s;
  font-family: inherit;
}

.btn:hover {
  background: #dbeafe;
}

.btn:active {
  transform: translateY(1px);
}

.btn.primary {
  background: #1d4ed8;
  border-color: #1d4ed8;
  color: #fff;
}

.btn.primary:hover {
  background: #1e40af;
}

.btn:disabled {
  opacity: 0.45;
  cursor: not-allowed;
}

.zoom-row {
  display: flex;
  align-items: center;
  gap: 8px;
}

.icon-btn {
  width: 30px;
  height: 28px;
  flex: none;
  border-radius: 8px;
  border: 1px solid #bfdbfe;
  background: #eff6ff;
  color: #1d4ed8;
  font-size: 15px;
  line-height: 1;
  cursor: pointer;
  transition: all 0.12s;
}

.icon-btn:hover {
  background: #dbeafe;
}

.icon-btn:active {
  transform: translateY(1px);
}

.icon-btn:disabled {
  opacity: 0.45;
  cursor: not-allowed;
}

.scale {
  flex: 1;
  text-align: center;
  font-size: 11px;
  color: #6b8ab8;
  font-variant-numeric: tabular-nums;
}

.hint {
  font-size: 11px;
  color: #8aa4c9;
  line-height: 1.7;
  border-top: 1px dashed #dbeafe;
  padding-top: 8px;
}

.tip {
  position: absolute;
  z-index: 20;
  pointer-events: none;
  background: rgba(255, 255, 255, 0.97);
  border: 1px solid #bfdbfe;
  border-radius: 8px;
  padding: 7px 10px;
  font-size: 12px;
  line-height: 1.65;
  color: #1e3a5f;
  box-shadow: 0 4px 16px rgba(29, 78, 216, 0.15);
}

.tip b {
  color: #1d4ed8;
  font-variant-numeric: tabular-nums;
}

.tip .dim {
  color: #93b0d4;
  font-weight: normal;
}

.load {
  position: absolute;
  inset: 0;
  display: flex;
  align-items: center;
  justify-content: center;
  color: #6b8ab8;
  font-size: 14px;
  z-index: 5;
}
</style>
