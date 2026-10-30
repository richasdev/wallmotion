# Wallmotion — Design & Visual Identity Architecture
**macOS Native Dynamic Desktop Wallpaper Platform (macOS 14+ Sonoma / macOS 15+ Sequoia)**

---

## 1. Executive Summary & Brand Philosophy

Wallmotion is engineered as a state-of-the-art, high-performance native macOS dynamic desktop wallpaper platform. Its design identity reflects three core brand pillars:

1. **Fluid Kinetic Motion:** Desktop backgrounds designed as living art pieces—almejando reprodução fluida a 60/120 FPS suportada por Metal e AVFoundation nativo (meta de projeto e arquitetura, não uma métrica certificada sob todas as cargas de hardware).
2. **Native macOS Craftsmanship:** Wallmotion feels like it was designed in Cupertino. It adheres strictly to Apple's Human Interface Guidelines (HIG), utilizing native glassmorphism, continuous curvature squircles, system vibrant materials, and natural diffuse lighting.
3. **Invisible Lightweight Footprint:** O design visual expressa precisão sem ruído, alinhando-se à meta de projeto de manter utilização mínima e conservação de bateria em repouso e oclusão (meta de engenharia, dependente do tipo de mídia e do compositor do sistema, sem promessa de consumo zero invariante).

> [!NOTE]
> All brand assets, iconography, and documentation adhere strictly to the **Wallmotion** identity. No foreign, legacy, or cross-platform competitor names are ever referenced.

---

## 2. macOS 14+ App Icon HIG Architecture

Apple’s macOS app icon standard (introduced in Big Sur and refined in Monterey, Ventura, Sonoma, and Sequoia) defines a tactile, multi-layered visual language:

```
+--------------------------------------------------------------+
| 1024 x 1024 px Canvas                                        |
|                                                              |
|        +--------------------------------------------+        |
|        | (100, 100) -> 824 x 824 px                 |        |
|        | Base Squircle Tile (Corner Radius: ~185px) |        |
|        |                                            |        |
|        |      +------------------------------+      |        |
|        |      | Safe Optical Content Zone    |      |        |
|        |      | 640 x 640 px (Centered)      |      |        |
|        |      +------------------------------+      |        |
|        |                                            |        |
|        +--------------------------------------------+        |
|        | Contact Shadow: dy=12px, blur=12px, a=0.22 |        |
|        | Ambient Shadow: dy=28px, blur=30px, a=0.32 |        |
+--------------------------------------------------------------+
```

### 2.1 The Official Squircle Geometry
- **Outer Canvas:** `1024 × 1024 px` square.
- **Icon Tile:** Centered at `x = 100, y = 100` with dimensions `824 × 824 px`.
- **Corner Curvature:** Continuous superellipse curvature with nominal radius `r = 185 px` (~22.45% of width).
- **Safe Content Zone:** Inner `640 × 640 px` centered box to ensure zero clipping on Dock magnification and Launchpad scales.

### 2.2 Realistic macOS Lighting & Material Shading
- **Diffuse Overhead Light Source:** macOS icons feature an ambient top-to-bottom light falloff. The top rim is illuminated by a subtle specular highlight, while the bottom edge rests in soft occlusion.
- **Specular Bevel Rim (Rim Stroke):** A continuous `1.5 px – 2.0 px` stroke with a vertical linear gradient:
  - Top: `rgba(255, 255, 255, 0.40 – 0.50)`
  - Shoulder: `rgba(255, 255, 255, 0.12)`
  - Lower Half: `rgba(255, 255, 255, 0.02 – 0.05)`
  - Bottom Lip: `rgba(255, 255, 255, 0.12)` (reflecting ambient surface bounce).
- **Dual-Layer Drop Shadow:**
  1. *Contact Shadow:* `dx = 0`, `dy = 12px`, `blur = 12px`, `opacity = 0.22` (sharp contact with the Dock/Desktop).
  2. *Ambient Shadow:* `dx = 0`, `dy = 28px`, `blur = 30px`, `opacity = 0.32` (soft elevated hover elevation).
- **Physical Glass Sheen:** A subtle linear or elliptical surface gradient overlay giving the illusion of polished glass or anodized space aluminum.

---

## 3. Four Creative Concept Directions

