<template>
  <div class="globe-container">
    <div class="globe-viewport">
      <canvas
        ref="canvasRef"
        @mousedown="onMouseDown"
        @mousemove="onMouseMove"
        @mouseup="onMouseUp"
        @mouseleave="onMouseLeave"
      ></canvas>
      <canvas ref="overlayRef" class="border-overlay"></canvas>
    </div>
    <div
      v-if="tooltipVisible"
      class="country-tooltip"
      :style="{ left: tooltipX + 'px', top: tooltipY + 'px' }"
    >{{ tooltipName }}</div>
  </div>
</template>

<script setup>
import { ref, onMounted, onUnmounted } from 'vue'
import * as THREE from 'three'

const canvasRef = ref(null)

const GLOBE_VIEW_SIZE = 560
const overlayRef = ref(null)

const tooltipVisible = ref(false)
const tooltipName = ref('')
const tooltipX = ref(0)
const tooltipY = ref(0)

let renderer, scene, camera, globeGroup, sphereMesh
let animationId
let geojsonData = null
let densifiedBorderRings = []

const TEX_W = 2048
const TEX_H = 1024
const ID_W = 1024
const ID_H = 512

let maskCanvas, maskCtx, maskTexture
let hoverCanvas, hoverCtx, hoverTexture
let idCanvas, idCtx
let hoveredCountry = -1
let prevHoveredCountry = -1
let needsHoverUpdate = false

// ── Shaders ────────────────────────────────────────────────────
const vertexShader = /* glsl */ `
  varying vec3 vNormal;
  varying vec3 vWorldPosition;
  varying vec2 vUv;

  void main() {
    vec4 worldPos = modelMatrix * vec4(position, 1.0);
    vWorldPosition = worldPos.xyz;
    vNormal = normalize(mat3(modelMatrix) * normal);
    vUv = uv;
    gl_Position = projectionMatrix * modelViewMatrix * vec4(position, 1.0);
  }
`

const fragmentShader = /* glsl */ `
  varying vec3 vNormal;
  varying vec3 vWorldPosition;
  varying vec2 vUv;

  uniform vec3 uColorLight;
  uniform vec3 uColorDark;
  uniform sampler2D uCountryMask;
  uniform sampler2D uHoverMask;
  uniform float uDefaultOpacity;
  uniform float uHoverOpacity;

  float sharpenMask(float raw) {
    float aa = max(fwidth(raw) * 0.75, 0.001);
    return smoothstep(0.5 - aa, 0.5 + aa, raw);
  }

  void main() {
    // Ocean gradient
    vec3 lightDir = normalize(vec3(-0.3, 0.8, 0.6));
    float diff = dot(normalize(vNormal), lightDir);
    float highlight = pow(max(diff, 0.0), 4.0) * 3.0;
    float gradient = highlight + 0.1;

    vec3 viewDir = normalize(cameraPosition - vWorldPosition);
    float fresnel = 1.0 - abs(dot(normalize(vNormal), viewDir));
    fresnel = pow(fresnel, 2.5) * 0.15;

    vec3 oceanColor = mix(uColorDark, uColorLight, gradient);
    oceanColor = mix(oceanColor, uColorLight, fresnel);

    // Country mask (binary 0/1) — sharpened in shader
    float countryRaw = texture2D(uCountryMask, vUv).a;
    float hoverRaw   = texture2D(uHoverMask, vUv).a;

    float countryMask = sharpenMask(countryRaw);
    float hoverMask   = sharpenMask(hoverRaw);

    float fillAlpha =
      countryMask * uDefaultOpacity +
      hoverMask   * (uHoverOpacity - uDefaultOpacity);
    fillAlpha = clamp(fillAlpha, 0.0, 1.0);

    vec3 finalColor = mix(oceanColor, vec3(1.0), fillAlpha);
    gl_FragColor = vec4(finalColor, 1.0);
  }
`

// ── Canvas drawing: pure binary masks ───────────────────────────
function drawPathOnCanvas(ctx, w, h, feature) {
  const geom = feature.geometry
  if (!geom) return
  const polygons = geom.type === 'MultiPolygon' ? geom.coordinates : [geom.coordinates]
  ctx.beginPath()
  for (const poly of polygons) {
    if (!poly || !poly[0] || poly[0].length < 3) continue
    const ring = poly[0]
    const step = Math.max(1, Math.floor(ring.length / 600))
    for (let j = 0; j < ring.length; j += step) {
      const [lng, lat] = ring[j]
      const x = ((lng + 180) / 360) * w
      const y = ((90 - lat) / 180) * h
      if (j === 0) ctx.moveTo(x, y)
      else ctx.lineTo(x, y)
    }
    ctx.closePath()
  }
  ctx.fill()
}

