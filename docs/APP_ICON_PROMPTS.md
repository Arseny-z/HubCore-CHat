# App Icon — Generation Prompts

Working file with prompts for generating the new HubCore Chat app icon
via AI tools (ChatGPT/DALL-E 3, Midjourney, Stable Diffusion / Flux).
Copy any block as-is.

---

## Project context (paste this block first if the tool needs context)

> "HubCore Chat" is a peer-to-peer end-to-end encrypted messenger.
> No servers, no phone number, runs over a mesh network (Yggdrasil +
> Reticulum). Brand colours: electric blue `#2AABEE` (Telegram-blue
> accent) on a deep navy `#0E1621` base. The visual mood is technical,
> minimalist, modern — closer to Signal / Telegram / Element than to
> WhatsApp. The icon must read clearly at 48 px (Android mdpi).

---

## Output specs

What we ultimately need from the AI tool:

| Asset | Size | Format | Notes |
|---|---|---|---|
| Master icon | 1024 × 1024 | PNG (or PSD/AI if available) | Used for Play Store, App Store, and full launcher |
| Adaptive foreground | 1024 × 1024 | PNG with **transparent background** | Logo only; main element confined to centre 60% (≈ 660 × 660) so launcher masks (circle / squircle / teardrop) don't crop it |
| Adaptive background | 1024 × 1024 | PNG **or** hex colour | A solid colour (`#0E1621`) is fine; gradient PNG also OK |

**Safe-zone rule:** when generating the *foreground*, prompt
explicitly: *"main element fits within central 60% of the canvas with
margin around — outer edges may be cropped by launcher mask."*

---

## Four concept directions

| # | Name | One-liner |
|---|---|---|
| **A** | Mesh Node | A glowing central hub linked by thin lines to surrounding nodes. P2P metaphor. |
| **B** | Speech bubble × Shield | Single silhouette merging a chat bubble and a shield. Encrypted-messaging metaphor. |
| **C** | Bold H-mark | Geometric letter **H** built from network line segments. Continuity from the current HC mark. |
| **D** | Hexagon Hub | White **H** inside a hexagonal frame. Most "technical" of the four. |

Pick one, generate several variants, iterate.

---

## Prompts — ChatGPT / DALL-E 3 (natural language, full sentences)

### A — Mesh Node

```
A modern minimalist app icon for a peer-to-peer encrypted messenger
called "HubCore Chat". 1024×1024 px, square, with rounded corners
(iOS/Android style). Design: a glowing central node connected by thin
lines to six smaller nodes arranged around it, like a mesh network.
Color palette: dark navy background (#0E1621) with electric blue
(#2AABEE) accents and white highlights. Smooth gradients, soft inner
shadow on the central node, no text, no realistic imagery. Vector-
style, clean, geometric. Suitable for a launcher icon. Main element
fits within central 60% of canvas with margin around.
```

### B — Speech bubble × Shield

```
A modern app icon, 1024×1024 px, square with rounded corners. The
silhouette combines a chat speech bubble and a shield: the bubble's
bottom-right tail flows into the pointed bottom of a shield, forming
one solid silhouette. Silhouette in white, on a deep blue gradient
background (top: #2AABEE, bottom: #0E1621). Subtle glossy highlight in
the upper-left third. Minimalist, no text, vector style. Looks crisp
at 48 px. Main element fits within central 60% of canvas.
```

### C — Bold H-mark

```
A modern app icon, 1024×1024 px, square with rounded corners. Centred:
a bold geometric letter "H" constructed from straight angular line
segments, as if drawn by connecting nodes in a network. The H is white
with a thin electric-blue outline glow. Background: a smooth diagonal
gradient from #1A237E (top-left) to #0E1621 (bottom-right). No other
text, no realistic imagery, sharp vector look. Main element fits
within central 60% of canvas.
```

### D — Hexagon Hub

```
A modern app icon, 1024×1024 px, square with rounded corners. A bold
white letter "H" centred inside a hexagonal frame with a thin double
border. Soft electric-blue glow around the hexagon. Background: dark
navy (#0E1621) with a subtle radial gradient lighter in the centre.
Geometric, technical, very clean. No additional text. Vector style,
suitable for a mobile launcher. Main element fits within central 60%
of canvas.
```

