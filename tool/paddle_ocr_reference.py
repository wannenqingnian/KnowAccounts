"""Host reference for the Android PP-OCR pipeline; never downloads or uploads.
Requires separately installed numpy, opencv-python-headless and onnxruntime.
Matches the Android BGR normalization, DB thresholds/rectangle expansion,
perspective crops, recognition padding and CTC decoder. Not a device test.
"""
import sys, json
from pathlib import Path
import cv2
import numpy as np
import onnxruntime as ort

def order(points):
    p=sorted(points, key=lambda p:p[0]);a=sorted(p[:2],key=lambda p:p[1]);b=sorted(p[2:],key=lambda p:p[1])
    return np.asarray([a[0],b[0],b[1],a[1]],dtype=np.float32)

def recognize(path, model_dir, tier):
    opts=ort.SessionOptions();opts.intra_op_num_threads=2;opts.inter_op_num_threads=1
    v='v4' if tier=='light' else 'v5'
    det=ort.InferenceSession(str(Path(model_dir)/f'ch_PP-OCR{v}_det_mobile.onnx'),opts,providers=['CPUExecutionProvider'])
    rec_kind='server' if tier=='accurate' else 'mobile'
    rec=ort.InferenceSession(str(Path(model_dir)/f'ch_PP-OCR{v}_rec_{rec_kind}.onnx'),opts,providers=['CPUExecutionProvider'])
    alphabet=['']+rec.get_modelmeta().custom_metadata_map['character'].split('\n')+[' ']
    image=cv2.imread(path);assert image is not None
    h,w=image.shape[:2];limit=960 if tier=='light' else 1280;scale=min(1,limit/max(h,w))
    # Java round is floor(x+.5), not Python ties-to-even.
    dh=max(32,int(h*scale/32+.5)*32);dw=max(32,int(w*scale/32+.5)*32)
    resized=cv2.resize(image,(dw,dh)).astype('float32');tensor=((resized/255-.5)/.5).transpose(2,0,1)[None]
    scores=det.run(None,{'x':tensor})[0][0,0];mh,mw=scores.shape
    contours,_=cv2.findContours((scores>.3).astype('uint8')*255,cv2.RETR_LIST,cv2.CHAIN_APPROX_SIMPLE)
    regions=[]
    for contour in contours[:1000]:
        rect=cv2.minAreaRect(contour);rw,rh=rect[1]
        if min(rw,rh)<3 or rw*rh<10:continue
        corners=cv2.boxPoints(rect);x0=max(0,int(np.floor(corners[:,0].min())));x1=min(mw-1,int(np.ceil(corners[:,0].max())));y0=max(0,int(np.floor(corners[:,1].min())));y1=min(mh-1,int(np.ceil(corners[:,1].max())))
        mask=np.zeros((y1-y0+1,x1-x0+1),np.uint8);cv2.fillPoly(mask,[(corners-[x0,y0]).astype('int32')],1)
        if cv2.mean(scores[y0:y1+1,x0:x1+1],mask)[0]<.5:continue
        distance=rw*rh*1.5/(2*(rw+rh));corners=order(cv2.boxPoints((rect[0],(rw+2*distance,rh+2*distance),rect[2])))
        corners[:,0]=np.clip(corners[:,0]*w/mw,0,w-1);corners[:,1]=np.clip(corners[:,1]*h/mh,0,h-1)
        if np.linalg.norm(corners[0]-corners[1])>3 and np.linalg.norm(corners[0]-corners[3])>3:regions.append(corners)
    assert len(regions)<=160
    lines=[]
    for corners in sorted(regions,key=lambda p:p[:,1].min()):
        cw=max(4,int(max(np.linalg.norm(corners[0]-corners[1]),np.linalg.norm(corners[2]-corners[3]))+.5));ch=max(4,int(max(np.linalg.norm(corners[0]-corners[3]),np.linalg.norm(corners[1]-corners[2]))+.5))
        target=np.asarray([[0,0],[cw-1,0],[cw-1,ch-1],[0,ch-1]],np.float32)
        crop=cv2.warpPerspective(image,cv2.getPerspectiveTransform(corners,target),(cw,ch),flags=cv2.INTER_CUBIC,borderMode=cv2.BORDER_REPLICATE)
        if ch>cw*1.5:crop=cv2.rotate(crop,cv2.ROTATE_90_COUNTERCLOCKWISE)
        actual=int(np.ceil(48*crop.shape[1]/crop.shape[0]));width=max(32,(actual+7)//8*8);assert width<=2048
        inp=np.zeros((1,3,48,width),np.float32);scaled=cv2.resize(crop,(actual,48)).astype('float32');inp[0,:,:,:actual]=((scaled/255-.5)/.5).transpose(2,0,1)
        pred=rec.run(None,{'x':inp})[0][0];assert pred.shape[1]==len(alphabet)
        ids=pred.argmax(1);conf=pred.max(1);text=[];confidence=[];last=-1
        for token,score in zip(ids,conf):
            if token and token!=last:text.append(alphabet[token]);confidence.append(float(score))
            last=token
        score=float(np.mean(confidence)) if confidence else 0
        if text and score>=.5:
            lines.append({'text':''.join(text),'left':int(corners[:,0].min()),'top':int(corners[:,1].min()),'right':int(corners[:,0].max()),'bottom':int(corners[:,1].max()),'confidence':score})
    marker=next((l for l in lines if l['left']>w*.55 and l['top']<h*.35 and any(k.lower() in l['text'].lower().replace(' ','') for k in ['查看共享链接','ChatGPT','BaseEn','Cloud'])),None)
    if marker:
        left=max(int(w*.55),marker['left']-w//25);lines=[l for l in lines if not(l['left']>=left and l['bottom']<=int(h*.35))]
    rows=[]
    for l in sorted(lines,key=lambda l:(l['top']+l['bottom'])//2):
        a=rows[-1][0] if rows else None
        gap=max(0,l['left']-max(r['right'] for r in rows[-1]),min(r['left'] for r in rows[-1])-l['right']) if a else 999999
        if a and abs(a['top']+a['bottom']-l['top']-l['bottom'])<min(a['bottom']-a['top'],l['bottom']-l['top']) and gap<=min(a['bottom']-a['top'],l['bottom']-l['top'])*2.5:rows[-1].append(l)
        else:rows.append([l])
    return {'texts':['\n'.join(' '.join(l['text'] for l in sorted(row,key=lambda l:l['left'])) for row in rows)],'lines':lines}
if __name__=='__main__':print(json.dumps(recognize(*sys.argv[1:4]),ensure_ascii=False))