function drawCountryMask(ctx, w, h) {
  if (!geojsonData) return
  ctx.clearRect(0, 0, w, h)
  ctx.fillStyle = 'rgba(255,255,255,1)' // pure white 100%
  for (const feature of geojsonData.features) {
    drawPathOnCanvas(ctx, w, h, feature)
  }
}

function drawHoverMask(ctx, w, h) {
  if (!geojsonData) return
  ctx.clearRect(0, 0, w, h)
  if (hoveredCountry < 0) return
  ctx.fillStyle = 'rgba(255,255,255,1)'
  drawPathOnCanvas(ctx, w, h, geojsonData.features[hoveredCountry])
}

function drawIdMap(ctx, w, h) {
  if (!geojsonData) return
  ctx.fillStyle = '#ffffff'; ctx.fillRect(0, 0, w, h)
  const features = geojsonData.features
  for (let i = 0; i < features.length; i++) {
    const c = { r: i & 0xFF, g: (i >> 8) & 0xFF, b: (i >> 16) & 0xFF }
    ctx.fillStyle = `rgb(${c.r},${c.g},${c.b})`
    ctx.beginPath()
    const geom = features[i].geometry
    if (!geom) continue
    const polygons = geom.type === 'MultiPolygon' ? geom.coordinates : [geom.coordinates]
    for (const poly of polygons) {
      if (!poly || !poly[0] || poly[0].length < 3) continue
      const ring = poly[0]
      const step = Math.max(1, Math.floor(ring.length / 600))
      let first = true
      for (let j = 0; j < ring.length; j += step) {
        const [lng, lat] = ring[j]
        const x = ((lng + 180) / 360) * w, y = ((90 - lat) / 180) * h
        if (first) { ctx.moveTo(x, y); first = false }
        else { ctx.lineTo(x, y) }
      }
      ctx.closePath()
    }
    ctx.fill()
  }
}

function updateHoverMask() {
  if (hoveredCountry === prevHoveredCountry && !needsHoverUpdate) return
  prevHoveredCountry = hoveredCountry
  needsHoverUpdate = false
  drawHoverMask(hoverCtx, TEX_W, TEX_H)
  hoverTexture.needsUpdate = true
}

// ── Border preprocessing ────────────────────────────────────────
function densifyRing(ring, maxDeg = 0.5) {
  const out = []
  for (let i = 0; i < ring.length - 1; i++) {
    const [lng1, lat1] = ring[i]
    const [lng2, lat2] = ring[i + 1]
    let dLng = lng2 - lng1
    if (Math.abs(dLng) > 180) { out.push([lng1, lat1]); continue }
    const dLat = lat2 - lat1
    const steps = Math.max(1, Math.ceil(Math.max(Math.abs(dLng), Math.abs(dLat)) / maxDeg))
    for (let s = 0; s < steps; s++) { const t = s / steps; out.push([lng1 + dLng * t, lat1 + dLat * t]) }
  }
  out.push(ring[ring.length - 1])
  return out
}

function buildDensifiedRings(data) {
  const rings = []
  for (const f of data.features || []) {
    const geom = f.geometry
    if (!geom) continue
    const polygons = geom.type === 'MultiPolygon' ? geom.coordinates : [geom.coordinates]
    for (const poly of polygons) {
      if (!poly || !poly[0] || poly[0].length < 3) continue
      rings.push(densifyRing(poly[0]))
    }
  }
  return rings
}

// ── Screen-space overlay ────────────────────────────────────────
let cameraPos = new THREE.Vector3()
let worldPos = new THREE.Vector3()
let normalWorld = new THREE.Vector3()
let ndc = new THREE.Vector3()