---

## Prompts — Midjourney v6 (short, with parameters)

### A — Mesh Node

```
mesh network app icon, central glowing node connected by thin lines to
surrounding nodes, dark navy background, electric blue accents,
minimalist, geometric, vector style, 1024x1024, rounded square, no
text --ar 1:1 --style raw --v 6
```

### B — Speech bubble × Shield

```
app icon combining chat speech bubble and shield silhouette, white on
deep blue gradient, glossy highlight, minimalist, vector style, no
text --ar 1:1 --style raw --v 6
```

### C — Bold H-mark

```
app icon, bold geometric letter H made from connected line segments,
white with blue glow, dark navy gradient background, network theme,
minimalist, vector style, no text --ar 1:1 --style raw --v 6
```

### D — Hexagon Hub

```
app icon, white letter H inside hexagonal frame, dark navy background
with radial glow, electric blue accents, geometric technical look,
minimalist, vector --ar 1:1 --style raw --v 6
```

---

## Prompts — Stable Diffusion / Flux (tags, no params)

### A — Mesh Node

```
app icon, mesh network, central glowing node, six surrounding nodes
connected by thin lines, dark navy #0E1621 background, electric blue
#2AABEE accents, white highlights, soft inner shadow, vector style,
minimalist, geometric, rounded square, no text, no people, 1024x1024
```

### B — Speech bubble × Shield

```
app icon, speech bubble and shield combined silhouette, white
silhouette on blue gradient background, top blue #2AABEE, bottom navy
#0E1621, glossy highlight upper-left, vector style, minimalist,
rounded square, no text, no people, 1024x1024
```

### C — Bold H-mark

```
app icon, bold geometric letter H, constructed from angular line
segments, network-inspired construction, white H with thin electric
blue outline glow, diagonal gradient background from #1A237E top-left
to #0E1621 bottom-right, vector style, minimalist, rounded square, no
text other than the letter H, 1024x1024
```

### D — Hexagon Hub

```
app icon, white letter H inside hexagonal frame, thin double border,
electric blue glow around hexagon, dark navy #0E1621 background with
subtle radial gradient, geometric, technical, minimalist, vector
style, rounded square, no extra text, 1024x1024
```

---

## Foreground-only variants (transparent BG, for adaptive-icon)

If the tool can output transparent PNG, request a *foreground-only*
variant for the chosen concept. Add to any of the prompts above:

```
…transparent background, isolated subject, no rectangular border, no
rounded square, only the symbol — for use as Android adaptive-icon
foreground. The subject should occupy approximately the central 60%
of the canvas with empty transparent margin around it.
```

If the tool cannot output transparent PNG, generate on a solid
contrasting background (e.g. magenta `#FF00FF`) and remove the
background later via [`remove.bg`](https://www.remove.bg/) or
ImageMagick:

```bash
convert in.png -fuzz 8% -transparent '#FF00FF' out.png
```

---

## Iteration tips

- Generate **3–4 variants** for the chosen concept; rarely is the
  first one launcher-ready.
- After picking a winner, ask the tool to "*increase contrast at small
  size*" or "*simplify details, this will be viewed at 48 px*" — most
  models hallucinate detail that vanishes when downscaled.
- Test the candidate at small sizes manually:

  ```bash
  convert master_1024.png -resize 48x48 test_48.png
  convert master_1024.png -resize 96x96 test_96.png
  ```
- Test it as a foreground over both light and dark wallpapers (Android
  launchers vary).

---

## Where to put the final files

```
client/assets/icons/
├── icon_full.png            # 1024×1024 master
├── icon_foreground.png      # 1024×1024 transparent
└── icon_background.png      # 1024×1024 solid/gradient (or use hex via flutter_launcher_icons config)
```

The `flutter_launcher_icons` setup will then regenerate every Android
mipmap, the adaptive-icon XML, and iOS assets from those three files.
