# 3D 地球渲染方案全记录

## 需求概述

在 Three.js r173 + Vue 3 框架下，渲染一个扁平矢量风格的 3D 地球：
- 蓝色渐变海洋
- 国家白色 30% 半透明填充，悬浮高亮至 80%
- 国界线纯白 100% 不透明描边
- 鼠标拖拽旋转 + 滚轮缩放 + 悬浮显示国名

---

## 核心矛盾

Three.js 原生没有「在球面上画一个带填充 + 描边的矢量形状」的单一原语。填充和描边是两种不同的渲染概念，在 3D 场景中天然需要分开处理。所有方案的本质都是在解决**如何在两个独立元素之间消除层级距离感**。

---

## 方案一：Canvas 一体（填充 + 描边同在一张纹理上）

**做法：** 在 2048×1024 Canvas 上用 `ctx.fill()` 画国家填充，再用 `ctx.stroke()` 画描边，整张纹理贴到球面上。只有一个 Sphere Mesh，无第二层。

**结果：** ❌ **失败。** Canvas 的 `stroke()` 输出是栅格像素，受 2048×1024 分辨率限制。纹理通过 LinearFilter 采样后，1.5px 的描边线被线性插值揉开，视觉上明显模糊。Line 几何体的屏幕分辨率矢量锐利度无法在 Canvas 描边上复现。

**驳回原因：** 描边不够锐利。Canvas 纹理的分辨率瓶颈在物理上无法突破（4096×2048 也有限，且性能/内存开销翻倍）。

---

## 方案二：两层分离 + 明显物理偏移

**做法：**
- Layer 1：球体 `r=1.0`，Canvas 纹理填充 + ShaderMaterial 渐变
- Layer 2：Line 几何体 `r=1.005`，纯白不透明
- 球体加 `polygonOffset(factor=1, units=1)` 向内推

**结果：** ⚠️ **功能正常但视觉有距离感。** Line 在球体外 0.005 半径 + 球体又被 polygonOffset 向内推，双重偏移导致线明显"浮"在球面上方。用户反馈："线高一些"、"能看出差距"。

**中途变体：**
- 去掉球体 polygonOffset，线半径降到 1.001 → Z-fighting，部分线段被球面吞掉
- 线半径 1.001 + polygonOffset 纯 GPU 偏移（factor=-1, units=-1）→ 仍然有部分线段闪烁

**驳回原因：** 在"肉眼可见的层距"和"Z-fighting 闪烁"之间没有中间地带。只要线和球不是同一个半径，就必然有取舍。

---

## 方案三：Shader 边缘检测（单层纯 GPU）

**做法：**
- 球体 `r=1.0`，Fragment Shader 中同时处理海洋渐变、填充和描边
- 创建两张 2048×1024 Canvas 纹理：
  - `uFillMap`（LinearFilter）：白色填充 + 透明度（30%/80%），用于柔和混合
  - `uIdMap`（NearestFilter）：每个国家用唯一 R 通道值编码（R=0~254），海洋=255
- 在 Fragment Shader 中做四邻域像素比对：当前像素的 ID ≠ 邻居 ID → 判定为边界 → 输出纯白

**结果：** ❌ **失败。** 边缘检测输出是栅格化的——每个纹理像素要么是白色（边界）要么不是。2048 分辨率贴到球面上，边界是硬切出来的，放大后锯齿明显。尝试过 8 邻域 → 4 邻域 → 用户甚至问"0 邻域可以吗"，但边缘检测本质上是比较相邻像素，没有"0 邻域"这个概念——没有邻居就没有边缘。

**驳回原因：** 任何基于像素比对的栅格方案都无法达到矢量 Line 的平滑度。Fragment Shader 无论怎么调检测核大小，输出永远是阶梯状的。

---

## 方案四：ShapeGeometry + 顶点着色器球面包裹（真实矢量单层）

