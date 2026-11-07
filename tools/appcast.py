#!/usr/bin/env python3
# 자동 업데이트(Sparkle, 1.0.2)의 새 버전 목록 site/appcast.xml 에 한 버전을 넣는다 (tools/release.sh --publish 가 부른다).
# 같은 버전이 이미 있으면 바꾸고, 새것이 맨 위. 최근 10개만 둔다.
# 사용: tools/appcast.py <appcast.xml> <버전> <빌드 번호> <DMG 주소> <sign_update 출력> [릴리스 노트 .md]
#   sign_update 출력: sparkle:edSignature="..." length="..."
# 릴리스 노트는 docs/release-notes/<버전>.md 형식: 위가 한국어, "---" 아래가 영어.
import html, re, sys
from email.utils import formatdate

def md_to_html(text):
    out, items = [], []
    def flush():
        if items:
            out.append("<ul>" + "".join(f"<li>{i}</li>" for i in items) + "</ul>")
            items.clear()
    for raw in text.strip().splitlines():
        line = raw.strip()
        if line.startswith("## "):
            continue  # 제목은 Sparkle 창에 이미 있다
        esc = html.escape(line)
        esc = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", esc)
        esc = re.sub(r"(https://[^\s<]+)", r'<a href="\1">\1</a>', esc)
        if line.startswith("- "):
            items.append(esc[2:])
        elif line:
            flush()
            out.append(f"<p>{esc}</p>")
        else:
            flush()
    flush()
    return "\n".join(out)

def main():
    if len(sys.argv) < 6:
        sys.exit(__doc__ or "usage: appcast.py <appcast.xml> <version> <build> <url> <signature> [notes.md]")
    path, version, build, url, signed = sys.argv[1:6]
    notes = sys.argv[6] if len(sys.argv) > 6 else None
    m = re.search(r'sparkle:edSignature="([^"]+)"\s+length="(\d+)"', signed)
    if not m:
        sys.exit("appcast: sign_update 출력에서 서명을 찾지 못했습니다: " + signed)
    signature, length = m.groups()
    if not re.fullmatch(r"\d+(\.\d+)*", version) or not re.fullmatch(r"\d+", build):
        sys.exit(f"appcast: 버전({version}) 또는 빌드 번호({build}) 형식이 아닙니다")

    descriptions = ""
    if notes:
        text = open(notes, encoding="utf-8").read()
        parts = re.split(r"\n---+\n", text, maxsplit=1)
        langs = ["ko", "en"]
        for lang, part in zip(langs, parts):
            descriptions += f'      <description xml:lang="{lang}"><![CDATA[\n{md_to_html(part)}\n      ]]></description>\n'

    item = (
        "    <item>\n"
        f"      <title>FAKUKU Mail {version}</title>\n"
        f"      <pubDate>{formatdate(usegmt=True)}</pubDate>\n"
        f"      <sparkle:version>{build}</sparkle:version>\n"
        f"      <sparkle:shortVersionString>{version}</sparkle:shortVersionString>\n"
        "      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>\n"
        f"{descriptions}"
        f'      <enclosure url="{html.escape(url, quote=True)}" type="application/octet-stream" '
        f'sparkle:edSignature="{signature}" length="{length}"/>\n'
        "    </item>"
    )

    try:
        old = open(path, encoding="utf-8").read()
    except FileNotFoundError:
        old = ""
    items = re.findall(r"    <item>.*?</item>", old, flags=re.S)
    items = [i for i in items if f"<sparkle:shortVersionString>{version}</sparkle:shortVersionString>" not in i]
    items = [item] + items[:9]

    doc = (
        '<?xml version="1.0" encoding="utf-8"?>\n'
        "<!-- FAKUKU Mail 자동 업데이트 목록 (Sparkle). tools/release.sh (publish) 가 쓴다: 손으로 고치지 마세요. -->\n"
        '<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">\n'
        "  <channel>\n"
        "    <title>FAKUKU Mail</title>\n"
        "    <link>https://mail.fakukulab.com/appcast.xml</link>\n"
        "    <language>ko</language>\n"
        + "\n".join(items) + "\n"
        "  </channel>\n"
        "</rss>\n"
    )
    open(path, "w", encoding="utf-8").write(doc)
    print(f"appcast: {path} 에 {version} ({build}) 를 넣었습니다")

if __name__ == "__main__":
    main()
