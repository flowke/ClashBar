import base64
from pathlib import Path


ROOT = Path(__file__).resolve().parent
VARIANTS = [
    ("A", "清透蓝", "#2F86D6", "#F8FBFF", "ABGqz", "Das0g", "G3iG3n", "C5RAK", "XD67F"),
    ("B", "湖水青", "#148C85", "#F3FFFC", "PAR1j", "ZogNA", "C3KDsz", "JTby9", "lLLDv"),
    ("C", "翡翠绿", "#169568", "#F3FFF9", "JbTpz", "faqjR", "HFXtG", "kR5wS", "PMCdy"),
    ("D", "薄荷绿", "#9AE5C0", "#13523B", "P5yiBF", "Z2y5YO", "EPyVC", "Qpa2r", "iJ8kU"),
    ("E", "珍珠白 × 墨绿", "#EFF7F2", "#176B51", "MUaeW", "Mif0h", "T0S1GT", "RZqKE", "E2a3ND"),
    ("F", "瓷白 × 深蓝", "#EDF5FF", "#2B669D", "R9VbM", "ZHci8", "Vipts", "z8OnrE", "DKlqS"),
]


def image(filename):
    return "data:image/png;base64," + base64.b64encode((ROOT / filename).read_bytes()).decode("ascii")


sections = []
for code, name, body, face, run, tun, light, dark, foliage in VARIANTS:
    sections.append(f"""
    <section class="variant" aria-label="方案 {code} {name}">
      <div class="variant-heading"><h2>{code} · {name}{' · 已采用' if code == 'C' else ''}</h2><span class="swatches" aria-hidden="true"><i style="background:{body}"></i><i style="background:{face}"></i></span></div>
      <p class="colors">{body} / {face}</p>
      <div class="enlarged">
        <figure><img src="{image(run + '.png')}" width="84" height="66" alt="{name}运行态放大图"><figcaption>运行</figcaption></figure>
        <figure><img src="{image(tun + '.png')}" width="96" height="66" alt="{name}嵌入式盾牌 TUN 态放大图"><figcaption>TUN</figcaption></figure>
      </div>
      <div class="actual"><img class="menu-strip" src="{image(foliage + '.png')}" data-light="{image(light + '.png')}" data-dark="{image(dark + '.png')}" data-foliage="{image(foliage + '.png')}" width="240" height="40" alt="方案{code}，图形高度18pt，依次为关闭、运行、TUN、异常与时钟参照"></div>
    </section>""")

html = """<!doctype html>
<html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>ClashBar 菜单栏配色探索</title>
<style>
:root { color-scheme: light dark; }
* { box-sizing: border-box; }
body { margin: 0; font-family: var(--font-sans); color: var(--foreground); }
h1 { margin: 0; font-size: 24px; font-weight: 650; letter-spacing: -.025em; }
p { line-height: 1.6; }
.intro { margin: 8px 0 20px; font-size: 14px; color: var(--muted-foreground); }
.reference { display: flex; align-items: center; flex-wrap: wrap; gap: 12px 22px; margin: 0 0 22px; }
.reference img { width: 302px; height: 51px; max-width: 100%; object-fit: contain; object-position: left; }
.reference figcaption { font-size: 12px; color: var(--muted-foreground); line-height: 1.6; }
.controls { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; margin-bottom: 10px; }
.controls span { margin-right: 4px; font-size: 13px; color: var(--muted-foreground); }
button { padding: 7px 12px; border: 1px solid var(--border); border-radius: var(--radius); background: var(--background); color: var(--foreground); font: inherit; font-size: 13px; cursor: pointer; }
button[aria-pressed="true"] { background: var(--primary); color: var(--primary-foreground); border-color: var(--primary); }
button:hover { box-shadow: inset 0 0 0 1px var(--ring); }
button:focus-visible { outline: 2px solid var(--ring); outline-offset: 3px; }
.legend { margin: 0 0 20px; font-size: 12px; color: var(--muted-foreground); }
.grid { display: grid; grid-template-columns: repeat(2,minmax(0,1fr)); gap: 24px; }
.variant { min-width: 0; padding-bottom: 18px; border-bottom: 1px solid var(--border); }
.variant-heading { display:flex; align-items:center; justify-content:space-between; gap:12px; }
h2 { margin: 0; font-size: 17px; font-weight: 650; }
.colors { margin: 5px 0 12px; color: var(--muted-foreground); font-size: 12px; font-variant-numeric: tabular-nums; }
.swatches { display:flex; gap:5px; }
.swatches i { width:14px; height:14px; border:1px solid var(--border); border-radius:50%; }
.enlarged { display:flex; justify-content:center; gap:28px; padding:16px; background:var(--card); border-radius:var(--radius); }
.enlarged figure { margin:0; display:flex; flex-direction:column; align-items:center; gap:6px; }
.enlarged img { object-fit:contain; }
figcaption { font-size:11px; color:var(--muted-foreground); }
.actual { display:flex; align-items:center; justify-content:center; margin-top:12px; min-height:40px; }
.menu-strip { display:block; width:240px; height:40px; flex-shrink:0; }
.note { margin:20px 0 0; font-size:12px; color:var(--muted-foreground); }
@media(max-width:560px) { .grid { grid-template-columns:1fr; } .variant { padding-bottom:20px; } }
</style></head><body>
<h1>菜单栏图标 · 六组配色</h1>
<p class="intro">保持现在的大小与造型。上方放大看颜色，下方按 18pt 图形高度比较。</p>
<figure class="reference"><img src="REFERENCE_IMAGE" alt="用户提供的调整前菜单栏实际截图"><figcaption>调整前灰蓝色，作为对照。<br>下面的绿植色条是背景示意。</figcaption></figure>
<div class="controls" role="group" aria-label="切换菜单栏示意背景"><span>实际尺寸背景</span><button data-background="foliage" aria-pressed="true">绿植示意</button><button data-background="dark" aria-pressed="false">深色</button><button data-background="light" aria-pressed="false">浅色</button></div>
<p class="legend">色条顺序：关闭 / 运行 / TUN / 异常。D–F 用同色系细轮廓帮助浅底辨识。</p>
<div class="grid">VARIANT_SECTIONS</div>
<p class="note">运行与 TUN 的正式图片资源已切换为 C 翡翠绿；其他配色保留供比较。关闭态与黄色异常态保持原样。</p>
<script>
document.querySelectorAll('[data-background]').forEach(button => button.addEventListener('click', () => {
  const background = button.dataset.background;
  document.querySelectorAll('[data-background]').forEach(other => other.setAttribute('aria-pressed', String(other === button)));
  document.querySelectorAll('.menu-strip').forEach(strip => { strip.src = strip.dataset[background]; });
}));
</script></body></html>"""
html = html.replace("REFERENCE_IMAGE", image("current-menu-reference.png")).replace("VARIANT_SECTIONS", "".join(sections))
(ROOT / "preview.html").write_text(html, encoding="utf-8")
print(ROOT / "preview.html")