function drawBorderOverlay() {
  const canvas = overlayRef.value
  if (!canvas || densifiedBorderRings.length === 0) return
  const dpr = window.devicePixelRatio || 1
  const w = canvas.clientWidth, h = canvas.clientHeight
  if (w === 0 || h === 0) return
  canvas.width = w * dpr; canvas.height = h * dpr
  const ctx = canvas.getContext('2d')
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
  ctx.clearRect(0, 0, w, h)

  ctx.strokeStyle = 'rgba(255,255,255,1)'
  ctx.lineWidth = 1.2
  ctx.lineJoin = 'round'; ctx.lineCap = 'round'

  camera.getWorldPosition(cameraPos)

  // Merge all rings into one big path → single stroke call
  // prevents double-stroking on shared borders (over-brightening)
  ctx.beginPath()
  for (const ring of densifiedBorderRings) {
    let drawing = false
    for (const [lng, lat] of ring) {
      const phi = (90 - lat) * Math.PI / 180
      const theta = (lng + 180) * Math.PI / 180
      worldPos.set(-Math.sin(phi) * Math.cos(theta), Math.cos(phi), Math.sin(phi) * Math.sin(theta))
      worldPos.applyMatrix4(globeGroup.matrixWorld)
      normalWorld.copy(worldPos).normalize()
      const viewDir = cameraPos.clone().sub(worldPos).normalize()
      if (normalWorld.dot(viewDir) <= 0.005) { drawing = false; continue }
      ndc.copy(worldPos).project(camera)
      const x = (ndc.x * 0.5 + 0.5) * w
      const y = (-ndc.y * 0.5 + 0.5) * h
      if (!drawing) { ctx.moveTo(x, y); drawing = true }
      else { ctx.lineTo(x, y) }
    }
  }
  ctx.stroke()
}

// ── Interaction ────────────────────────────────────────────────
let isDragging = false
let dragPrev = { x: 0, y: 0 }
let velocity = { x: 0, y: 0 }  // inertia momentum
const raycaster = new THREE.Raycaster()
const mouse = new THREE.Vector2()

function getCanvasPos(e) {
  const rect = canvasRef.value.getBoundingClientRect()
  return { x: e.clientX - rect.left, y: e.clientY - rect.top, w: rect.width, h: rect.height }
}

function onMouseDown(e) {
  dragPrev = getCanvasPos(e)
  velocity.x = 0; velocity.y = 0
  isDragging = true
  canvasRef.value.style.cursor = 'grabbing'
}

function onMouseMove(e) {
  const pos = getCanvasPos(e)
  if (isDragging) {
    const dx = pos.x - dragPrev.x, dy = pos.y - dragPrev.y
    // Track velocity for momentum
    velocity.x = dx * 0.005
    velocity.y = dy * 0.005
    globeGroup.rotation.y += velocity.x
    globeGroup.rotation.x += velocity.y
    // Limit vertical: show all of Russia (~75°N) but not flip to poles
    globeGroup.rotation.x = Math.max(-0.4, Math.min(0.4, globeGroup.rotation.x))
    dragPrev = { x: pos.x, y: pos.y }
  }
  if (!sphereMesh || !idCanvas) return
  mouse.x = (pos.x / pos.w) * 2 - 1; mouse.y = -(pos.y / pos.h) * 2 + 1
  raycaster.setFromCamera(mouse, camera)
  const hits = raycaster.intersectObject(sphereMesh)
  if (hits.length > 0 && hits[0].uv) {
    const uv = hits[0].uv
    const ix = Math.floor(uv.x * ID_W), iy = Math.floor((1 - uv.y) * ID_H)
    if (ix >= 0 && ix < ID_W && iy >= 0 && iy < ID_H) {
      const p = idCtx.getImageData(ix, iy, 1, 1).data
      const idx = p[0] | (p[1] << 8) | (p[2] << 16)
      hoveredCountry = (idx < (geojsonData?.features?.length || 0)) ? idx : -1
    }
  } else { hoveredCountry = -1 }

  if (hoveredCountry >= 0 && geojsonData) {
    tooltipName.value = geojsonData.features[hoveredCountry].properties?.NAME_ZH || ''
    tooltipX.value = e.clientX + 14; tooltipY.value = e.clientY - 10
    tooltipVisible.value = true
  } else { tooltipVisible.value = false }
  needsHoverUpdate = true
}

function onMouseUp() { isDragging = false; canvasRef.value.style.cursor = 'grab' }
function onMouseLeave() { isDragging = false; hoveredCountry = -1; tooltipVisible.value = false; needsHoverUpdate = true; canvasRef.value.style.cursor = 'grab' }