Four distinct visual identities were created, mathematically specified, and generated as vector SVGs in `resources/branding/`:

| Concept | File | Key Theme | Visual Signature |
|---|---|---|---|
| **Concept A** | `wallmotion-concept-aurora.svg` | Kinetic Wave / Aurora | Luminous multi-tiered fluid waves in cosmic indigo glass |
| **Concept B** | `wallmotion-concept-horizon.svg` | The Desktop Horizon / Prismatic Aperture | Native macOS display window framing a glowing kinetic sun & perspective grid |
| **Concept C** | `wallmotion-concept-kinetic-w.svg` | Dual-M Fold / Kinetic W | Interlocking 3D faceted ribbon monogram ("W" & "M") |
| **Concept D** | `wallmotion-concept-minimal.svg` | Minimal Kinetic Particle / Orbital Ring | Clean circular motion loop with glowing nexus particle |

---

### Concept A: "Kinetic Wave / Aurora"
- **Asset:** `resources/branding/wallmotion-concept-aurora.svg`
- **Core Concept:** Captures the living essence of dynamic desktop wallpapers. Multiple fluid kinetic ribbon waves sweep across the dark obsidian tile, blending electric cyan into royal cobalt and neon magenta.
- **Visual Elements:**
  - Obsidian glass base tile (`#141829` to `#07090F`).
  - Layer 1: Ambient deep violet glow filter (`#7928CA` → `#FF007F`).
  - Layer 2: Oceanic cobalt wave (`#0052D4` → `#4364F7`).
  - Layer 3: High-energy electric cyan crest (`#00F2FE` → `#4FACFE`).
  - Translucent front glass ribbon creating spatial depth.
  - Fine luminous micro-particles representing individual frames of motion.
- **Best Suited For:** Flagship consumer branding, creative users, dynamic wallpaper enthusiasts who want an expressive, luminous Dock icon.

---

### Concept B: "The Desktop Horizon / Prismatic Aperture"
- **Asset:** `resources/branding/wallmotion-concept-horizon.svg`
- **Core Concept:** Represents Wallmotion as an aperture—a portal through which your Mac display unlocks infinite dynamic dimensions.
- **Visual Elements:**
  - Space Gray aluminum chassis tile with chamfered rim.
  - Stylized macOS display bezel featuring native traffic light window dots (Ruby `#FF5F56`, Amber `#FFBD2E`, Emerald `#27C93F`).
  - An inner prismatic aperture showing a radiating kinetic sun and synthetic perspective grid lines flowing forward towards the viewer.
  - Prismatic color palette: sunrise amber (`#FFF275`), neon coral (`#FF5E62`), and electric purple (`#5B144E`).
  - Diagonal glass reflection streak across the aperture screen.
- **Best Suited For:** Power users and developers who value native window/desktop system integration and retro-futuristic elegance.

---

### Concept C: "Dual-M Fold / Kinetic W & M"
- **Asset:** `resources/branding/wallmotion-concept-kinetic-w.svg`
- **Core Concept:** A geometric, typographic monogram brand mark. Interconnected faceted ribbons fold in space to form the primary letter "W" (Wall) while evoking an inverted "M" (Motion).
- **Visual Elements:**
  - Minimalist slate-dark background with subtle radial backglow.
  - 4 dimensional ribbon facets with realistic drop shadows between overlapping folds:
    - Segment 1: Cyan to Apple Blue (`#00F2FE` → `#007AFF`).
    - Segment 2: Royal Blue to Vibrant Violet (`#0066FF` → `#7928CA`).
    - Segment 3: Deep Magenta to Vivid Rose (`#8E2DE2` → `#FF2D55`).
    - Segment 4: Coral Rose to Solar Amber (`#FF2D55` → `#FFBE0B`).
  - Razor-sharp specular highlight creases on apex points.
  - High-visibility silhouette that remains 100% legible at micro sizes (16px and 32px).
- **Best Suited For:** Corporate branding, universal cross-platform collateral, App Store editorial features, and long-term brand equity.

---

