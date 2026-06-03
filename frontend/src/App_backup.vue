<template>
  <div class="globe-container" ref="containerRef">
    <canvas
      ref="canvasRef"
      @mousedown="onMouseDown"
      @mousemove="onMouseMove"
      @mouseup="onMouseUp"
      @mouseleave="onMouseLeave"
      @wheel.prevent="onWheel"
    ></canvas>
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

const containerRef = ref(null)
const canvasRef = ref(null)

// Tooltip state
const tooltipVisible = ref(false)
const tooltipName = ref('')
const tooltipX = ref(0)
const tooltipY = ref(0)

let renderer, scene, camera, globeGroup, borderGroup, sphereMesh
let animationId
let geojsonData = null

// Texture canvases
const TEX_W = 2048
const TEX_H = 1024
const ID_W = 2048  // upgraded for edge detection precision
const ID_H = 1024

let fillCanvas, fillCtx, fillTexture
let idCanvas, idCtx, idTexture
let hoveredCountry = -1
let prevHoveredCountry = -1
let needsTextureUpdate = false

// ── Gradient + texture shader ─────────────────────────────────
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
  uniform sampler2D uFillMap;

  void main() {
    vec3 lightDir = normalize(vec3(0.6, 0.8, 0.6));
    float diff = dot(normalize(vNormal), lightDir);
    float gradient = diff * 0.6 + 0.4;

    vec3 viewDir = normalize(cameraPosition - vWorldPosition);
    float fresnel = 1.0 - abs(dot(normalize(vNormal), viewDir));
    fresnel = pow(fresnel, 2.5) * 0.15;

    vec3 color = mix(uColorDark, uColorLight, gradient);
    color = mix(color, uColorLight, fresnel);

    vec4 fill = texture2D(uFillMap, vUv);
    color = mix(color, fill.rgb, fill.a);

    gl_FragColor = vec4(color, 1.0);
  }
