"""Host reference for Android layout/region strategy; not a device test.
Uses locally supplied images and separately downloaded Tesseract models.
"""
import csv, io, json, re, subprocess, sys, tempfile
from pathlib import Path
from PIL import Image

AMOUNTS={'实付金额','实付款','实付','实际支付','付款金额','支付金额','扣款金额','交易金额','消费金额','应付金额','合计','总计','金额'}
DATES={'支付时间','付款时间','交易时间','交易日期','扣款时间','到账时间'}
MERCHANTS={'商户全称','商户名称','商家名称','收款商户','收款方'}
ACCOUNTS={'支付方式','付款方式','付款账户','扣款账户','支付账户','支付渠道'}
KEYS=AMOUNTS|DATES|MERCHANTS|ACCOUNTS

def compact(s): return re.sub(r'\s+','',s).replace('文付方式','支付方式')
def units(s): return sum(2 if '\u3400'<=c<='\u9fff' else 1 for c in s)
def command(image,models,lang,mode,tsv=False):
    result=subprocess.run(['tesseract',str(image),'stdout','--tessdata-dir',str(models),'-l',lang,'--oem','1','--psm',str(mode),'-c','user_defined_dpi=300',*(['-c','tessedit_create_tsv=1'] if tsv else [])],capture_output=True,text=True,check=True)
    return result.stdout

def usable(key,s):
    if not s or s in KEYS or re.search('交易单号|订单号|当前状态|支付时间|交易时间',s):return False
    if key in AMOUNTS:return bool(re.fullmatch(r'[+\-−－]?[¥￥]?\d[\d,]*(?:\.\d{1,2})?(?:元)?',s))
    if key in DATES:return bool(re.search(r'20\d{2}[年./-]\d{1,2}[月./-]\d{1,2}',s))
    return 2<=len(s)<=60 and bool(re.search(r'[\u3400-\u9fffA-Za-z]',s))

def recognize(image,models,lang):
    original=Image.open(image).convert('RGB');scale=min(2,1080/original.width,(8_000_000/(original.width*original.height))**.5)
    im=original.resize((round(original.width*scale),round(original.height*scale)),Image.Resampling.BILINEAR) if scale>1.15 else original
    documents=[]
    with tempfile.TemporaryDirectory() as temp:
        path=Path(temp)/'input.png';im.save(path)
        for mode in (11,3):
            groups={}
            for w in csv.DictReader(io.StringIO(command(path,models,lang,mode,True)),delimiter='\t',quoting=csv.QUOTE_NONE):
                if w['level']!='5' or not w['text'].strip():continue
                groups.setdefault((w['block_num'],w['par_num'],w['line_num']),[]).append(w)
            lines=[]
            for words in groups.values():
                lines.append({'text':' '.join(w['text'] for w in words),'left':min(int(w['left']) for w in words),'top':min(int(w['top']) for w in words),'right':max(int(w['left'])+int(w['width']) for w in words),'bottom':max(int(w['top'])+int(w['height']) for w in words)})
            marker=next((l for l in lines if l['left']>im.width*.55 and l['top']<im.height*.35 and re.search('查看共享链接|ChatGPT|BaseEn|Cloud',compact(l['text']),re.I)),None)
            if marker:
                left=max(im.width*.55,marker['left']-im.width/25)
                lines=[l for l in lines if not (l['left']>=left and l['bottom']<=im.height*.35)]
            rows=[]
            for l in sorted(lines,key=lambda l:l['top']+l['bottom']):
                row=rows[-1] if rows else None;a=row[0] if row else None
                if a and abs(a['top']+a['bottom']-l['top']-l['bottom'])<min(a['bottom']-a['top'],l['bottom']-l['top']) and max(0,l['left']-max(v['right'] for v in row),min(v['left'] for v in row)-l['right'])<=min(a['bottom']-a['top'],l['bottom']-l['top'])*2.5:row.append(l)
                else:rows.append([l])
            combined=[]
            for row in rows:
                combined.append({'text':' '.join(v['text'] for v in sorted(row,key=lambda l:l['left'])),'left':min(v['left'] for v in row),'right':max(v['right'] for v in row),'top':min(v['top'] for v in row),'bottom':max(v['bottom'] for v in row)})
            baseline='\n'.join(l['text'] for l in combined);enhanced=[];contrasted=[]
            for row in combined:
                key=next((k for k in sorted(KEYS,key=len,reverse=True) if compact(row['text']).startswith(k)),None)
                if not key:enhanced.append(row['text']);contrasted.append(row['text']);continue
                label=next((l for l in lines if compact(l['text']).strip(':：')==key and abs(l['top']+l['bottom']-row['top']-row['bottom'])<row['bottom']-row['top']),None)
                estimated=row['left']+(row['right']-row['left'])*units(key)//max(1,units(row['text']))
                x=min(im.width-1,(label['right'] if label else estimated)+im.width//80)
                y=max(0,row['top']-(row['bottom']-row['top'])//2);h=min(im.height-y,max(12,(row['bottom']-row['top'])*2))
                crop=Path(temp)/'region.png';im.crop((x,y,im.width,y+h)).save(crop)
                value=compact(command(crop,models,lang,7))
                enhanced.append(f'{key} {value}' if usable(key,value) else row['text'])
                gray=im.crop((x,y,im.width,y+h)).convert('L');hist=gray.histogram();count=sum(hist);total=sum(i*v for i,v in enumerate(hist));weight=accum=0;maximum=-1;threshold=127
                for i,v in enumerate(hist):
                    weight+=v;accum+=i*v
                    if weight==0 or weight==count:continue
                    diff=accum/weight-(total-accum)/(count-weight);variance=weight*(count-weight)*diff*diff
                    if variance>maximum:maximum=variance;threshold=i
                gray.point(lambda p:255 if p>threshold else 0).save(crop)
                value=compact(command(crop,models,lang,7))
                contrasted.append(f'{key} {value}' if usable(key,value) else row['text'])
            documents.extend((baseline,'\n'.join(enhanced),'\n'.join(contrasted)))
    return list(dict.fromkeys(documents))
if __name__=='__main__':
    print(json.dumps(recognize(*sys.argv[1:4]),ensure_ascii=False))
