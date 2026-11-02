#!/usr/bin/env python3
# 화면 글자 검사: 한국어 글자가 모두 L(...)로 감싸여 있고, 영어 번역이 있는지 본다.
# 사용: tools/l10n.py   (PASS l10n 이면 통과)
# 키 규칙은 Sources/ExchangeMailKit/Localization.swift와 같다: 끼워 넣은 값은 %@, 원문의 %는 %%.
import re, sys, os, json

HANGUL = re.compile(r'[가-힣]')

def decode_escapes(s):
    out=[];i=0
    while i<len(s):
        c=s[i]
        if c=='\\' and i+1<len(s):
            n=s[i+1]
            m={'n':'\n','t':'\t','r':'\r','"':'"',"'":"'",'\\':'\\','0':'\0'}
            if n in m: out.append(m[n]); i+=2; continue
            if n=='u':
                j=s.index('}',i); out.append(chr(int(s[i+3:j],16))); i=j+1; continue
            out.append(c); i+=1; continue
        out.append(c); i+=1
    return ''.join(out)

class Lit:
    def __init__(s, start, end, parts, multiline=False, raw=False):
        s.start=start; s.end=end; s.parts=parts; s.multiline=multiline; s.raw=raw
    # parts: list of ('lit', rawtext, (a,b)) or ('expr', exprtext, (a,b))
    def text(s): return ''.join(p[1] if p[0]=='lit' else '\\('+p[1]+')' for p in s.parts)
    def korean(s): return any(p[0]=='lit' and HANGUL.search(p[1]) for p in s.parts)
    def key(s):
        k=''
        for p in s.parts:
            if p[0]=='lit': k+=decode_escapes(p[1]).replace('%','%%')
            else: k+='%@'
        return k
    def has_interp(s): return any(p[0]=='expr' for p in s.parts)

def scan(src, i0=0, end=None, depth_stop=False):
    """yield top-level literals in src[i0:end]. If depth_stop, stop at unmatched ')' (for interpolation)."""
    lits=[]; i=i0; n=len(src) if end is None else end; depth=0
    while i<n:
        c=src[i]
        if src.startswith('//',i):
            j=src.find('\n',i); i=n if j<0 else j; continue
        if src.startswith('/*',i):
            d=1;i+=2
            while i<n and d:
                if src.startswith('/*',i): d+=1;i+=2
                elif src.startswith('*/',i): d-=1;i+=2
                else: i+=1
            continue
        if c=='#' and re.match(r'#+"',src[i:]):
            hashes=re.match(r'#+',src[i:]).group(0)
            q=i+len(hashes)
            if src.startswith('"""',q):
                close='"""'+hashes; j=src.index(close,q+3); lits.append(Lit(i,j+len(close),[('lit',src[q+3:j],(q+3,j))],True,True)); i=j+len(close); continue
            close='"'+hashes; j=src.index(close,q+1); lits.append(Lit(i,j+len(close),[('lit',src[q+1:j],(q+1,j))],False,True)); i=j+len(close); continue
        if c=='"':
            ml=src.startswith('"""',i)
            j=i+(3 if ml else 1); parts=[]; segstart=j
            while True:
                if ml and src.startswith('"""',j): break
                if not ml and src[j]=='"': break
                if src[j]=='\\' and src[j+1]=='(':
                    if j>segstart: parts.append(('lit',src[segstart:j],(segstart,j)))
                    # find matching paren
                    k=j+2; d=1; inner_start=k
                    sub=scan(src,k,None,True)
                    k=sub_end[0]
                    parts.append(('expr',src[inner_start:k],(inner_start,k)))
                    j=k+1; segstart=j; continue
                if src[j]=='\\': j+=2; continue
                j+=1
            if j>segstart: parts.append(('lit',src[segstart:j],(segstart,j)))
            endq=j+(3 if ml else 1)
            lits.append(Lit(i,endq,parts,ml)); i=endq; continue
        if depth_stop:
            if c=='(' : depth+=1
            elif c==')':
                if depth==0: sub_end[0]=i; return lits
                depth-=1
        i+=1
    return lits
sub_end=[0]

# ---- 검사 ----
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
# 번역하지 않는 파일: 셀프 테스트, 데모 메일 내용, 스냅숏. Siri 파일은 LocalizedStringResource라 표에 직접 넣는다.
SKIP_FILES = {'ExchangeMail/SelfTest.swift', 'ExchangeMail/Mail/DemoMailService.swift', 'ExchangeMail/Snapshot.swift',
              'ExchangeMail/Intents/MailIntents.swift'}
# 화면 글자가 아닌 한국어 (비교, 패턴, 서버에 저장되는 이름, 템플릿 자리표시자). 줄 끝에 // l10n: data 를 붙여도 된다.
DATA_CONTEXT = re.compile(r'(==|!=|\bcase|\.tag\(|AppStorage\(|forKey:|hasPrefix\(|hasSuffix\(|contains\(|range\(of:|'
                          r'components\(separatedBy:|replacingOccurrences\(of:|with:|print\(|firstIndex\(of:|starts\(with:|'
                          r'fatalError\(|precondition\(|assert\()\s*$')

def strings_table(path):
    s = open(path, encoding='utf-8').read()
    s = re.sub(r'/\*.*?\*/', '', s, flags=re.S)
    out = {}
    for m in re.finditer(r'"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)";', s):
        out[decode_escapes(m.group(1))] = m.group(2)
    return out

def check():
    table = strings_table(os.path.join(ROOT, 'Localization/en.lproj/Localizable.strings'))
    unwrapped, missing = [], []
    for dp, dn, fn in os.walk(os.path.join(ROOT, 'Sources')):
        for f in sorted(fn):
            if not f.endswith('.swift'): continue
            p = os.path.join(dp, f); rel = os.path.relpath(p, os.path.join(ROOT, 'Sources'))
            if rel in SKIP_FILES: continue
            src = open(p, encoding='utf-8').read()
            def visit(lits):
                for x in lits:
                    for part in x.parts:
                        if part[0] == 'expr': visit(scan(src, part[2][0], part[2][1]))
                    if not x.korean() or x.raw or x.multiline: continue
                    line_no = src.count('\n', 0, x.start) + 1
                    line = src.split('\n')[line_no - 1]
                    before = src[max(0, x.start - 80):x.start].split('\n')[-1]
                    if re.search(r'\bL\(\s*$', before):
                        if x.key() not in table: missing.append(f'{rel}:{line_no}: {x.key()}')
                    elif 'l10n: data' in line or DATA_CONTEXT.search(before) or re.match(r'\s*:', src[x.end:x.end + 3]) \
                            or re.search(r'\bcase\s+\w+\s*=\s*$', before):
                        continue
                    else:
                        unwrapped.append(f'{rel}:{line_no}: {x.text()[:70]}')
            visit(scan(src))
    for u in unwrapped: print('NOT WRAPPED (L(...)로 감싸거나 // l10n: data):', u)
    for m in missing: print('NO ENGLISH (Localization/en.lproj/Localizable.strings에 추가):', m)
    print('PASS l10n' if not (unwrapped or missing) else f'FAIL l10n: {len(unwrapped)} not wrapped, {len(missing)} without English')
    return 0 if not (unwrapped or missing) else 1

if __name__ == '__main__':
    sys.exit(check())
