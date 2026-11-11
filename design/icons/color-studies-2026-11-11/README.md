# 菜单栏配色探索 · 2026-11-11

当前已采用 **C 翡翠绿**，运行与 TUN 的正式图片资源已替换；其他颜色保留供比较。图形保持已确认的 18pt 高度，普通槽位 24pt，TUN 槽位 28pt，保留半身猫与嵌入式镂空盾牌。当前四态设计导出位于 `../menu-bar-emerald/`，代码实际渲染结果位于 `../applied-emerald-states/`。

- Pencil 画板：主设计稿中的 `ClashBar · 菜单栏配色探索 / A–F`，节点 `N9jU3`。
- [交互对比预览](preview.html)：切换绿植示意、深色、浅色背景，实际尺寸色条保持 240×40 CSS 像素。
- [完整画板](N9jU3.png)：放大图与三种背景并列。

| 方案 | 主体 | 五官 | 五官与主体对比度 | 运行 PNG | TUN PNG |
| --- | --- | --- | --- | --- | --- |
| A 清透蓝 | `#2F86D6` | `#F8FBFF` | 3.68:1 | `ABGqz.png` | `Das0g.png` |
| B 湖水青 | `#148C85` | `#F3FFFC` | 4.01:1 | `PAR1j.png` | `ZogNA.png` |
| C 翡翠绿 | `#169568` | `#F3FFF9` | 3.70:1 | `JbTpz.png` | `faqjR.png` |
| D 薄荷绿 | `#9AE5C0` | `#13523B` | 6.24:1 | `P5yiBF.png` | `Z2y5YO.png` |
| E 珍珠白 × 墨绿 | `#EFF7F2` | `#176B51` | 5.91:1 | `MUaeW.png` | `Mif0h.png` |
| F 瓷白 × 深蓝 | `#EDF5FF` | `#2B669D` | 5.47:1 | `R9VbM.png` | `ZHci8.png` |

对比度数值仅比较不透明的五官与主体颜色，不代表任意壁纸背景上的整体可见度。D–F 增加 0.5pt 同色系细轮廓，盾牌使用五官色；A–C 盾牌使用主体色。关闭态继续展示系统模板的黑白外观，黄色轮廓继续表示异常。绿植背景为示意，原始用户截图保留在 `current-menu-reference.png`。

所有 PNG 由 Pencil 导出。TUN 镂空蒙版引用各自配色的运行 PNG，避免混入上一版灰蓝。PNG 与主设计稿的图片引用均保存在仓库内。

重新生成自包含 HTML：

```sh
python3 design/icons/color-studies-2026-11-11/build-preview.py
```
