"""Compare automated groups with the fixed, manually annotated five-page reference."""
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
raw = json.loads((root/'output/raw.json').read_text())
reference = json.loads((root/'output/reference.json').read_text())
auto = json.loads((root/'output/automatic.json').read_text())
def union(lines):
    x,y = min(l['x'] for l in lines),min(l['y'] for l in lines)
    r,b = max(l['x']+l['width'] for l in lines),max(l['y']+l['height'] for l in lines)
    return dict(x=x,y=y,width=r-x,height=b-y)
def iou(a,b):
    area = max(0,min(a['x']+a['width'],b['x']+b['width'])-max(a['x'],b['x'])) * max(0,min(a['y']+a['height'],b['y']+b['height'])-max(a['y'],b['y']))
    return area/(a['width']*a['height']+b['width']*b['height']-area) if area else 0
rows=[]
for r,ref,p in zip(raw,reference,auto):
    matched=[]
    for block in ref['blocks']:
        box=union([r['lines'][i] for i in block['raw_line_indices']])
        best=max(range(len(p['blocks'])),key=lambda i:iou(box,p['blocks'][i]['box']))
        if iou(box,p['blocks'][best]['box']) >= 0.55: matched.append(best)
    good=len(matched)==len(ref['blocks']) and len(set(matched))==len(matched)
    rows.append(dict(page=p['file'],reference_blocks=len(ref['blocks']),matched=len(set(matched)),automatic_blocks=len(p['blocks']),dialogue_order_matches=good and matched==sorted(matched)))
result={'method':'Manual reference; spatial IoU >= 0.55; reading order excludes unmatched background/SFX blocks. Not a text accuracy metric.', 'pages':rows}
(root/'output/evaluation.json').write_text(json.dumps(result,ensure_ascii=False,indent=2))
print(json.dumps(result,ensure_ascii=False,indent=2))