**做法：**
- 每个国家从 GeoJSON 提取坐标 → 用 `THREE.ShapeGeometry` 在 2D 平面三角化 → Mesh
- 在 Vertex Shader 中用球面映射公式把 2D 顶点"弯"到球面上：
  ```glsl
  float lon = position.x * PI / 180.0;
  float lat = position.y * PI / 180.0;
  vec3 spherePos = vec3(
    -cos(lat) * cos(lon),
     sin(lat),
     cos(lat) * sin(lon)
  );
  ```
- 同时用 `EdgesGeometry` 或 Line 提取描边
- 无 Canvas 纹理、无第二层——填充和描边是同一个几何体上的 Mesh + Line，天然同层

**结果：** ❌ **灾难性失败。** ShapeGeometry 生成的是平面三角形。对于像俄罗斯这样横跨 170° 经度的大国，ShapeGeometry 生成的是巨大的平面三角形（可能整个国家只有几十个三角面）。Vertex Shader 会把三角形的三个顶点推到球面上，但**三角形的内部面仍然是平面的**——它不会自动弯曲。结果就是：面片的边缘贴在球面上，但中央区域像一块硬纸板一样直直地切进（穿透）了球体内部。

**根本原因：** 平面三角化在宏观尺度上无法逼近弧面。要解决这个问题需要把大国细分成成千上万个足够小的三角形（每个三角形跨 < 0.5°），使得小三角形的平面足够逼近球面弧度。177 个国家递归细分出来可能是十万级三角面——虽然 GPU 能扛住，但细分逻辑复杂且三年前我们在这条路上验证过类似问题。

**驳回原因：** 大三角形切穿球体。要修需要疯狂细分，投入产出比太差。

---

## 方案五：高分辨率 Canvas + NearestFilter（纯纹理单层）

**做法：** 4096×2048 Canvas，填充 + 描边都画在上面，纹理采样禁用线性过滤（NearestFilter）。

**结果：** ❌ **理论上就不可行。** NearestFilter 会让描边锐利，但同时会把海洋渐变也变成马赛克——填充的柔和过渡和描边的锐利需求无法在同一张纹理上兼得。

**驳回原因：** 外观降级严重。渐变马赛克比描边模糊更不可接受。

---

## 最终方案：两层分离 + 最小物理偏移（r=1.002）

**做法：**

| 层 | 半径 | 技术 | 材质 |
|---|---|---|---|
| 海洋底色 | r=1.000 | SphereGeometry(128×128) | ShaderMaterial（对角线光照 + Fresnel） |
| 国家填充 | r=1.000 | Canvas 纹理（2048×1024）叠加到 Shader | `texture2D(uFillMap, vUv)` with LinearFilter |
| 国界线 | r=1.002 | Line geometries（GeoJSON 全部原始坐标） | LineBasicMaterial, depthTest:true |

**与早期方案二的关键区别：**
- **没有 polygonOffset** — 球体不做深度偏移
- **线半径从 1.005 降到 1.002** — 0.2% 半径差，在相机距离 4.5 单位下 ≈ 屏幕上 0.5px，肉眼不可分辨
- **线使用全部原始坐标** — 不抽稀。之前我们试过 `ring.length / 200` 的简化，导致俄罗斯和中国因简化率不同而边界发散。全部原始坐标保证了邻国共享边界段 100% 重叠。

**为什么 1.002？** 经实验验证：
- `r=1.000`（共面）：Z-fighting，线闪烁或被球面吞没
- `r=1.001`：大部分视角正常，但极端浅角度仍有个别线段闪烁
- `r=1.002`：所有视角稳定，且肉眼看不到浮动。这是该渲染尺度下的最小可靠偏移

**填充 Canvas 的关键细节：**

1. **填白防黑边：** 绘制国家前先用 `rgba(255,255,255,0)` 填满整张 Canvas。否则 clearRect 后底色是透明黑色 `rgba(0,0,0,0)`，LinearFilter 在国界边缘会在白色(50%)和黑色(0%)之间插值，导致格陵兰、俄罗斯、南极洲的海岸线出现暗色阴影。

2. **ID 识别 Canvas 哨兵值：** 用于悬浮检测的隐藏 ID Canvas（1024×512）必须先填满白色 `#ffffff`。如果不填，默认黑色 `(0,0,0)` 解码为索引 0 = 斐济（GeoJSON 第一个 feature），所有海洋区域都会误报为斐济。