### Concept D: "Minimal Kinetic Particle / Orbital Ring"
- **Asset:** `resources/branding/wallmotion-concept-minimal.svg`
- **Core Concept:** Precision engineering, performance, zero lag. Inspired by macOS native pro utilities like Activity Monitor and QuickTime, this concept features a perpetual circular kinetic sweep driven by an energy nexus particle.
- **Visual Elements:**
  - Obsidian black background tile (`#161822` → `#040508`).
  - Faint concentric wave resonator rings illustrating wallpaper refresh pulses.
  - Precision motion vector crosshairs at the cardinal points (0°, 90°, 180°, 270°).
  - Sweeping 300° tapered kinetic torus stroke in electric cyan-to-purple gradient.
  - Luminous radial kinetic particle at the apex with trailing high-speed micro-orbs.
  - Central play/motion glyphic triangle.
- **Best Suited For:** Performance purists, system utility lovers, and minimalist desk setups.

---

## 4. Color Palette & Display P3 Specification

> [!NOTE]
> A implementação atual em `BrandTheme.swift` utiliza componentes `Color(red:green:blue:)` em espaço sRGB padrão. A tabela abaixo em wide-gamut Display P3 representa uma intenção de design e especificação teórica para expansão futura com suporte nativo a color spaces avançados no SwiftUI, não estando ativa no código runtime atual.

```
+---------------------------------------------------------------------------------------+
|  Role             | Name                | Hex Code  | Display P3 (approx)             |
|-------------------|---------------------|-----------|---------------------------------|
|  Primary Kinetic  | Electric Cyan       | #00F2FE   | color(display-p3 0.12 0.94 0.98)|
|  Primary macOS    | Apple System Blue   | #007AFF   | color(display-p3 0.00 0.48 1.00)|
|  Vibrant Accent   | Kinetic Violet      | #7F00FF   | color(display-p3 0.48 0.05 0.98)|
|  Energy Crest     | Neon Rose / Coral   | #FF2D55   | color(display-p3 0.99 0.18 0.35)|
|  Warm Accent      | Sunset Amber        | #FF9500   | color(display-p3 1.00 0.58 0.00)|
|  Neutral Surface  | Obsidian Glass      | #0D0E15   | color(display-p3 0.05 0.05 0.08)|
|  Neutral Surface  | Space Slate         | #1A1C29   | color(display-p3 0.10 0.11 0.16)|
|  Specular Light   | Pure Highlight      | #FFFFFF   | color(display-p3 1.00 1.00 1.00)|
+---------------------------------------------------------------------------------------+
```

---

## 5. Typography Standards

Wallmotion typography integrates seamlessly with native macOS system fonts:

1. **Brand Titles & Window Headers:**
   - **Font:** `SF Pro Display`
   - **Weight:** `Bold` or `Heavy`
   - **Tracking:** `-0.015em` to `-0.020em` (tight, crisp optical rendering on Retina).
2. **Body, Settings, and Inspector Panels:**
   - **Font:** `SF Pro Text`
   - **Weight:** `Regular` (body) / `Semibold` (section headers).
   - **Tracking:** `0` (natural system kerning).
3. **Engine Metrics & Kinetic Indicators (FPS, CPU %, Resolution):**
   - **Font:** `SF Pro Rounded` or `SF Mono`
   - **Weight:** `Medium` / `Semibold`
   - **Purpose:** Gives real-time engine telemetry a friendly yet technical instrument feel.

---

## 6. Menu Bar Status Item Specification

The Menu Bar icon is the primary ongoing touchpoint for Wallmotion users. According to Apple HIG:
- Must be a **Template Image** (`image.isTemplate = true`). macOS automatically handles inversion (white in Dark Mode, dark graphite in Light Mode, and white with selection background when clicked).
- **Physical Canvas:** `22 × 22 pt` (`44 × 44 px` @2x Retina) and `18 × 18 pt` compact standard.
- Assets created:
  - `resources/branding/wallmotion-menubar-template.svg`: Desktop monitor frame containing a kinetic wave crest.
  - `resources/branding/wallmotion-menubar-kinetic-template.svg`: Pure kinetic ribbon "W" with active motion particle.

### Menu Bar States:
1. **Active (Playing):** Standard crisp template icon with dynamic wave.
2. **Paused:** Wave opacity dropped to `40%` or subtle slash/pause indicator.
3. **Muted / Sleep:** Outlined ring with sleep dot.

---

## 7. AppIcon.appiconset & ICNS Generation Recipe

