#!/usr/bin/env python3
"""Lists localizable string keys used in Sources/ (SwiftUI literals and String(localized:)), with interpolations as %@ / %lld."""
import re,sys,glob,json
pre=re.compile(r'(?:(?:\bText|\bButton|\bLabel|\bToggle|\bPicker|\bSection|\bMenu|\.help|\.navigationTitle|\.alert|\.confirmationDialog|\bCommandMenu|\bWindow|\bProgressView)\(|String\(localized:)\s*"')
intwords=re.compile(r'count|Count|\.files|directories')
def parse(src,i):
    # src[i] is first char after opening quote; return (key, end)
    out='';
    while True:
        c=src[i]
        if c=='"': return out,i
        if src.startswith('\\(',i):
            depth=1;j=i+2;inq=False
            while depth:
                ch=src[j]
                if inq:
                    if ch=='\\': j+=1
                    elif ch=='"': inq=False
                else:
                    if ch=='"': inq=True
                    elif ch=='(':depth+=1
                    elif ch==')':depth-=1
                j+=1
            e=src[i+2:j-1]
            isint = intwords.search(e) and not any(w in e for w in ['ByteFormat','formatted','displayName','title','name'])
            out+='%lld' if isint else '%@'
            i=j; continue
        if c=='\\':
            out+=src[i:i+2]; i+=2; continue
        out+=c; i+=1
keys={}
import os
os.chdir(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
for f in sorted(glob.glob('Sources/**/*.swift',recursive=True)):
    src=open(f).read()
    for m in pre.finditer(src):
        k,_=parse(src,m.end())
        if k.strip(): keys.setdefault(k,set()).add(f.split('/')[-1])
if '--json' in sys.argv:
    print(json.dumps(sorted(keys), ensure_ascii=False))
else:
    for k in sorted(keys): print(k)
