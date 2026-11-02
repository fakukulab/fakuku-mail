"""FAKUKU Mail 아이콘 레이어: 위가 열린 봉투(편지가 보인다) + 오른쪽 아래 'F' 타일 (Outlook의 'O'처럼).
Usage: python3 tools/icon_fakuku.py Icon/AppIcon.icon/Assets
Then on a Mac: ./build.sh (tools/make_icon.sh) and tools/icon_review.sh.
Layers (top to bottom in icon.json): tile.svg, pocket.svg, letter.svg, flap.svg. Canvas 1024.
"""
import sys

OUT = sys.argv[1]
W = 1024

def svg(body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{W}" viewBox="0 0 {W} {W}">\n'
            f'{body}\n</svg>\n')

# 봉투 (흰색). 둥근 모서리는 같은 색 굵은 선(round join)으로 낸다.
L, R, TOP, BOTTOM = 170, 700, 430, 790
MID = (L + R) / 2
ROUND = 'stroke="#FFFFFF" stroke-width="40" stroke-linejoin="round"'

# 열린 덮개: 봉투 위로 젖혀진 삼각형
flap = svg(f'  <polygon points="{L},{TOP} {MID},{TOP - 250} {R},{TOP}" fill="#FFFFFF" {ROUND}/>')

# 편지: 봉투에서 반쯤 나온 종이와 글 줄
letter = svg(
    f'  <rect x="{L + 70}" y="{TOP - 175}" width="{R - L - 140}" height="360" rx="28" fill="#FFFFFF"/>\n'
    f'  <rect x="{L + 125}" y="{TOP - 105}" width="{R - L - 250}" height="34" rx="17" fill="#6B4DE6" fill-opacity="0.45"/>\n'
    f'  <rect x="{L + 125}" y="{TOP - 40}" width="{R - L - 310}" height="34" rx="17" fill="#6B4DE6" fill-opacity="0.45"/>'
)

# 봉투 앞주머니: 위쪽이 V로 파인 몸통
POCKET = "#EFEAFF"  # 편지(흰색)와 구분되는 아주 옅은 보라
pocket = svg(f'  <polygon points="{L},{TOP} {MID},{TOP + 210} {R},{TOP} {R},{BOTTOM} {L},{BOTTOM}" '
             f'fill="{POCKET}" stroke="{POCKET}" stroke-width="40" stroke-linejoin="round"/>\n'
             # 봉투 접힌 선: 아래 모서리에서 가운데로 모이는 옅은 선
             f'  <polyline points="{L + 10},{BOTTOM - 10} {MID},{TOP + 260} {R - 10},{BOTTOM - 10}" fill="none" '
             f'stroke="#6B4DE6" stroke-opacity="0.18" stroke-width="12" stroke-linecap="round" stroke-linejoin="round"/>')

# 'F' 타일: 진한 파랑 둥근 사각형 위에 흰 F (Outlook의 O 타일 자리)
TX, TY, TS = 545, 505, 340
stem_x, top_y = TX + 105, TY + 72
tile = svg(
    f'  <rect x="{TX}" y="{TY}" width="{TS}" height="{TS}" rx="76" fill="#2340C8"/>\n'
    f'  <g fill="#FFFFFF">\n'
    f'    <rect x="{stem_x}" y="{top_y}" width="58" height="196" rx="10"/>\n'
    f'    <rect x="{stem_x}" y="{top_y}" width="150" height="54" rx="10"/>\n'
    f'    <rect x="{stem_x}" y="{top_y + 80}" width="124" height="50" rx="10"/>\n'
    f'  </g>'
)

for name, content in [("flap", flap), ("letter", letter), ("pocket", pocket), ("tile", tile)]:
    open(f"{OUT}/{name}.svg", "w").write(content)
print("wrote flap.svg letter.svg pocket.svg tile.svg")