`

// ── Lat/lng ↔ UV helpers ──────────────────────────────────────
function latLngToUV(lat, lng) {
  // Equirectangular: x = (lng+180)/360, y = (90-lat)/180
  let u = (lng + 180) / 360
  let v = (90 - lat) / 180
  // Handle antimeridian wrapping for convenience
  u = ((u % 1) + 1) % 1
  return { u, v }
}

function uvToLatLng(u, v) {
  const lng = u * 360 - 180
  const lat = 90 - v * 180
  return { lat, lng }
}

// ── Point-in-polygon (ray casting) ─────────────────────────────
function pointInPolygon(lng, lat, ring) {
  let inside = false
  const n = ring.length
  for (let i = 0, j = n - 1; i < n; j = i++) {
    const xi = ring[i][0], yi = ring[i][1]
    const xj = ring[j][0], yj = ring[j][1]
    if ((yi > lat) !== (yj > lat) && lng < (xj - xi) * (lat - yi) / (yj - yi) + xi) {
      inside = !inside
    }
  }
  return inside
}

function findCountryByLatLng(lat, lng) {
  if (!geojsonData) return -1
  // Handle lat/lng wrapping for features that cross antimeridian
  const features = geojsonData.features
  for (let i = 0; i < features.length; i++) {
    const geom = features[i].geometry
    if (!geom) continue
    const polygons = geom.type === 'MultiPolygon' ? geom.coordinates : [geom.coordinates]
    for (const poly of polygons) {
      if (!poly || !poly[0]) continue
      if (pointInPolygon(lng, lat, poly[0])) return i
    }
  }
  return -1
}

// ── Draw country fills on canvas ───────────────────────────────

function drawAllCountries(ctx, highlightIdx, w, h) {
  if (!geojsonData) return
  // Fill entire canvas with white (alpha=0) so edge interpolation
  // blends white→white instead of white→black (the "dark edge" fix)
  ctx.clearRect(0, 0, w, h)
  ctx.fillStyle = 'rgba(255, 255, 255, 0)'
  ctx.fillRect(0, 0, w, h)

  const features = geojsonData.features
  for (let i = 0; i < features.length; i++) {
    const fillAlpha = (i === highlightIdx) ? 0.8 : 0.3
    const geom = features[i].geometry
    if (!geom) continue

    const polygons = geom.type === 'MultiPolygon' ? geom.coordinates : [geom.coordinates]

    const drawPath = () => {
      ctx.beginPath()
      for (const poly of polygons) {
        if (!poly || !poly[0]) continue
        const ring = poly[0]
        if (ring.length < 3) continue
        const maxPts = 600
        const step = Math.max(1, Math.floor(ring.length / maxPts))
        for (let j = 0; j < ring.length; j += step) {
          const [lng, lat] = ring[j]
          const x = ((lng + 180) / 360) * w
          const y = ((90 - lat) / 180) * h
          if (j === 0) ctx.moveTo(x, y)
          else ctx.lineTo(x, y)
        }
        ctx.closePath()
      }
    }

    // Fill only - borders handled by 3D Lines for crispness
    ctx.fillStyle = `rgba(255, 255, 255, ${fillAlpha})`
    drawPath()
    ctx.fill()
  }
}

function drawIdMap(ctx, w, h) {
  if (!geojsonData) return
  // Fill with white (sentinel: 255 = ocean)
  ctx.fillStyle = '#ffffff'
  ctx.fillRect(0, 0, w, h)

  const features = geojsonData.features
  // Encode index in R channel (0-254 for countries, 255=ocean sentinel)
  for (let i = 0; i < features.length && i < 255; i++) {
    const geom = features[i].geometry
    if (!geom) continue
    ctx.fillStyle = `rgb(${i},0,0)`
    const polygons = geom.type === 'MultiPolygon' ? geom.coordinates : [geom.coordinates]

    ctx.beginPath()
    for (const poly of polygons) {
      if (!poly || !poly[0]) continue
      const ring = poly[0]
      if (ring.length < 3) continue
      const maxPts = 600
      const step = Math.max(1, Math.floor(ring.length / maxPts))
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
}

function updateFillTexture() {
  if (hoveredCountry === prevHoveredCountry && !needsTextureUpdate) return
  prevHoveredCountry = hoveredCountry
  needsTextureUpdate = false

  drawAllCountries(fillCtx, hoveredCountry, TEX_W, TEX_H)
  fillTexture.needsUpdate = true
}

// ── Mouse interaction: drag + hover ────────────────────────────
const raycaster = new THREE.Raycaster()
const mouse = new THREE.Vector2()
let isDragging = false
let dragPrev = { x: 0, y: 0 }
let dragStartTime = 0
const DRAG_THRESHOLD = 3 // px movement before considered a drag

function getCanvasPos(event) {
  const rect = canvasRef.value.getBoundingClientRect()
  return {
    x: event.clientX - rect.left,
    y: event.clientY - rect.top,
    w: rect.width,
    h: rect.height,
  }
}

function onMouseDown(event) {
  const pos = getCanvasPos(event)
  dragPrev = { x: pos.x, y: pos.y }
  dragStartTime = Date.now()
  isDragging = true
  canvasRef.value.style.cursor = 'grabbing'
}

function onMouseMove(event) {
  const pos = getCanvasPos(event)

  // ── Drag rotation ──
  if (isDragging) {
    const dx = pos.x - dragPrev.x
    const dy = pos.y - dragPrev.y
    if (Math.abs(dx) > 0 || Math.abs(dy) > 0) {
      globeGroup.rotation.y += dx * 0.005
      globeGroup.rotation.x += dy * 0.005
      // Clamp vertical rotation
      globeGroup.rotation.x = Math.max(-Math.PI / 2, Math.min(Math.PI / 2, globeGroup.rotation.x))
    }
    dragPrev = { x: pos.x, y: pos.y }
  }

  // ── Hover detection ──
  if (!sphereMesh || !idCanvas) return

  mouse.x = (pos.x / pos.w) * 2 - 1
  mouse.y = -(pos.y / pos.h) * 2 + 1

  raycaster.setFromCamera(mouse, camera)
  const intersects = raycaster.intersectObject(sphereMesh)

  if (intersects.length > 0) {
    const uv = intersects[0].uv
    if (uv) {
      const ix = Math.floor(uv.x * ID_W)
      const iy = Math.floor((1 - uv.y) * ID_H)
      if (ix >= 0 && ix < ID_W && iy >= 0 && iy < ID_H) {
        const pixel = idCtx.getImageData(ix, iy, 1, 1).data
        const idx = pixel[0]  // R channel = country index (0-254)
        hoveredCountry = (idx < 255) ? idx : -1
      }
    }
  } else {
    hoveredCountry = -1
  }

  // Tooltip
  if (hoveredCountry >= 0 && geojsonData) {
    const feat = geojsonData.features[hoveredCountry]
    tooltipName.value = feat?.properties?.NAME_ZH || feat?.properties?.NAME || ''
    tooltipX.value = event.clientX + 14
    tooltipY.value = event.clientY - 10
    tooltipVisible.value = true
  } else {
    tooltipVisible.value = false
  }

  needsTextureUpdate = true
}

function onMouseUp() {
  isDragging = false
  canvasRef.value.style.cursor = 'grab'
}

function onMouseLeave() {
  isDragging = false
  hoveredCountry = -1
  tooltipVisible.value = false
  needsTextureUpdate = true
  canvasRef.value.style.cursor = 'grab'
}

function onWheel(event) {
  // Zoom via camera distance
  const delta = event.deltaY * 0.01
  camera.position.z += delta
  camera.position.z = Math.max(2.5, Math.min(8, camera.position.z))
}

// ── Convert lat/lng to 3D point ────────────────────────────────
function latLngToVec3(lat, lng, radius) {
  const phi = (90 - lat) * (Math.PI / 180)
  const theta = (lng + 180) * (Math.PI / 180)
  return new THREE.Vector3(
    -radius * Math.sin(phi) * Math.cos(theta),
    radius * Math.cos(phi),
    radius * Math.sin(phi) * Math.sin(theta)
  )
}

// ── Build 3D border lines (vector-sharp, zero-offset) ──────────
function buildBorderLines(data, radius) {
  borderGroup.clear()

  const features = data.features || []
  
  // Custom shader for lines:
  // 1. We draw lines AT EXACTLY r=1.0, the same radius as the sphere.
  // 2. We use depthTest = true, depthWrite = false, polygonOffset = true
  // This combination guarantees lines perfectly wrap the sphere with NO floating gap,
  // and no Z-fighting.
  const lineMaterial = new THREE.LineBasicMaterial({
    color: 0xffffff,
    transparent: true,
    opacity: 0.9,
    depthWrite: false, // Don't block other lines
    polygonOffset: true,
    polygonOffsetFactor: -1, // Pull lines slightly toward camera mathematically, not physically
    polygonOffsetUnits: -1
  })

  for (const feature of features) {
    const geom = feature.geometry
    if (!geom) continue

    const polygons = geom.type === 'MultiPolygon' ? geom.coordinates : [geom.coordinates]
    for (const polygon of polygons) {
      const ring = polygon[0]
      if (!ring || ring.length < 3) continue
      const points = []
      for (let i = 0; i < ring.length; i++) {
        const [lng, lat] = ring[i]
        points.push(latLngToVec3(lat, lng, radius))
      }
      if (points.length > 2) points.push(points[0].clone())
      if (points.length > 1) {
        const lineGeo = new THREE.BufferGeometry().setFromPoints(points)
        const lineMesh = new THREE.Line(lineGeo, lineMaterial)
        lineMesh.renderOrder = 1 // Ensure lines render after the sphere
        borderGroup.add(lineMesh)
      }
    }
  }
}

// ── Init ────────────────────────────────────────────────────────
function initScene() {
  const container = containerRef.value
  const canvas = canvasRef.value
  const width = container.clientWidth
  const height = container.clientHeight

  // Renderer
  renderer = new THREE.WebGLRenderer({ canvas, antialias: true, alpha: true })
  renderer.setSize(width, height)
  renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2))
  renderer.setClearColor(0xf5f7fa, 1)

  // Scene & camera
  scene = new THREE.Scene()
  const aspect = width / height
  camera = new THREE.PerspectiveCamera(35, aspect, 0.1, 100)
  camera.position.set(0, 0.3, 4.5)
  camera.lookAt(0, 0, 0)

  // Globe group
  globeGroup = new THREE.Group()
  scene.add(globeGroup)

  // ── Canvas textures ──
  fillCanvas = document.createElement('canvas')
  fillCanvas.width = TEX_W
  fillCanvas.height = TEX_H
  fillCtx = fillCanvas.getContext('2d')

  fillTexture = new THREE.CanvasTexture(fillCanvas)
  fillTexture.magFilter = THREE.LinearFilter
  fillTexture.minFilter = THREE.LinearMipmapLinearFilter
  fillTexture.generateMipmaps = true

  idCanvas = document.createElement('canvas')
  idCanvas.width = ID_W
  idCanvas.height = ID_H
  idCtx = idCanvas.getContext('2d')

  // ── Sphere ──
  const sphereGeom = new THREE.SphereGeometry(1, 128, 128)
  const uniforms = {
    uColorLight: { value: new THREE.Color('#A8D8EA') },
    uColorDark: { value: new THREE.Color('#1A2D5E') },
    uFillMap: { value: fillTexture },
  }
  const sphereMat = new THREE.ShaderMaterial({
    vertexShader,
    fragmentShader,
    uniforms,
    side: THREE.FRONT,
  })
  sphereMesh = new THREE.Mesh(sphereGeom, sphereMat)
  globeGroup.add(sphereMesh)

  // ── Borders ──
  borderGroup = new THREE.Group()
  globeGroup.add(borderGroup)

  // Initial rotation
  globeGroup.rotation.y = THREE.MathUtils.degToRad(70)

  // Ambient light
  scene.add(new THREE.AmbientLight(0xffffff, 1))

  // Load GeoJSON
  fetch('/api/geojson')
    .then(res => res.json())
    .then(data => {
      geojsonData = data
      drawIdMap(idCtx, ID_W, ID_H)
      drawAllCountries(fillCtx, -1, TEX_W, TEX_H)
      fillTexture.needsUpdate = true
      
      // Pass the EXACT sphere radius to borders
      buildBorderLines(data, 1.0)
    })
    .catch(err => console.error('GeoJSON load failed:', err))

  window.addEventListener('resize', onResize)
  animate()
}

function onResize() {
  const container = containerRef.value
  const w = container.clientWidth
  const h = container.clientHeight
  if (w === 0 || h === 0) return
  renderer.setSize(w, h)
  camera.aspect = w / h
  camera.updateProjectionMatrix()
}

function animate() {
  animationId = requestAnimationFrame(animate)

  updateFillTexture()
  renderer.render(scene, camera)
}

onMounted(() => initScene())

onUnmounted(() => {
  cancelAnimationFrame(animationId)
  window.removeEventListener('resize', onResize)
  if (renderer) renderer.dispose()
  if (fillTexture) fillTexture.dispose()
  if (idTexture) idTexture.dispose()
})
</script>

<style scoped>
.globe-container {
  width: 100%;
  height: 100%;
  min-height: 500px;
  display: flex;
  align-items: center;
  justify-content: center;
  background: #f5f7fa;
  overflow: hidden;
  position: relative;
}

.globe-container canvas {
  display: block;
  width: 100%;
  height: 100%;
  cursor: grab;
}

.country-tooltip {
  position: fixed;
  pointer-events: none;
  z-index: 100;
  background: rgba(26, 45, 94, 0.92);
  color: #fff;
  padding: 6px 14px;
  border-radius: 6px;
  font-size: 14px;
  font-weight: 500;
  white-space: nowrap;
  box-shadow: 0 2px 12px rgba(0,0,0,0.18);
  transform: translateY(-100%);
}
</style>
