# Adjacent passes with the same set of attachments (serial + mip level + layer) where the later one loads all of them: if the split in between is not necessary, merging saves one full load and one full store
# Every dumped frame of the log (DM_NVN_PASSDUMP=every:<n> dumps several), one summary line each, with the pass end (E row: the call site that ended the earlier pass) of each mergeable pair
import re, sys, collections
BPP={70:4,71:4,80:4,81:4,90:4,92:4,93:4,115:8,125:16,55:4,25:2,65:4,105:4,103:4,252:4,250:2,260:5,255:4,10:1,20:2,30:2,60:4,53:4}
frames=collections.OrderedDict()   # frame -> (passes, order, between, ends)
def fr(f):
    if f not in frames: frames[f]=(collections.OrderedDict(),[],collections.defaultdict(set),{})
    return frames[f]
for l in open(sys.argv[1], errors='replace'):
    l=l.strip(); i=l.find('[pass] F')
    if i<0: continue
    l=l[i:]
    m=re.match(r'\[pass\] F(\d+) P (\d+) (c\d+|d) ser=(\d+) fmt=(\d+) (\d+)x(\d+)(?:.*? lv(\d+))?(?:.*? sl(\d+))?.*?(clear|load)(?: mtl=\S+)?$',l)
    if m:
        f,p,slot,s,fmt,w,h,lv,sl,act=m.groups(); passes,order,_,_=fr(int(f)); p=int(p)
        lv=int(lv or 0); b=max(int(w)>>lv,1)*max(int(h)>>lv,1)*BPP.get(int(fmt),4)
        if p not in passes: passes[p]=[]; order.append(p)
        passes[p].append((slot,int(s),lv,int(sl or 0),act,b)); continue
    m=re.match(r'\[pass\] F(\d+) R (\d+) st\d+ ser=(\d+)',l)
    if m: fr(int(m.group(1)))[2][int(m.group(2))].add(int(m.group(3))); continue   # textures sampled in this pass
    m=re.match(r'\[pass\] F(\d+) E (\d+) pass ends in (\S+)',l)
    if m: fr(int(m.group(1)))[3][int(m.group(2))]=m.group(3)
why_all=collections.Counter()
for f,(passes,order,between,ends) in frames.items():
    key=lambda p, passes=passes: tuple(sorted((a[0],a[1],a[2],a[3]) for a in passes[p]))
    n=0; sv=0; ex=[]
    for a,b in zip(order,order[1:]):
        if key(a)==key(b) and all(x[4]=='load' for x in passes[b]):
            hazard = bool({x[1] for x in passes[a]} & between[b])   # the later pass samples its own attachment as a texture: cannot merge
            bb=sum(x[5] for x in passes[b])
            if not hazard: n+=1; sv+=2*bb; ex.append((a,b,bb)); why_all[ends.get(a,'?')]+=1
    print('frame %d: %d passes; splits between adjacent passes with the same attachments where the later pass loads them all and does not sample them: %d; merging saves %.1f MB/frame (one load and one store)'%(f,len(order),n,sv/1e6))
    for a,b,bb in ex[:12]: print('  %d→%d: %s  %.1f MB, ended in %s'%(a,b,' '.join('%s:ser%d'%(x[0],x[1]) for x in passes[b]),bb/1e6,ends.get(a,'?')))
if len(frames)>1: print('pass ends of the mergeable splits, all frames: '+', '.join('%s %d'%(k,v) for k,v in why_all.most_common()))