To generate production-ready Apple `.icns` and `.appiconset` bundles from the vector SVG:

```bash
# 1. Create temporary iconset directory
mkdir -p /tmp/Wallmotion.iconset

# 2. Select chosen concept SVG (e.g., Concept A)
INPUT_SVG="resources/branding/wallmotion-concept-aurora.svg"

# 3. Export all required macOS icon resolutions
/opt/homebrew/bin/rtk rsvg-convert -w 16   -h 16   "$INPUT_SVG" -o /tmp/Wallmotion.iconset/icon_16x16.png
/opt/homebrew/bin/rtk rsvg-convert -w 32   -h 32   "$INPUT_SVG" -o /tmp/Wallmotion.iconset/icon_16x16@2x.png
/opt/homebrew/bin/rtk rsvg-convert -w 32   -h 32   "$INPUT_SVG" -o /tmp/Wallmotion.iconset/icon_32x32.png
/opt/homebrew/bin/rtk rsvg-convert -w 64   -h 64   "$INPUT_SVG" -o /tmp/Wallmotion.iconset/icon_32x32@2x.png
/opt/homebrew/bin/rtk rsvg-convert -w 128  -h 128  "$INPUT_SVG" -o /tmp/Wallmotion.iconset/icon_128x128.png
/opt/homebrew/bin/rtk rsvg-convert -w 256  -h 256  "$INPUT_SVG" -o /tmp/Wallmotion.iconset/icon_128x128@2x.png
/opt/homebrew/bin/rtk rsvg-convert -w 256  -h 256  "$INPUT_SVG" -o /tmp/Wallmotion.iconset/icon_256x256.png
/opt/homebrew/bin/rtk rsvg-convert -w 512  -h 512  "$INPUT_SVG" -o /tmp/Wallmotion.iconset/icon_256x256@2x.png
/opt/homebrew/bin/rtk rsvg-convert -w 512  -h 512  "$INPUT_SVG" -o /tmp/Wallmotion.iconset/icon_512x512.png
/opt/homebrew/bin/rtk rsvg-convert -w 1024 -h 1024 "$INPUT_SVG" -o /tmp/Wallmotion.iconset/icon_512x512@2x.png

# 4. Generate Apple .icns file
/usr/bin/iconutil -c icns /tmp/Wallmotion.iconset -o resources/branding/AppIcon.icns
```

---

## 8. Comparative Analysis & Adopted Design Direction

| Evaluation Criteria | Aurora Minimalista + W (Adotado) | Concept B (Horizon Aperture) | Concept C (Dual-M Fold) | Concept D (Minimal Orbital) |
|---|:---:|:---:|:---:|:---:|
| **Dock Prominence & Vibrancy** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐☆ | ⭐⭐⭐⭐☆ | ⭐⭐⭐⭐☆ |
| **Small-Scale Clarity (16–32px)** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐☆☆ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| **macOS HIG Alignment** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐⭐ |
| **Brand Storytelling** | ⭐⭐⭐⭐⭐ (Fluid Motion) | ⭐⭐⭐⭐⭐ (Desktop Portal) | ⭐⭐⭐⭐☆ (Monogram) | ⭐⭐⭐⭐☆ (Zero-Lag Engine) |
| **Uniqueness & Memorability**| ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐☆ | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐☆ |

### Escolha Final Adotada pelo Projeto:
- **Ícone Oficial do Aplicativo:** A direção consolidada e adotada para o Wallmotion é a **Aurora Minimalista com monograma 'W'** (`resources/branding/wallmotion-concept-aurora-minimal.svg`, empacotado como `resources/AppIcon.icns`). Essa versão aplica estritamente a paleta de 4 tons essenciais (Preto Espacial `#0A0B10`, Branco Puro `#FFFFFF`, Ciano Aurora `#00F2FE` e Violeta Aurora `#7F00FF`), sem sombras artificiais ou degradês forçados, com o monograma 'W' ocupando o quadrante superior esquerdo (~25% da área) e com pernas inferiores submersas atrás das duas linhas de fluxo harmônico em S.
- **Menu Bar Companion:** `wallmotion-menubar-template.svg` em harmonia direta com as linhas cinéticas, oferecendo contraste e adaptação nativa aos modos Claro e Escuro do macOS.