3. **悬浮检测路径：** Raycaster 命中球体 Mesh → 获取 UV → 采样 ID Canvas → 解码 RGB 为国家索引 → 重新绘制填充 Canvas（被悬浮国 80%，其余 30%）→ `fillTexture.needsUpdate = true`

---

## 方案总览

| # | 方案 | 层数 | 填充 | 描边 | 描边清晰度 | 层距 | 结果 |
|---|---|---|---|---|---|---|---|
| 1 | Canvas 一体 | 1 | Canvas fill | Canvas stroke | ❌ 模糊 | ✅ 无 | 驳回 |
| 2 | 两层 + 大偏移 | 2 | Canvas 纹理 | Line r=1.005 | ✅ 锐利 | ❌ 可见 | 驳回 |
| 3 | Shader 边缘检测 | 1 | Canvas 纹理 | Fragment Shader | ❌ 锯齿 | ✅ 无 | 驳回 |
| 4 | ShapeGeometry 包裹 | 1 | 三角化 Mesh | EdgesGeometry | ✅ 锐利 | ✅ 无 | 驳回（穿透） |
| 5 | 高分辨率 Nearest | 1 | Canvas 纹理 | Canvas stroke | ✅ 锐利 | ✅ 无 | 驳回（渐变马赛克） |
| **6** | **两层 + 最小偏移** | **2** | **Canvas 纹理** | **Line r=1.002** | **✅ 锐利** | **✅ 微不可见** | **当前方案** |

---

## 复刻指南（最小可运行）

### 1. 依赖
```json
{ "three": "^0.173.0", "vue": "^3.5.0" }
```

### 2. 数据
Natural Earth `ne_110m_admin_0_countries.json`（110m 精度 GeoJSON），通过 HTTP 接口或静态文件提供。

### 3. 核心代码结构（伪代码）

```
initScene():
  renderer = WebGLRenderer({ antialias, alpha })
  scene = Scene()
  globeGroup = Group()

  // Layer 1+2: 海洋球 + 填充纹理
  sphereMesh = Mesh(SphereGeometry(1.0, 128, 128),
    ShaderMaterial({
      uniforms: { uColorLight: '#A8D8EA', uColorDark: '#1A2D5E', uFillMap: fillTexture },
      fragmentShader: gradient + texture2D(uFillMap) * alpha
    }))
  globeGroup.add(sphereMesh)

  // Layer 3: 边界线
  borderGroup = Group(); globeGroup.add(borderGroup)

  fetch('/geojson') → draw fills on Canvas → buildBorderLines(r=1.002)

buildBorderLines(geojson, radius):
  for each feature:
    for each polygon ring:
      points = ring.map([lng,lat] → latLngToVec3(lng, lat, radius))
      borderGroup.add(Line(BufferGeometry(points), LineBasicMaterial(white)))

latLngToVec3(lat, lng, r):
  phi = (90 - lat) * PI/180
  theta = (lng + 180) * PI/180
  return (-r*sin(phi)*cos(theta), r*cos(phi), r*sin(phi)*sin(theta))

onMouseMove:
  raycaster.intersect(sphereMesh) → UV → sample ID Canvas → country index → redraw fill Canvas
```

### 4. 关键调参项

| 参数 | 当前值 | 说明 |
|---|---|---|
| 球体半径 | 1.0 | 所有元素的基准 |
| 线半径 | 1.002 | Z-fighting 的最小可靠偏移 |
| 填充透明度 | 0.3 / 0.8 | defaultOpacity / hoverOpacity |
| Canvas 分辨率 | 2048×1024 | 填充纹理；越大越清晰但内存翻倍 |
| ID Canvas 分辨率 | 1024×512 | 悬浮检测；不影响视觉 |
| Canvas 环采样上限 | 600 点 | 每个多边形环最多采样点数 |
| 相机初始距离 | 4.5 | PerspectiveCamera(35°, aspect, 0.1, 100) |
| 拖拽灵敏度 | 0.005 | dx/dy 乘以此系数累加到 rotation |