// ── Init ────────────────────────────────────────────────────────
function initScene() {
  const canvas = canvasRef.value
  const w = GLOBE_VIEW_SIZE, h = GLOBE_VIEW_SIZE

  renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true })
  renderer.setSize(w, h); renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2))
  renderer.setClearColor(0xf5f7fa, 1)

  scene = new THREE.Scene()
  camera = new THREE.PerspectiveCamera(35, w / h, 0.1, 100)
  camera.position.set(0, 0.3, 4.5)

  globeGroup = new THREE.Group(); scene.add(globeGroup)

  // Country mask texture (binary, no mipmaps)
  maskCanvas = document.createElement('canvas'); maskCanvas.width = TEX_W; maskCanvas.height = TEX_H
  maskCtx = maskCanvas.getContext('2d')
  maskTexture = new THREE.CanvasTexture(maskCanvas)
  maskTexture.generateMipmaps = false
  maskTexture.minFilter = THREE.LinearFilter; maskTexture.magFilter = THREE.LinearFilter
  maskTexture.colorSpace = THREE.NoColorSpace

  // Hover mask texture (binary, no mipmaps)
  hoverCanvas = document.createElement('canvas'); hoverCanvas.width = TEX_W; hoverCanvas.height = TEX_H
  hoverCtx = hoverCanvas.getContext('2d')
  hoverTexture = new THREE.CanvasTexture(hoverCanvas)
  hoverTexture.generateMipmaps = false
  hoverTexture.minFilter = THREE.LinearFilter; hoverTexture.magFilter = THREE.LinearFilter
  hoverTexture.colorSpace = THREE.NoColorSpace

  // ID canvas
  idCanvas = document.createElement('canvas'); idCanvas.width = ID_W; idCanvas.height = ID_H
  idCtx = idCanvas.getContext('2d')

  const sphereGeom = new THREE.SphereGeometry(1.0, 128, 128)
  const uniforms = {
    uColorLight: { value: new THREE.Color('#8A8CFC') },
    uColorDark: { value: new THREE.Color('#4C5FF0') },
    uCountryMask: { value: maskTexture },
    uHoverMask: { value: hoverTexture },
    uDefaultOpacity: { value: 0.15 },
    uHoverOpacity: { value: 0.8 },
  }
  sphereMesh = new THREE.Mesh(sphereGeom, new THREE.ShaderMaterial({
    vertexShader, fragmentShader, uniforms, side: THREE.FrontSide,
  }))
  globeGroup.add(sphereMesh)
  globeGroup.rotation.y = THREE.MathUtils.degToRad(70)

  scene.add(new THREE.AmbientLight(0xffffff, 1))

  fetch(`${import.meta.env.BASE_URL}ne_110m_admin_0_countries.json`).then(r => r.json()).then(data => {
    geojsonData = data
    drawIdMap(idCtx, ID_W, ID_H)
    drawCountryMask(maskCtx, TEX_W, TEX_H)
    maskTexture.needsUpdate = true
    drawHoverMask(hoverCtx, TEX_W, TEX_H)
    hoverTexture.needsUpdate = true
    densifiedBorderRings = buildDensifiedRings(data)
  }).catch(err => console.error('GeoJSON failed:', err))

  animate()
}

function animate() {
  animationId = requestAnimationFrame(animate)

  // Apply inertia momentum with friction
  if (!isDragging) {
    if (Math.abs(velocity.x) > 0.0001 || Math.abs(velocity.y) > 0.0001) {
      globeGroup.rotation.y += velocity.x
      globeGroup.rotation.x += velocity.y
      globeGroup.rotation.x = Math.max(-0.4, Math.min(0.4, globeGroup.rotation.x))
      velocity.x *= 0.95
      velocity.y *= 0.95
    }
  }

  updateHoverMask()
  renderer.render(scene, camera)
  drawBorderOverlay()
}

onMounted(() => initScene())
onUnmounted(() => {
  cancelAnimationFrame(animationId)
  renderer?.dispose()
  maskTexture?.dispose(); hoverTexture?.dispose()
})
</script>

<style scoped>
.globe-container{width:100%;height:100%;display:flex;align-items:center;justify-content:center;background:#f5f7fa;overflow:hidden}
.globe-viewport{width:560px;height:560px;position:relative;flex-shrink:0}
.globe-viewport canvas{display:block;width:100%;height:100%;cursor:grab;touch-action:none}
.border-overlay{position:absolute;inset:0;pointer-events:none;z-index:2}
.country-tooltip{position:fixed;pointer-events:none;z-index:100;background:rgba(26,45,94,0.92);color:#fff;padding:6px 14px;border-radius:6px;font-size:14px;font-weight:500;white-space:nowrap;box-shadow:0 2px 12px rgba(0,0,0,0.18);transform:translateY(-100%)}
</style>