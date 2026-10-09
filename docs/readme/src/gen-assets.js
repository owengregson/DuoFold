// Generates every README graphic except the hero (see gen-hero.js).
// Run inside run_script:   const src = await readFile('readme/src/gen-assets.js'); await eval(src);
// Optional: set `var OUT_DIR = 'readme/_check/'` before eval to write somewhere else.
// Animated SVGs are saved twice: readme/assets/<name>.svg (the project strips <animate>) and
// readme/full/<name>.svg.txt (pristine). build-zip.js packs the pristine copies.
(async()=>{
const OUT=typeof OUT_DIR!=='undefined'?OUT_DIR:'readme/';
const P={n0:'#060B2E',n1:'#101A5C',n2:'#2A1E78',b0:'#0B1033',b1:'#1E2370',b2:'#3A3196',pink:'#FF5FA2',mag:'#D63F8C',haze:'#E0559A',peach:'#FFB08A',cream:'#FFE2C4',coral:'#FF8A7A',violet:'#6F5BFF',lav:'#8E84B8',paper:'#F6F1FF',ink:'#07041F'};
const TXT='#F4F2FF',LAV='#B4ABE6',LIL='#C9C1FF';
const SANS="-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', 'Helvetica Neue', Helvetica, Arial, sans-serif";
const DISP="-apple-system, BlinkMacSystemFont, 'SF Pro Display', 'Segoe UI', 'Helvetica Neue', Helvetica, Arial, sans-serif";
const MONO="ui-monospace, 'SF Mono', SFMono-Regular, Menlo, Consolas, monospace";
const esc=s=>String(s).replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;').replace(/"/g,'&quot;');
const r=n=>Math.round(n*100)/100,r4=n=>Math.round(n*10000)/10000,sm=t=>t*t*(3-2*t),cl=t=>Math.min(Math.max(t,0),1);
const ctx=createCanvas(10,10).getContext('2d');
const mw=(t,size,weight=400,ls=0,mono=false)=>{ctx.font=`${weight} ${size}px ${mono?'Menlo, Courier New, monospace':'Helvetica, Arial, sans-serif'}`;return ctx.measureText(t).width*1.03+ls*Math.max(t.length-1,0);};
const svg=(w,h,label,body)=>`<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}" fill="none"${label?` role="img" aria-label="${esc(label)}"`:' aria-hidden="true"'}>${body}</svg>\n`;
const T=(x,y,s,o={})=>{const{size=12,weight=400,fill=TXT,op=1,anchor='start',family=SANS,ls=0,tl=null,extra=''}=o;return `<text x="${r(x)}" y="${r(y)}" font-family="${family}" font-size="${size}" font-weight="${weight}" fill="${fill}"${op!==1?` fill-opacity="${op}"`:''}${anchor!=='start'?` text-anchor="${anchor}"`:''}${ls?` letter-spacing="${ls}"`:''}${tl?` textLength="${r(tl)}" lengthAdjust="spacing"`:''}${extra}>${s}</text>`;};
const M=(x,y,s,o={})=>T(x,y,esc(s),{family:MONO,size:9.5,ls:1.4,weight:600,...o});
const lg=(id,stops,o={})=>{const{x1=0,y1=0,x2=0,y2=1}=o;return `<linearGradient id="${id}" x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}">${stops.map(([of,c,a=1])=>`<stop offset="${r(of)}" stop-color="${c}"${a!==1?` stop-opacity="${r(a)}"`:''}/>`).join('')}</linearGradient>`;};
const rg=(id,stops)=>`<radialGradient id="${id}">${stops.map(([of,c,a=1])=>`<stop offset="${r(of)}" stop-color="${c}"${a!==1?` stop-opacity="${r(a)}"`:''}/>`).join('')}</radialGradient>`;
const blurF=(id,sd,reg='x="-30%" y="-30%" width="160%" height="160%"')=>`<filter id="${id}" ${reg} color-interpolation-filters="sRGB"><feGaussianBlur stdDeviation="${r(sd)}"/></filter>`;
const glowDefs=p=>rg(p+'pk',[[0,P.pink,.95],[.45,P.mag,.55],[1,P.mag,0]])+rg(p+'pc',[[0,P.cream,1],[.35,P.peach,.75],[1,P.coral,0]])+rg(p+'vi',[[0,P.violet,.65],[1,P.violet,0]]);
const glassDefs=p=>lg(p+'rim',[[0,'#fff',.55],[.42,'#fff',.08],[1,P.peach,.38]])+lg(p+'rimh',[[0,'#fff',.8],[.45,P.pink,.35],[1,P.pink,.7]])+lg(p+'sh',[[0,'#fff',.14],[.5,'#fff',.03],[1,'#fff',0]]);
// A frosted glass panel: the world blurred behind a clip, a tint, a top sheen and a rim.
const panel=(p,id,x,y,w,h,rad,world,blurId,o={})=>{const{rim=p+'rim',tint=.05}=o;return{defs:`<clipPath id="${id}"><rect x="${r(x)}" y="${r(y)}" width="${r(w)}" height="${r(h)}" rx="${rad}"/></clipPath>`,body:`<g clip-path="url(#${id})"><use href="#${world}" filter="url(#${blurId})"/><rect x="${r(x)}" y="${r(y)}" width="${r(w)}" height="${r(h)}" fill="#fff" fill-opacity="${tint}"/><rect x="${r(x)}" y="${r(y)}" width="${r(w)}" height="${r(h)}" fill="url(#${p}sh)"/></g><rect x="${r(x+.5)}" y="${r(y+.5)}" width="${r(w-1)}" height="${r(h-1)}" rx="${rad-.5}" stroke="url(#${rim})"/>`};};
// The night-indigo backdrop with coloured glows that every diagram sits on.
const world=(p,W,H,glows,rad=24)=>({defs:lg(p+'bg',[[0,'#241B6E'],[.6,'#121856'],[1,'#0A0E34']])+glowDefs(p)+`<clipPath id="${p}clip"><rect width="${W}" height="${H}" rx="${rad}"/></clipPath>`+lg(p+'frim',[[0,'#fff',.24],[.5,'#fff',.05],[1,P.peach,.2]])+`<g id="${p}w"><rect x="-40" y="-40" width="${W+80}" height="${H+80}" fill="url(#${p}bg)"/>${glows.map(([k,cx,cy,rx,ry,op=1])=>`<ellipse cx="${cx}" cy="${cy}" rx="${rx}" ry="${ry}" fill="url(#${p}${k})"${op!==1?` opacity="${op}"`:''}/>`).join('')}</g>`,frame:`<rect x=".5" y=".5" width="${W-1}" height="${H-1}" rx="${rad-.5}" stroke="url(#${p}frim)"/>`});
const wrap=(text,size,weight,maxW)=>{const ws=text.split(' ');const out=[];let cur='';for(const w of ws){const t=cur?cur+' '+w:w;if(mw(t,size,weight)>maxW&&cur){out.push(cur);cur=w;}else cur=t;}if(cur)out.push(cur);return out;};
const tag=(x,y,label,col=P.pink,txt='#FFC6DE')=>{const w=mw(label,8,700,1,true)+12;return `<rect x="${r(x)}" y="${r(y)}" width="${r(w)}" height="15" rx="7.5" fill="${col}" fill-opacity=".18" stroke="${col}" stroke-opacity=".55"/>`+M(x+6,y+10.5,label,{size:8,ls:1,weight:700,fill:txt});};
const tagW=label=>mw(label,8,700,1,true)+12;
// Mini screen content: traffic lights, a light window, a dark editor window, a menu bar.
const lights=(x,y,w,ins,lt)=>['#FF5F57','#FEBC2E','#28C840'].map((c,i)=>`<circle cx="${r(x+ins*.9+i*lt*2.9)}" cy="${r(y+ins*.9)}" r="${r(lt)}" fill="${c}"/>`).join('');
const win=(p,x,y,w,h,share)=>{const rad=w*.045,lt=w*.022,ins=w*.06;let s=`<rect x="${r(x)}" y="${r(y)}" width="${r(w)}" height="${r(h)}" rx="${r(rad)}" fill="${P.paper}" fill-opacity=".96" filter="url(#${p}ws)"/>`+lights(x,y,w,ins,lt);const ph=h*share,py=y+h-ins-ph;s+=`<rect x="${r(x+ins)}" y="${r(py)}" width="${r(w-2*ins)}" height="${r(ph)}" rx="${r(w*.02)}" fill="url(#${p}ph)"/>`;const lh=w*.04;let ly=y+ins*.9+lt+lh*1.4;for(const f of [.9,.66,.8,.52,.72]){if(ly+lh>py-lh*.8)break;s+=`<rect x="${r(x+ins)}" y="${r(ly)}" width="${r((w-2*ins)*f)}" height="${r(lh)}" rx="${r(lh/2)}" fill="${P.lav}" fill-opacity=".65"/>`;ly+=lh*2;}return s;};
let seed=7;const rnd=()=>(seed=(seed*16807)%2147483647)/2147483647;
const edwin=(p,x,y,w,h)=>{seed=11;const rad=w*.04,lt=w*.022,ins=w*.06;let s=`<rect x="${r(x)}" y="${r(y)}" width="${r(w)}" height="${r(h)}" rx="${r(rad)}" fill="#1A1B36" fill-opacity=".97" filter="url(#${p}ws)"/><rect x="${r(x+.5)}" y="${r(y+.5)}" width="${r(w-1)}" height="${r(h-1)}" rx="${r(rad)}" stroke="#fff" stroke-opacity=".12"/>`+lights(x,y,w,ins,lt);
 const sb=w*.26;s+=`<rect x="${r(x+sb)}" y="${r(y+ins*1.9)}" width="1" height="${r(h-ins*2.4)}" fill="#fff" fill-opacity=".08"/>`;const lh=Math.max(w*.02,1.2);
 for(let i=0;i<7;i++){const yy=y+ins*2.4+i*lh*2.4;if(yy>y+h-ins)break;s+=`<rect x="${r(x+ins*.9+(i%3?lh*1.5:0))}" y="${r(yy)}" width="${r(sb*(.45+rnd()*.3))}" height="${r(lh)}" rx="${r(lh/2)}" fill="${i===2?P.pink:P.lav}" fill-opacity="${i===2?.8:.45}"/>`;}
 const cols=[P.pink,P.peach,LIL,P.cream,P.lav];for(let i=0;;i++){const yy=y+ins*2.4+i*lh*2;if(yy>y+h-ins*1.1)break;let xx=x+sb+ins*.7+(i%4===0?0:lh*2*Math.floor(1+rnd()*3));const segs=1+Math.floor(rnd()*3);for(let k=0;k<segs;k++){const ww=w*(.05+rnd()*.14);if(xx+ww>x+w-ins)break;s+=`<rect x="${r(xx)}" y="${r(yy)}" width="${r(ww)}" height="${r(lh)}" rx="${r(lh/2)}" fill="${cols[Math.floor(rnd()*5)]}" fill-opacity=".85"/>`;xx+=ww+lh*1.2;}}
 return s;};
const menubar=(x,y,w,h)=>{let s=`<rect x="${r(x)}" y="${r(y)}" width="${r(w)}" height="${r(h)}" fill="#fff" fill-opacity=".13"/>`;const bh=h*.28,by=y+(h-bh)/2;let xx=x+h*.8;s+=`<circle cx="${r(xx)}" cy="${r(y+h/2)}" r="${r(h*.2)}" fill="#fff" fill-opacity=".85"/>`;xx+=h*.7;for(const f of [1.5,1.2,1.3,1.6,1.1]){s+=`<rect x="${r(xx)}" y="${r(by)}" width="${r(h*f)}" height="${r(bh)}" rx="${r(bh/2)}" fill="#fff" fill-opacity="${xx<x+h*2?.85:.6}"/>`;xx+=h*f+h*.6;}let rx_=x+w-h*.8;for(const f of [2.2,.7,.7,.7]){rx_-=h*f;s+=`<rect x="${r(rx_)}" y="${r(by)}" width="${r(h*f)}" height="${r(bh)}" rx="${r(bh/2)}" fill="#fff" fill-opacity=".7"/>`;rx_-=h*.55;}return s;};
const winDefs=(p,dy=8,sd=12)=>`<filter id="${p}ws" x="-25%" y="-25%" width="150%" height="160%"><feDropShadow dx="0" dy="${dy}" stdDeviation="${sd}" flood-color="#0A0530" flood-opacity=".5"/></filter>`+lg(p+'ph',[[0,'#FFA27E'],[.5,'#E0559A'],[1,'#7B5CFF']],{x2:1,y2:1});
// Frost bands up a picture (FrostBandLayout): n blurred copies, each masked in where its height begins.
function frost(p,href,X,Y,Wd,Ht,sH,sR,n,ua=''){let defs='',body='';if(sH>.25){defs+=blurF(p+'f0',sH);body+=`<use href="#${href}"${ua} filter="url(#${p}f0)"/>`;}let prev=0;for(let i=1;i<=n;i++){const s=sH+sR*i/n,h=Math.pow(i/n,1/2.25),id=p+'b'+i;defs+=blurF(id+'f',s)+`<linearGradient id="${id}g" gradientUnits="userSpaceOnUse" x1="0" y1="${r(Y+Ht)}" x2="0" y2="${r(Y)}"><stop offset="${r(prev)}" stop-color="#fff" stop-opacity="0"/><stop offset="${r(h)}" stop-color="#fff"/></linearGradient><mask id="${id}m" maskUnits="userSpaceOnUse" x="${r(X)}" y="${r(Y)}" width="${r(Wd)}" height="${r(Ht)}"><rect x="${r(X)}" y="${r(Y)}" width="${r(Wd)}" height="${r(Ht)}" fill="url(#${id}g)"/></mask>`;body+=`<g mask="url(#${id}m)"><use href="#${href}"${ua} filter="url(#${id}f)"/></g>`;prev=h;}return{defs,body};}
// Dimming up the glass (BlurGradient.dimming).
const dimGrad=(id,Y,Ht,maxD,reach,color='#000',floor=.2)=>{let st='';for(let k=0;k<=10;k++){const h=k/10,t=Math.min(h/Math.max(reach,.02),1),d=Math.min(maxD*(floor+(1-floor)*sm(t)),1);st+=`<stop offset="${h}" stop-color="${color}" stop-opacity="${r(d)}"/>`;}return `<linearGradient id="${id}" gradientUnits="userSpaceOnUse" x1="0" y1="${r(Y+Ht)}" x2="0" y2="${r(Y)}">${st}</linearGradient>`;};
// The app's ramp math (LidEffectRamp / BlurGradient), Balanced preset: start 85°, span 65°, max lean 70°, recession 1.
const prog=(a,s=85,span=65)=>Math.min(Math.max((s-a)/span,0),1);
const blurS=p=>Math.pow(Math.pow(p,1.6),1.2), dimS=p=>Math.pow(p,.7);
const soft=(v,lim,k)=>v<=lim-k?v:v>=lim+k?lim:v-(v-(lim-k))**2/(4*k);
const held=(a,s=85,span=65,maxLean=70,rec=1)=>{const tr=s-a;if(tr<=0)return 0;const lt=rec>0?Math.max(maxLean,1)/rec:Infinity;return Math.min(lt===Infinity?tr:soft(tr,lt,lt/4),span);};
// A lid that closes from o to s and opens again over one animation loop.
const lidAt=(t,o,s)=>t<.08?o:t<.48?o+(s-o)*sm((t-.08)/.4):t<.64?s:t<.94?s+(o-s)*sm((t-.64)/.3):o;
const KT=N=>Array.from({length:N+1},(_,i)=>r4(i/N)).join(';');
const anim=(attr,N,f,dur)=>`<animate attributeName="${attr}" values="${Array.from({length:N+1},(_,i)=>r(f(i/N))).join(';')}" keyTimes="${KT(N)}" dur="${dur}" repeatCount="indefinite"/>`;
const rquad=(pts,radii)=>{let d='';const n=pts.length;for(let i=0;i<n;i++){const pv=pts[(i+n-1)%n],c=pts[i],nx=pts[(i+1)%n],rr=radii[i];const tow=(t,dist)=>{const dx=t[0]-c[0],dy=t[1]-c[1],l=Math.hypot(dx,dy);return[c[0]+dx/l*dist,c[1]+dy/l*dist];};const e=tow(pv,rr),x=tow(nx,rr);d+=(i?'L':'M')+r(e[0])+' '+r(e[1])+'Q'+r(c[0])+' '+r(c[1])+' '+r(x[0])+' '+r(x[1]);}return d+'Z';};
const mix=(c1,c2,t)=>{const h=s=>[1,3,5].map(i=>parseInt(s.slice(i,i+2),16));const a=h(c1),bb=h(c2);return '#'+a.map((v,i)=>Math.round(v+(bb[i]-v)*t).toString(16).padStart(2,'0')).join('');};
const LIC='<!-- Icon: Lucide, ISC License, https://lucide.dev -->';
const L={download:'<path d="M12 15V3"/><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><path d="m7 10 5 5 5-5"/>',archive:'<rect width="20" height="5" x="2" y="3" rx="1"/><path d="M4 8v11a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8"/><path d="M10 12h4"/>',package:'<path d="M11 21.73a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73z"/><path d="M12 22V12"/><polyline points="3.29 7 12 12 20.71 7"/><path d="m7.5 4.27 9 5.15"/>'};
const ico=(n,x,y,size,color,sw=1.75)=>`<g transform="translate(${r(x)} ${r(y)}) scale(${r4(size/24)})" stroke="${color}" stroke-width="${r(sw*24/size)}" stroke-linecap="round" stroke-linejoin="round" fill="none">${L[n]}</g>`;
const full={},stat={};

// ---------- SECTION HEADERS (dark + light; GitHub picks via <picture>) ----------
const headers=[['presets','01','PRESETS'],['fold','02','THE FOLD'],['haptics','03','HAPTICS'],['technical','04','TECHNICAL DESIGN'],['settings','05','SETTINGS'],['developers','06','DEVELOPERS']];
for(const[slug,idx,label]of headers)for(const mode of ['dark','light']){const dk=mode==='dark';const fs=12.5,ls=3,lw=mw(label,fs,700,ls),iw=mw(idx,11,600,1,true);const capW=Math.round(20+iw+10+4+10+lw+22),line=64,gap=12,H=60,ch=38,cy=11,W=line*2+gap*2+capW,x0=line+gap,mid=cy+ch/2;const hc=dk?LAV:'#B9B3E6';
 const d=lg('hl',[[0,hc,0],[1,hc,dk?.6:.9]],{x2:1,y2:0})+lg('hr',[[0,hc,dk?.6:.9],[1,hc,0]],{x2:1,y2:0})+rg('gl',dk?[[0,P.pink,.32],[.55,P.violet,.14],[1,P.violet,0]]:[[0,P.pink,.24],[.55,P.violet,.1],[1,P.violet,0]])+lg('rim',dk?[[0,'#fff',.55],[.5,'#fff',.08],[1,P.peach,.45]]:[[0,'#fff',1],[.5,'#fff',.6],[1,'#B9B3E6',.95]])+lg('sh',[[0,'#fff',dk?.16:.7],[.55,'#fff',dk?.03:.2],[1,'#fff',0]])+lg('hi',[[0,'#fff',0],[.5,'#fff',dk?.55:1],[1,'#fff',0]],{x2:1,y2:0})+lg('dg',[[0,P.peach],[1,P.violet]],{x2:1,y2:1});
 let b=`<rect x="0" y="${mid-.5}" width="${line}" height="1" fill="url(#hl)"/><rect x="${W-line}" y="${mid-.5}" width="${line}" height="1" fill="url(#hr)"/><ellipse cx="${W/2}" cy="${mid+5}" rx="${r(capW*.52)}" ry="24" fill="url(#gl)"/>`;
 if(!dk)b+=`<rect x="${x0+6}" y="${cy+6}" width="${capW-12}" height="${ch}" rx="${ch/2}" fill="#1E2370" fill-opacity=".06"/>`;
 b+=`<rect x="${x0}" y="${cy}" width="${capW}" height="${ch}" rx="${ch/2}" fill="${dk?'#16153F':'#FFFFFF'}" fill-opacity="${dk?.62:.82}"/><rect x="${x0}" y="${cy}" width="${capW}" height="${ch}" rx="${ch/2}" fill="url(#sh)"/><rect x="${x0+.5}" y="${cy+.5}" width="${capW-1}" height="${ch-1}" rx="${ch/2-.5}" stroke="url(#rim)"/><rect x="${x0+ch/2}" y="${cy+1.5}" width="${capW-ch}" height="1" fill="url(#hi)"/>`;
 b+=M(x0+20,mid+4,idx,{size:11,ls:1,fill:dk?P.pink:P.mag,tl:iw-1})+`<circle cx="${r(x0+20+iw+12)}" cy="${mid}" r="2.2" fill="url(#dg)"/>`+T(x0+20+iw+24,mid+4.5,esc(label),{size:fs,weight:700,ls,fill:dk?'#EDEBFF':P.b1,tl:lw});
 stat[`headers/${slug}-${mode}.svg`]=svg(W,H,label.charAt(0)+label.slice(1).toLowerCase(),`<defs>${d}</defs>${b}`);}

// ---------- BUTTONS ----------
const btns=[['dmg','Download DMG','download',true],['releases','All releases','package',false]];
for(const[slug,label,icn,pri]of btns)for(const mode of ['dark','light']){const dk=mode==='dark';const fs=14,tw=mw(label,fs,600,.2),pad=22,isz=18,ig=10;const pw=Math.round(pad+isz+ig+tw+pad),ph=46,mx=24,py=12,W=pw+2*mx,H=80,px=mx;
 let d=lg('sh',[[0,'#fff',pri?.42:(dk?.16:.7)],[.5,'#fff',pri?.08:(dk?.03:.2)],[1,'#fff',0]])+lg('fl',[[0,'#FF9A7E'],[.5,'#E0559A'],[1,'#7B5CFF']],{x2:1,y2:0})+blurF('sb',6,'x="-30%" y="-80%" width="160%" height="260%"');let b='';
 const shadow=(fill,op)=>`<rect x="${px+14}" y="${py+14}" width="${pw-28}" height="${ph-12}" rx="${(ph-12)/2}" fill="${fill}" opacity="${op}" filter="url(#sb)"/>`;
 if(pri){d+=lg('rim',[[0,'#fff',.8],[.5,'#fff',.15],[1,'#fff',.4]]);b+=shadow('url(#fl)',dk?.75:.55)+`<rect x="${px}" y="${py}" width="${pw}" height="${ph}" rx="${ph/2}" fill="url(#fl)"/>`;}
 else{d+=lg('rim',dk?[[0,'#fff',.5],[.5,'#fff',.08],[1,P.peach,.42]]:[[0,'#fff',1],[.5,'#fff',.6],[1,'#C9C3EE',1]]);b+=shadow(dk?P.violet:'#1E2370',dk?.45:.16)+`<rect x="${px}" y="${py}" width="${pw}" height="${ph}" rx="${ph/2}" fill="${dk?'#1A1846':'#FFFFFF'}" fill-opacity="${dk?.72:.92}"/>`;}
 b+=`<rect x="${px}" y="${py}" width="${pw}" height="${ph}" rx="${ph/2}" fill="url(#sh)"/><rect x="${px+.5}" y="${py+.5}" width="${pw-1}" height="${ph-1}" rx="${ph/2-.5}" stroke="url(#rim)"/>`;
 const tc=pri?'#FFFFFF':(dk?'#EDEBFF':P.b1),ic=pri?'#FFFFFF':(dk?P.peach:P.mag);
 b+=ico(icn,px+pad,py+(ph-isz)/2,isz,ic,1.9)+T(px+pad+isz+ig,py+ph/2+5,esc(label),{size:fs,weight:600,ls:.2,fill:tc,tl:tw});
 stat[`buttons/${slug}-${mode}.svg`]=svg(W,H,label,LIC+`<defs>${d}</defs>${b}`);}

// ---------- DIVIDER ----------
for(const mode of ['dark','light']){const dk=mode==='dark',c=dk?LAV:'#B9B3E6';const d=lg('l',[[0,c,0],[1,c,dk?.6:.9]],{x2:1,y2:0})+lg('rr',[[0,c,dk?.6:.9],[1,c,0]],{x2:1,y2:0})+blurF('b1',.9)+blurF('b2',2);
 stat[`divider-${mode}.svg`]=svg(260,28,'',`<defs>${d}</defs><rect x="0" y="13.5" width="102" height="1" fill="url(#l)"/><rect x="158" y="13.5" width="102" height="1" fill="url(#rr)"/><circle cx="116" cy="14" r="4" fill="${P.peach}"/><circle cx="130" cy="14" r="4" fill="${P.pink}" opacity=".85" filter="url(#b1)"/><circle cx="144" cy="14" r="4.2" fill="${P.violet}" opacity=".75" filter="url(#b2)"/>`);}

// ---------- ANATOMY (The fold: front + side view, animated) ----------
{const W=860,H=400,p='a',N=96,dur='9s';const wd=world(p,W,H,[['pk',720,60,300,220],['pc',120,420,320,220],['vi',440,180,260,200],['pk',300,380,220,140,.5]]);
 let d=wd.defs+glassDefs(p)+winDefs(p,4,6)+blurF('apb',24);let b=`<g clip-path="url(#aclip)"><use href="#aw"/>`;
 const L1=panel(p,'ap1',16,16,532,368,22,'aw','apb'),L2=panel(p,'ap2',560,16,284,368,22,'aw','apb');d+=L1.defs+L2.defs;b+=L1.body+L2.body;
 b+=M(40,46,'FRONT VIEW',{fill:P.pink})+M(40+mw('FRONT VIEW',9.5,600,1.4,true)+6,46,'· BALANCED, FULL STRENGTH',{fill:LAV});
 const DX=48,DY=70,DW=336,DH=220;
 d+=lg('awp',[[0,P.n0],[.45,P.n1],[1,P.n2]])+`<clipPath id="adc"><rect x="${DX}" y="${DY}" width="${DW}" height="${DH}" rx="4"/></clipPath>`;
 d+=`<g id="asw"><rect x="${DX-30}" y="${DY-30}" width="${DW+60}" height="${DH+60}" fill="url(#awp)"/><ellipse cx="${r(DX+.78*DW)}" cy="${r(DY+.82*DH)}" rx="${r(.62*DW)}" ry="${r(.55*DH)}" fill="url(#apk)"/><ellipse cx="${r(DX+.12*DW)}" cy="${r(DY+1.05*DH)}" rx="${r(.55*DW)}" ry="${r(.5*DH)}" fill="url(#apc)"/><ellipse cx="${r(DX+.3*DW)}" cy="${r(DY+.38*DH)}" rx="${r(.3*DW)}" ry="${r(.32*DH)}" fill="url(#avi)"/>${menubar(DX,DY,DW,9)}${win(p,DX+.53*DW,DY+.11*DH,.37*DW,.42*DH,.42)}${win(p,DX+.09*DW,DY+.37*DH,.48*DW,.56*DH,.4)}</g>`;
 const k=DH/982,far=55*2/3,sH=far*.05*k,sR=far*.95*k;const f=frost('af','asw',DX,DY,DW,DH,sH,sR,8);d+=f.defs+dimGrad('adim',DY,DH,.55,.55);
 b+=`<rect x="40" y="62" width="352" height="236" rx="12" fill="#0A0B10" stroke="#A4A9BA" stroke-opacity=".5"/><g clip-path="url(#adc)"><use href="#asw"/>${f.body}<rect x="${DX}" y="${DY}" width="${DW}" height="${DH}" fill="url(#adim)"/></g>`;
 d+=lg('alu',[[0,'#F7F8FB'],[.4,'#C4C8D4'],[1,'#7C8194']]);b+=`<rect x="30" y="299" width="372" height="8" rx="4" fill="url(#alu)"/>`;
 const PX0=410,PX1=520,PY1=DY+DH;let pb='',pd='';for(let i=0;i<=50;i++){const h=i/50,y=PY1-h*DH;pb+=`${i?'L':'M'}${r(PX0+(PX1-PX0)*(.05+.95*Math.pow(h,2.25)))} ${r(y)}`;pd+=`${i?'L':'M'}${r(PX0+(PX1-PX0)*(.2+.8*sm(Math.min(h/.55,1))))} ${r(y)}`;}
 d+=lg('aar',[[0,P.pink,.05],[1,P.pink,.32]],{x2:1,y2:0});
 b+=`<path d="${pb}L${PX0} ${DY}L${PX0} ${PY1}Z" fill="url(#aar)"/><line x1="${PX0}" y1="${DY}" x2="${PX0}" y2="${PY1}" stroke="#fff" stroke-opacity=".3"/><line x1="${PX1}" y1="${DY}" x2="${PX1}" y2="${PY1}" stroke="#fff" stroke-opacity=".1" stroke-dasharray="2 4"/><line x1="${(PX0+PX1)/2}" y1="${DY}" x2="${(PX0+PX1)/2}" y2="${PY1}" stroke="#fff" stroke-opacity=".07" stroke-dasharray="2 4"/><path d="${pb}" stroke="${P.pink}" stroke-width="2.2" stroke-linecap="round"/><path d="${pd}" stroke="${LIL}" stroke-width="1.8" stroke-dasharray="4 3" stroke-linecap="round"/>`;
 b+=M(PX0,DY-8,'FAR EDGE',{size:8.5,fill:LAV})+M(PX0,PY1+17,'HINGE',{size:8.5,fill:LAV});
 b+=`<line x1="40" y1="333" x2="56" y2="333" stroke="${P.pink}" stroke-width="2.4" stroke-linecap="round"/>`+T(64,337,`Blur rises with height<tspan font-size="8.5" dy="-5">2.25</tspan><tspan dy="5">: almost none at the hinge, strongest at the top.</tspan>`,{size:12,op:.82});
 b+=`<line x1="40" y1="355" x2="56" y2="355" stroke="${LIL}" stroke-width="2" stroke-dasharray="4 3"/>`+T(64,359,'Dimming eases in from the hinge and holds from mid-height up.',{size:12,op:.82});
 b+=M(40,376,'BLUR DRAWN TO SCALE FOR A 14-INCH SCREEN',{size:8,fill:LAV,ls:1.1});
 b+=M(584,46,'SIDE VIEW',{fill:P.pink})+M(584+mw('SIDE VIEW',9.5,600,1.4,true)+6,46,'· LID ANGLE',{fill:LAV});
 wrap('Closing past the start angle begins the effect. Blur, dimming and lean build together and reach full strength well before the lid shuts.',12.5,400,236).forEach((ln,i)=>b+=T(584,78+i*19,esc(ln),{size:12.5,op:.8}));
 const hx=r(584+150*.643),hy=318,R2=150,R1=126,pt=(th,rr)=>[hx+rr*Math.cos(th*Math.PI/180),hy-rr*Math.sin(th*Math.PI/180)];
 const seg=(a0,a1,fill,op)=>{const[p1,p2,p3,p4]=[pt(a0,R2),pt(a1,R2),pt(a1,R1),pt(a0,R1)];return `<path d="M${r(p1[0])} ${r(p1[1])}A${R2} ${R2} 0 0 0 ${r(p2[0])} ${r(p2[1])}L${r(p3[0])} ${r(p3[1])}A${R1} ${R1} 0 0 1 ${r(p4[0])} ${r(p4[1])}Z" fill="${fill}" fill-opacity="${r(op)}"/>`;};
 b+=seg(85,130,'#FFFFFF',.1);
 for(let a=85;a>20;a-=5){const t=(85-a)/65;const col=t<.5?mix(P.peach,P.pink,t*2):mix(P.pink,P.violet,(t-.5)*2);b+=seg(a-5.15,a,col,.35+.55*t);}
 b+=seg(0,20,P.violet,.95);
 for(const[a,lab,rr]of [[130,'OPEN',R1-20],[85,'START',R1-18],[20,'FULL',R1-22],[0,'SHUT',R1-26]]){const[x1,y1]=pt(a,R1-2),[x2,y2]=pt(a,R2+4);b+=`<line x1="${r(x1)}" y1="${r(y1)}" x2="${r(x2)}" y2="${r(y2)}" stroke="#fff" stroke-opacity=".7"/>`;const[lx,ly]=pt(a,rr);b+=M(lx,ly+(a===0?-4:3),lab,{size:8,fill:'#fff',op:.78,anchor:'middle',ls:1});}
 b+=`<rect x="${hx}" y="${hy+3}" width="${R2}" height="7" rx="3.5" fill="url(#alu)"/>`;
 const LA=t=>lidAt(t,118,6);
 b+=`<g transform="rotate(-62 ${hx} ${hy})"><animateTransform attributeName="transform" type="rotate" values="${Array.from({length:N+1},(_,i)=>`${r(-LA(i/N))} ${hx} ${hy}`).join(';')}" keyTimes="${KT(N)}" dur="${dur}" repeatCount="indefinite"/><line x1="${hx}" y1="${hy}" x2="${hx+R2-4}" y2="${hy}" stroke="#FFFFFF" stroke-opacity=".92" stroke-width="5" stroke-linecap="round"/></g><circle cx="${hx}" cy="${hy}" r="5.5" fill="#2A2D38" stroke="#fff" stroke-opacity=".5"/>`;
 let lx=584;for(const[lab,c,op]of [['OPEN','#FFFFFF',.25],['RAMP',P.pink,.85],['FULL',P.violet,.95]]){b+=`<rect x="${lx}" y="358" width="10" height="10" rx="3" fill="${c}" fill-opacity="${op}"/>`+M(lx+15,366.5,lab,{size:8.5,fill:LAV});lx+=15+mw(lab,8.5,600,1.4,true)+18;}
 b+=`</g>`+wd.frame;
 full['diagrams/anatomy.svg']=svg(W,H,'Anatomy of the effect. Front view: the picture is sharp at the hinge and blurs and dims toward the top. Side view: the effect starts partway down and reaches full strength before the lid shuts.',`<defs>${d}</defs>${b}`);}

// ---------- CURVE (blur, dim, lean vs lid angle, animated playhead) ----------
{const W=860,H=320,p='c',N=96,dur='9s';const wd=world(p,W,H,[['pk',700,40,320,200],['vi',260,260,300,180],['pc',80,360,260,160,.6]]);
 let d=wd.defs+glassDefs(p)+blurF('cpb',24);const pn=panel(p,'cp',16,16,828,288,22,'cw','cpb');d+=pn.defs;let b=`<g clip-path="url(#cclip)"><use href="#cw"/>${pn.body}`;
 b+=M(40,46,'THE CURVE',{fill:P.pink})+M(40+mw('THE CURVE',9.5,600,1.4,true)+6,46,'· BALANCED PRESET, OPEN TO SHUT',{fill:LAV});
 let lx=820;const leg=[['Lean','#FFE2C4','5 4'],['Dimming',LIL,'4 3'],['Blur',P.pink,'']];d+=lg('cbl',[[0,P.peach],[1,P.pink]],{x2:1,y2:0});
 for(const[lab,c,da]of leg){const w=mw(lab,11.5,500);lx-=w;b+=T(lx,47,lab,{size:11.5,weight:500,op:.85});lx-=24;b+=`<line x1="${r(lx)}" y1="43" x2="${r(lx+16)}" y2="43" stroke="${c}" stroke-width="2.4" stroke-linecap="round"${da?` stroke-dasharray="${da}"`:''}/>`;lx-=22;}
 const X0=64,X1=820,Y0=76,Y1=232,xa=a=>X0+(130-a)/130*(X1-X0),yv=v=>Y1-v*(Y1-Y0);
 b+=`<rect x="${r(xa(85))}" y="${Y0}" width="${r(xa(20)-xa(85))}" height="${Y1-Y0}" fill="${P.pink}" fill-opacity=".07"/><rect x="${r(xa(20))}" y="${Y0}" width="${r(X1-xa(20))}" height="${Y1-Y0}" fill="${P.violet}" fill-opacity=".14"/>`;
 for(const v of [0,.5,1])b+=`<line x1="${X0}" y1="${r(yv(v))}" x2="${X1}" y2="${r(yv(v))}" stroke="#fff" stroke-opacity="${v?.08:.22}"/>`+M(X0-8,yv(v)+3,v?`${v*100}%`:'0',{size:8.5,fill:LAV,anchor:'end',ls:.4});
 for(let a=130;a>=0;a-=10)b+=`<line x1="${r(xa(a))}" y1="${Y1}" x2="${r(xa(a))}" y2="${Y1+4}" stroke="#fff" stroke-opacity=".25"/>`;
 b+=M(X0,Y1+18,'OPEN',{size:8.5,fill:LAV})+M(X1,Y1+18,'SHUT',{size:8.5,fill:LAV,anchor:'end'})+M((X0+X1)/2,Y1+18,'LID CLOSING →',{size:8.5,fill:LAV,anchor:'middle',op:.7});
 b+=`<line x1="${r(xa(85))}" y1="${Y0-6}" x2="${r(xa(85))}" y2="${Y1}" stroke="${P.pink}" stroke-opacity=".8" stroke-dasharray="3 3"/>`+M(xa(85)+5,Y0+4,'START',{size:8.5,fill:P.pink});
 b+=`<line x1="${r(xa(20))}" y1="${Y0-6}" x2="${r(xa(20))}" y2="${Y1}" stroke="#A99BFF" stroke-opacity=".8" stroke-dasharray="3 3"/>`+M(xa(20)+5,Y1-8,'FULL EFFECT',{size:8.5,fill:LIL});
 const hmax=held(20);const fB=a=>blurS(prog(a)),fD=a=>dimS(prog(a)),fL=a=>held(a)/hmax;
 const path=f=>{let s='';for(let a=130;a>=0;a-=.5)s+=`${a===130?'M':'L'}${r(xa(a))} ${r(yv(f(a)))}`;return s;};
 d+=lg('car',[[0,P.pink,.3],[1,P.pink,0]]);
 b+=`<path d="${path(fB)}L${X1} ${Y1}L${X0} ${Y1}Z" fill="url(#car)"/><path d="${path(fL)}" stroke="#FFE2C4" stroke-width="1.8" stroke-dasharray="5 4" stroke-linecap="round"/><path d="${path(fD)}" stroke="${LIL}" stroke-width="2" stroke-dasharray="4 3" stroke-linecap="round"/><path d="${path(fB)}" stroke="url(#cbl)" stroke-width="2.6" stroke-linecap="round"/>`;
 d+=lg('ctp',[[0,P.peach],[1,P.pink]]);
 b+=M(X0,288,'TRACKPAD TAPS · SWELL',{size:8.5,fill:LAV});for(let i=0;i<48;i++){const q=(i+1)/48,s=.2+.8*q,x=xa(85-65*q),h=14*s;b+=`<rect x="${r(x-.8)}" y="${r(287-h)}" width="1.6" height="${r(h)}" rx=".8" fill="url(#ctp)"/>`;}
 const A=t=>lidAt(t,125,3),st=50;
 b+=`<line x1="${r(xa(st))}" y1="${Y0}" x2="${r(xa(st))}" y2="${Y1}" stroke="#fff" stroke-opacity=".55">${anim('x1',N,t=>xa(A(t)),dur)}${anim('x2',N,t=>xa(A(t)),dur)}</line>`;
 for(const[f,c]of [[fL,'#FFE2C4'],[fD,LIL],[fB,P.pink]])b+=`<circle cx="${r(xa(st))}" cy="${r(yv(f(st)))}" r="4.5" fill="${c}" stroke="#fff" stroke-width="1.5">${anim('cx',N,t=>xa(A(t)),dur)}${anim('cy',N,t=>yv(f(A(t))),dur)}</circle>`;
 b+=`</g>`+wd.frame;
 full['diagrams/curve.svg']=svg(W,H,'How blur, dimming and lean ramp up as the lid closes on the Balanced preset, with the trackpad taps of the Swell pattern.',`<defs>${d}</defs>${b}`);}

// ---------- PRESETS (five cards with leaning-lid thumbnails; values from EffectPreset.swift) ----------
{const W=860,H=340,p='p';const wd=world(p,W,H,[['pk',720,40,320,220],['vi',300,120,300,200],['pc',120,380,300,200],['pk',520,380,260,160,.5]]);
 let d=wd.defs+glassDefs(p)+winDefs(p,2,2.5)+blurF('ppb',22)+lg('pbar',[[0,P.peach],[.5,P.pink],[1,P.violet]],{x2:1,y2:0})+lg('pwp',[[0,P.n0],[.45,P.n1],[1,P.n2]])+lg('alu',[[0,'#F7F8FB'],[.4,'#C4C8D4'],[1,'#7C8194']])+lg('palr',[[0,'#C4C8D4',.9],[1,'#7C8194',.6]])+lg('prf',[[0,'#fff',.13],[.45,'#fff',.03],[1,'#fff',0]],{x2:1,y2:1});let b=`<g clip-path="url(#pclip)"><use href="#pw"/>`;
 const DW=128,DH=84;d+=`<g id="pmw"><rect x="-20" y="-20" width="${DW+40}" height="${DH+40}" fill="url(#pwp)"/><ellipse cx="${.78*DW}" cy="${.82*DH}" rx="${.62*DW}" ry="${.6*DH}" fill="url(#ppk)"/><ellipse cx="${.12*DW}" cy="${1.05*DH}" rx="${.55*DW}" ry="${.5*DH}" fill="url(#ppc)"/><ellipse cx="${.3*DW}" cy="${.38*DH}" rx="${.3*DW}" ry="${.32*DH}" fill="url(#pvi)"/>${menubar(0,0,DW,5)}${edwin(p,.05*DW,.12*DH,.36*DW,.5*DH)}${win(p,.55*DW,.1*DH,.38*DW,.44*DH,.42)}${win(p,.2*DW,.38*DH,.46*DW,.56*DH,.4)}</g>`;
 const PR=[['Balanced','The default: a steady lean and a soft blur.',{t:85,span:65,blur:55,even:.05,dim:.55,reach:.55,rec:1,lean:70,vd:6},1],['Subtle','A light blur and a slight lean.',{t:75,span:55,blur:25,even:0,dim:.3,reach:.8,rec:.6,lean:35,vd:6}],['Deep','A strong lean, perspective and dimming.',{t:95,span:60,blur:100,even:.15,dim:.85,reach:.45,rec:1.3,lean:80,vd:3.5}],['Flat','Blurs and dims without leaning.',{t:85,span:60,blur:70,even:.5,dim:.5,reach:.8,rec:0,lean:45,vd:6}],['Classic','A heavy blur that fades into black.',{t:90,span:60,blur:135,even:0,dim:1,reach:.5,rec:1,lean:45,vd:6}]];
 const word=(k,f)=>k==='START'?(f>.66?'Early':f>.45?'Mid':'Late'):k==='BLUR'?(f<.2?'Light':f<.45?'Soft':f<.7?'Strong':'Heavy'):k==='DIM'?(f<.4?'Low':f<.7?'Medium':f<.95?'Deep':'Full'):(f<=0?'None':f<.4?'Slight':f<.6?'Medium':'Strong');
 PR.forEach(([name,sum,s,def],i)=>{const cx=16+i*167.5,cw=158;const pn=panel(p,'pc'+i,cx,16,cw,308,20,'pw','ppb',{rim:def?p+'rimh':p+'rim',tint:def?.08:.05});d+=pn.defs;b+=pn.body;
  b+=T(cx+16,40,name,{size:15,weight:650,family:DISP});if(def)b+=tag(cx+cw-12-tagW('DEFAULT'),28,'DEFAULT');
  const eff=s.rec>0?Math.min(s.lean,s.span*s.rec):0,kk=.13*(eff/80)*Math.pow(6/s.vd,.35);
  const ox0=cx+10,ox1=cx+148,oy1=142,oy0=54+10*(eff/80),ti=(ox1-ox0)*kk;
  const outer=[[ox0,oy1],[ox1,oy1],[ox1-ti,oy0],[ox0+ti,oy0]];
  const xl=y=>ox0+ti*(oy1-y)/(oy1-oy0)+5,xr=y=>ox1-ti*(oy1-y)/(oy1-oy0)-5,iy0=oy0+5,iy1=oy1-7;
  const inner=[[xl(iy1),iy1],[xr(iy1),iy1],[xr(iy0),iy0],[xl(iy0),iy0]];
  const X=xl(iy1),Y=iy0,dw=xr(iy1)-xl(iy1),dh=iy1-iy0;
  d+=`<mask id="pdm${i}" maskUnits="userSpaceOnUse" x="${cx}" y="40" width="${cw}" height="120"><path d="${rquad(inner,[1.5,1.5,5,5])}" fill="#fff"/></mask>`;
  const far=s.blur*(2/3)*.16,f=frost('pf'+i+'_','pmw',X,Y,dw,dh,far*s.even,far*(1-s.even),5,` transform="translate(${r(X)} ${r(Y)}) scale(${r4(dw/DW)} ${r4(dh/DH)})"`);d+=f.defs+dimGrad('pdim'+i,Y,dh,s.dim,s.reach);
  b+=`<ellipse cx="${cx+79}" cy="${oy1+6}" rx="70" ry="6" fill="#000" fill-opacity=".35" filter="url(#ppsh)"/>`;
  b+=`<path d="${rquad(outer,[3,3,10,10])}" fill="#0A0B10"/><path d="${rquad(outer,[3,3,10,10])}" stroke="url(#palr)" stroke-width="1.2"/>`;
  b+=`<g mask="url(#pdm${i})"><use href="#pmw" transform="translate(${r(X)} ${r(Y)}) scale(${r4(dw/DW)} ${r4(dh/DH)})"/>${f.body}<rect x="${r(X-2)}" y="${r(Y)}" width="${r(dw+4)}" height="${r(dh)}" fill="url(#pdim${i})"/><path d="${rquad(inner,[1.5,1.5,5,5])}" fill="url(#prf)"/></g>`;
  b+=`<rect x="${cx+4}" y="${oy1}" width="150" height="6" rx="3" fill="url(#alu)"/><rect x="${cx+60}" y="${oy1}" width="38" height="2.4" rx="1.2" fill="#8E93A5"/>`;
  wrap(sum,11.5,400,128).slice(0,3).forEach((ln,j)=>b+=T(cx+16,170+j*15.5,esc(ln),{size:11.5,op:.74}));
  const rows=[['START',(s.t-5)/125],['BLUR',(s.blur-10)/150],['DIM',s.dim],['LEAN',s.rec>0?(s.lean-10)/75:0]];
  rows.forEach(([lab,fr],j)=>{const y=226+j*24;b+=M(cx+16,y,lab,{size:8.5,fill:LAV,ls:1.2})+T(cx+142,y,word(lab,fr),{size:11,weight:600,anchor:'end',op:.92})+`<rect x="${cx+16}" y="${y+6}" width="126" height="3" rx="1.5" fill="#fff" fill-opacity=".1"/>`+(fr>0?`<rect x="${cx+16}" y="${y+6}" width="${r(126*fr)}" height="3" rx="1.5" fill="url(#pbar)"/>`:'');});});
 d+=blurF('ppsh',3,'x="-20%" y="-200%" width="140%" height="500%"');
 b+=`</g>`+wd.frame;
 stat['diagrams/presets.svg']=svg(W,H,'The five presets: Balanced, Subtle, Deep, Flat and Classic, each with how early it starts, how strong its blur and dimming are, and how far it leans.',`<defs>${d}</defs>${b}`);}

// ---------- HAPTICS (four tap patterns from HapticPattern.swift, animated sweep) ----------
{const W=860,H=344,p='k';const wd=world(p,W,H,[['pk',740,60,300,200],['vi',240,120,300,220],['pc',520,420,320,180,.6]]);
 let d=wd.defs+glassDefs(p)+blurF('kpb',24)+`<linearGradient id="ktp" gradientUnits="userSpaceOnUse" x1="300" y1="0" x2="816" y2="0"><stop offset="0" stop-color="${P.peach}"/><stop offset=".5" stop-color="${P.pink}"/><stop offset="1" stop-color="${P.violet}"/></linearGradient>`;const pn=panel(p,'kp',16,16,828,312,22,'kw','kpb');d+=pn.defs;let b=`<g clip-path="url(#kclip)"><use href="#kw"/>${pn.body}`;
 b+=M(40,46,'TRACKPAD TAPS',{fill:P.pink})+M(40+mw('TRACKPAD TAPS',9.5,600,1.4,true)+6,46,'· 24 TAPS SHOWN, 48 BY DEFAULT',{fill:LAV});
 const stops=(st,n=24,pk=1)=>{if(st==='linear')return Array.from({length:n},(_,i)=>[(i+1)/n,pk]);if(st==='exponential'){const k=3;return Array.from({length:n},(_,i)=>{const q=Math.log(1+(Math.exp(k)-1)*(i+1)/n)/k;return[q,pk*(.35+.65*q)];});}if(st==='swell')return Array.from({length:n},(_,i)=>{const q=(i+1)/n;return[q,pk*(.2+.8*q)];});return[[0,pk*.6],[1,pk]];};
 const ST=[['Linear','Even taps, like detents.','linear'],['Exponential','Tiny taps that come faster and faster.','exponential'],['Swell','Even taps that grow stronger.','swell',1],['Start and end','One tap as the effect starts, a firm one at full effect.','bookends']];
 const TX0=300,TX1=816,dur='4.5s',sweep=.72;
 ST.forEach(([name,desc,st,def],i)=>{const y0=66+i*60;if(i)b+=`<line x1="40" y1="${y0}" x2="820" y2="${y0}" stroke="#fff" stroke-opacity=".06"/>`;
  b+=T(40,y0+24,name,{size:14,weight:600,family:DISP});if(def)b+=tag(40+mw(name,14,600)+10,y0+12.5,'DEFAULT');
  wrap(desc,11.5,400,226).forEach((ln,j)=>b+=T(40,y0+42+j*15,esc(ln),{size:11.5,op:.66}));
  const base=y0+48;b+=`<rect x="${TX0}" y="${base}" width="${TX1-TX0}" height="1" fill="#fff" fill-opacity=".16"/>`;
  for(const[q,s]of stops(st)){const x=TX0+q*(TX1-TX0),h=Math.max(34*s,3),t=q*sweep;let vs,kt;if(t<=.002){vs='1;.5;.5';kt='0;.1;1';}else{vs='.5;.5;1;.5;.5';kt=`0;${r4(t-.001)};${r4(t)};${r4(Math.min(t+.1,.99))};1`;}b+=`<rect x="${r(x-1.6)}" y="${r(base-h)}" width="3.2" height="${r(h)}" rx="1.6" fill="url(#ktp)" opacity=".9"><animate attributeName="opacity" values="${vs}" keyTimes="${kt}" dur="${dur}" repeatCount="indefinite"/></rect>`;}});
 b+=`<line x1="${TX0}" y1="62" x2="${TX0}" y2="306" stroke="#fff" stroke-opacity="0"><animate attributeName="x1" values="${TX0};${TX1};${TX1}" keyTimes="0;${sweep};1" dur="${dur}" repeatCount="indefinite"/><animate attributeName="x2" values="${TX0};${TX1};${TX1}" keyTimes="0;${sweep};1" dur="${dur}" repeatCount="indefinite"/><animate attributeName="stroke-opacity" values=".5;.5;0;0" keyTimes="0;${sweep};${sweep+.02};1" dur="${dur}" repeatCount="indefinite"/></line>`;
 b+=M(TX0,314,'EFFECT STARTS',{size:8.5,fill:LAV})+M(TX1,314,'FULL EFFECT',{size:8.5,fill:LAV,anchor:'end'})+`<line x1="${TX0+92}" y1="311" x2="${TX1-84}" y2="311" stroke="#fff" stroke-opacity=".18" stroke-dasharray="2 4"/>`;
 b+=`</g>`+wd.frame;
 full['diagrams/haptics.svg']=svg(W,H,'The four trackpad tap patterns: Linear, Exponential, Swell and Start and end, plotted along the lid travel.',`<defs>${d}</defs>${b}`);}

// ---------- TECHNICAL DESIGN (2x2 principle cards; claims from LidWake, LidAngleEstimator, WindowServerBlur, LidPicturePolicy) ----------
{const W=860,H=440,p='e';const wd=world(p,W,H,[['pk',740,60,320,220],['vi',260,200,300,220],['pc',120,460,300,200],['pk',560,440,260,160,.5]]);
 let d=wd.defs+glassDefs(p)+blurF('epb',22)+lg('ebig',[[0,'#FFFFFF'],[1,'#FFE2C4']])+lg('ebar',[[0,P.peach],[.5,P.pink],[1,P.violet]],{x2:1,y2:0})+lg('escr',[[0,'#FFA27E'],[.5,'#E0559A'],[1,'#7B5CFF']],{x2:1,y2:1});
 let b=`<g clip-path="url(#eclip)"><use href="#ew"/>`;
 const CW=406,CH=196,cols=[16,438],rows=[16,228];
 const chartA=(x,y,w,h)=>{let s='';const base=y+28,b0=x+40,b1=b0+20;s+=M(x,y+8,'CPU',{size:7.5,fill:LAV,ls:1})+M(b0,y+8,'LID MOVES',{size:7.5,fill:P.pink,ls:.8});
  s+=`<line x1="${x}" y1="${base}" x2="${x+w}" y2="${base}" stroke="#fff" stroke-opacity=".25"/>`;const hs=[5,11,8,14,6,12,9];for(let i=0;i<7;i++){const xx=b0+i*3;s+=`<rect x="${xx}" y="${r(base-hs[i])}" width="2" height="${hs[i]}" rx="1" fill="${P.pink}"/>`;}
  s+=M(x,y+44,'PUSHES · 10/S',{size:7.5,fill:LAV,ls:.8});for(let xx=x;xx<=x+w-1;xx+=5)s+=`<rect x="${xx}" y="${y+48}" width="1.5" height="5" rx=".75" fill="${P.peach}" fill-opacity=".8"/>`;
  s+=M(x,y+66,'POLLING',{size:7.5,fill:LAV,ls:.8})+`<rect x="${b0}" y="${y+70}" width="50" height="4" rx="2" fill="#fff" fill-opacity=".3"/>`+M(x+w,y+74,'THEN ASLEEP',{size:7,fill:LAV,ls:.6,op:.8,anchor:'end'});return s;};
 const chartB=(x,y,w,h)=>{let s='';const T0=1.2,tx=t=>x+t/T0*w,ang=t=>100-60*sm(cl((t-.15)/.75)),ay=a=>y+6+(100-a)/60*(h-24);
  let stair='',prev=null;for(let t=0;t<=T0+1e-9;t+=.104){const a=Math.round(ang(t)),X=tx(t);stair+=prev===null?`M${r(X)} ${r(ay(a))}`:`L${r(X)} ${r(ay(prev))}L${r(X)} ${r(ay(a))}`;prev=a;}stair+=`L${r(x+w)} ${r(ay(prev))}`;
  s+=`<path d="${stair}" stroke="#fff" stroke-opacity=".32" stroke-width="1.2"/>`;let sp='';for(let t=0;t<=T0+1e-9;t+=.01)sp+=`${sp?'L':'M'}${r(tx(t))} ${r(ay(ang(t)))}`;s+=`<path d="${sp}" stroke="${P.pink}" stroke-width="2" stroke-linecap="round"/>`;
  for(let t=0;t<=T0+1e-9;t+=.104)s+=`<circle cx="${r(tx(t))}" cy="${r(ay(Math.round(ang(t))))}" r="2" fill="${P.peach}"/>`;
  s+=`<circle cx="${x+3}" cy="${y+h-3}" r="2" fill="${P.peach}"/>`+M(x+9,y+h,'READINGS',{size:7.5,fill:LAV,ls:.8})+`<line x1="${x+68}" y1="${y+h-3}" x2="${x+80}" y2="${y+h-3}" stroke="${P.pink}" stroke-width="2" stroke-linecap="round"/>`+M(x+85,y+h,'EVERY FRAME',{size:7.5,fill:LAV,ls:.8});return s;};
 const chartC=(x,y,w,h)=>{let s='';const plate=(py,fill,op,st)=>`<path d="M${x+2} ${py+15}L${x+98} ${py+15}L${x+82} ${py}L${x+18} ${py}Z" fill="${fill}" fill-opacity="${op}"${st?` stroke="#fff" stroke-opacity=".45"`:''}/>`;
  s+=plate(y+56,'url(#escr)',.95)+plate(y+38,'#fff',.1,1)+plate(y+23,'#fff',.18,1)+plate(y+8,'#fff',.28,1);
  s+=M(x+108,y+18,'GLASS',{size:7.5,fill:TXT,op:.85,ls:.8})+M(x+108,y+40,'BANDS',{size:7.5,fill:LAV,ls:.8})+M(x+108,y+68,'SCREEN',{size:7.5,fill:LAV,ls:.8});
  s+=`<line x1="${x+102}" y1="${y+10}" x2="${x+102}" y2="${y+52}" stroke="#fff" stroke-opacity=".2"/>`;
  s+=M(x,y+h+8,'GPU · NOTHING CAPTURED',{size:7.5,fill:LAV,ls:.8});return s;};
 const chartD=(x,y,w,h)=>{let s='';const ms=v=>x+v/80*w;const rows=[['GLASS',0,8,'url(#ebar)',1,'NEXT REFRESH'],['STREAM',25,45,'#fff',.35,'25–45 MS'],['SCREENSHOT',50,75,'#fff',.22,'50–75 MS']];
  rows.forEach(([lab,a,bb,fill,op,val],i)=>{const yy=y+6+i*22;s+=M(x,yy,lab,{size:7.5,fill:LAV,ls:.8})+`<rect x="${r(ms(a))}" y="${yy+4}" width="${r(ms(bb)-ms(a))}" height="6" rx="3" fill="${fill}" fill-opacity="${op}"/>`;const vx=Math.max(ms(bb)+6,x+mw(lab,7.5,600,.8,true)+10);s+=bb>40?M(ms(bb),yy,val,{size:7.5,fill:TXT,op:.8,ls:.6,anchor:'end'}):M(vx,yy,val,{size:7.5,fill:TXT,op:.8,ls:.6});});
  s+=`<line x1="${x}" y1="${y+h-6}" x2="${x+w}" y2="${y+h-6}" stroke="#fff" stroke-opacity=".2"/>`;for(const v of [0,40,80])s+=`<line x1="${r(ms(v))}" y1="${y+h-6}" x2="${r(ms(v))}" y2="${y+h-2}" stroke="#fff" stroke-opacity=".4"/>`;
  s+=M(x,y+h+8,'0',{size:7,fill:LAV,ls:.5})+M(ms(40),y+h+8,'40',{size:7,fill:LAV,ls:.5,anchor:'middle'})+M(x+w,y+h+8,'80 MS',{size:7,fill:LAV,ls:.5,anchor:'end'});return s;};
 const cards=[
  {mod:'LidWake',tag:'PUSHED READINGS',title:'Asleep until the lid moves',body:'The sensor pushes readings on its own, so nothing polls while the lid rests. A push 1.5° from where it settled wakes the app. Measured: no CPU time, no idle wakeups.',big:'0%',bl:'CPU WHILE THE LID IS STILL',chart:chartA},
  {mod:'LidAngleEstimator',tag:'KALMAN FILTER',title:'An angle for every frame',body:'The sensor reports about every 104 ms. A Kalman filter on angle, speed and acceleration places each reading when it arrived and tells every frame where the lid is now, never running ahead of it.',big:'10→120',bl:'READINGS/S TO FRAMES/S',chart:chartB},
  {mod:'WindowServerBlur',tag:'PRIVATE CORE ANIMATION',title:'Drawn by the window server',body:'CABackdropLayer blurs what the window server drew behind it, live on the GPU. The app never sees a pixel: no capture, no Screen Recording prompt. If macOS drops the class, the app captures the screen instead.',big:'0',bl:'SCREEN PIXELS SEEN BY THE APP',chart:chartC},
  {mod:'LidPicturePolicy',tag:'GLASS FIRST',title:'On screen at the next refresh',body:'The glass is built ahead and goes up on the very next refresh. A capture takes 25 to 75 ms to arrive, so in capture mode the glass still goes first and the picture cuts in over it, blurred and dimmed to match.',big:'8 ms',bl:'NEXT REFRESH AT 120 HZ',chart:chartD}];
 cards.forEach((c,i)=>{const cx=cols[i%2],cy=rows[Math.floor(i/2)];const pn=panel(p,'ec'+i,cx,cy,CW,CH,22,'ew','epb');d+=pn.defs;b+=pn.body;
  b+=M(cx+20,cy+30,c.mod,{fill:P.pink})+M(cx+20+mw(c.mod,9.5,600,1.4,true)+6,cy+30,'· '+c.tag,{fill:LAV});
  const ts=Math.min(16,16*198/mw(c.title,16,650));b+=T(cx+20,cy+58,esc(c.title),{size:r(ts),weight:650,family:DISP});
  wrap(c.body,11.5,400,200).slice(0,6).forEach((ln,j)=>b+=T(cx+20,cy+80+j*15,esc(ln),{size:11.5,op:.74}));
  const rx=cx+236;b+=T(rx,cy+60,esc(c.big),{size:30,weight:700,family:DISP,fill:'url(#ebig)',ls:-.5})+M(rx,cy+76,c.bl,{size:8,ls:.5,fill:LAV});b+=c.chart(rx,cy+94,154,74);});
 b+=`</g>`+wd.frame;
 stat['diagrams/engineering.svg']=svg(W,H,'Four principles of the technical design: asleep until the lid moves, an angle for every frame from a Kalman filter, drawn by the window server with nothing captured, and glass on screen at the next refresh.',`<defs>${d}</defs>${b}`);}

// ---------- MODULE MAP (Developers section; animated data flow) ----------
{const W=860,H=372,p='q';const wd=world(p,W,H,[['pk',760,300,300,200],['vi',200,80,300,200],['pc',480,40,260,140,.45]]);
 let d=wd.defs+glassDefs(p)+blurF('qpb',24)+blurF('qnfx',16)+`<marker id="ar" viewBox="0 0 8 8" refX="6.5" refY="4" markerWidth="8" markerHeight="8" markerUnits="userSpaceOnUse" orient="auto"><path d="M1.5 1.2 L6.5 4 L1.5 6.8" stroke="#D9D3FF" stroke-width="1.4" fill="none" stroke-linecap="round" stroke-linejoin="round"/></marker>`;
 const pn=panel(p,'qp',16,16,828,340,22,'qw','qpb');d+=pn.defs;let b=`<g clip-path="url(#qclip)"><use href="#qw"/>${pn.body}`;
 b+=M(40,46,'MODULE MAP',{fill:P.pink})+M(40+mw('MODULE MAP',9.5,600,1.4,true)+6,46,'· SENSOR TO GLASS',{fill:LAV});
 const C=[40,242,444,646],R=[70,172,268],NW=176,NH=64;
 const node=(id,c,rw,kick,title,sub,o={})=>{const x=C[c],y=R[rw];const pn=panel(p,'qn'+id,x,y,NW,NH,14,'qw','qnfx',{rim:o.hl?p+'rimh':p+'rim',tint:o.hl?.11:.08});d+=pn.defs;let s=pn.body+M(x+14,y+20,kick,{size:8.5,fill:o.hl?'#FF9CC6':LAV,ls:.5,weight:600})+T(x+14,y+39,esc(title),{size:13.5,weight:600,family:DISP})+T(x+14,y+55,esc(sub),{size:11,op:.64});if(o.tag)s+=tag(x+NW-10-tagW(o.tag),y+9,o.tag,o.tagc||P.pink,o.tagt||'#FFC6DE');return s;};
 const conn=(x1,y1,x2,y2,live)=>`<line x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}" stroke="#fff" stroke-opacity="${live?.22:.35}"${live?'':' stroke-dasharray="3 4"'} marker-end="url(#ar)"/>`+(live?`<line x1="${x1}" y1="${y1}" x2="${x2}" y2="${y2}" stroke="${P.pink}" stroke-width="2" stroke-linecap="round" stroke-dasharray="2 8"><animate attributeName="stroke-dashoffset" values="20;0" dur="0.9s" repeatCount="indefinite"/></line>`:'');
 const midY=R[0]+NH/2;
 b+=conn(C[0]+NW+3,midY,C[1]-4,midY,1)+conn(C[1]+NW+3,midY,C[2]-4,midY,1)+conn(C[2]+NW+3,midY,C[3]-4,midY,1)+conn(C[2]+NW/2,R[0]+NH+3,C[2]+NW/2,R[1]-4,1)+conn(C[3]+NW/2,R[0]+NH+3,C[3]+NW/2,R[1]-4,1)+conn(C[0]+NW/2,R[0]+NH+3,C[0]+NW/2,R[1]-4,0)+conn(C[3]+NW/2,R[1]+NH+3,C[3]+NW/2,R[2]-4,0);
 b+=M(C[3]+NW/2-10,R[1]+NH+22,"IF MACOS CAN'T DRAW IT",{size:8,fill:LAV,anchor:'end',ls:.8});
 b+=node('a',0,0,'LidAngleKit','Lid sensor','pushed readings, ~104 ms');
 b+=node('b',1,0,'LidAngleEstimator','Angle per frame','Kalman filter, no jitter');
 b+=node('c',2,0,'LidEffectRamp','Progress 0 → 1','start angle to full effect');
 b+=node('d',3,0,'BlurGradient','Blur and dim','by height, every frame');
 b+=node('e',0,1,'LidWake','Asleep','until the lid moves');
 b+=node('f',2,1,'HapticPattern','Trackpad taps','stops along the travel');
 b+=node('g',3,1,'WindowServerBlur','Window server glass','frost bands, no capture',{hl:1,tag:'DEFAULT'});
 b+=node('h',3,2,'ScreenStreamer · BlurStack','Capture fallback','ScreenCaptureKit + Metal',{tag:'FALLBACK',tagc:'#A99BFF',tagt:'#DCD6FF'});
 b+=`<line x1="40" y1="${R[2]+20}" x2="62" y2="${R[2]+20}" stroke="#fff" stroke-opacity=".22"/><line x1="40" y1="${R[2]+20}" x2="62" y2="${R[2]+20}" stroke="${P.pink}" stroke-width="2" stroke-linecap="round" stroke-dasharray="2 8"/>`+T(72,R[2]+24,'Runs every frame while the effect is on',{size:12,op:.74});
 b+=`<line x1="40" y1="${R[2]+44}" x2="62" y2="${R[2]+44}" stroke="#fff" stroke-opacity=".4" stroke-dasharray="3 4"/>`+T(72,R[2]+48,'Runs only when it is needed',{size:12,op:.74});
 b+=`</g>`+wd.frame;
 full['diagrams/pipeline.svg']=svg(W,H,'Module map: the lid sensor, angle estimator, effect ramp and blur gradient feed the window server glass, with a screen capture fallback, trackpad haptics and a low power wake.',`<defs>${d}</defs>${b}`);}

for(const[k,v]of Object.entries(full)){await saveFile(OUT+'full/'+k+'.txt',v);await saveFile(OUT+'assets/'+k,v);}
for(const[k,v]of Object.entries(stat))await saveFile(OUT+'assets/'+k,v);
log('wrote',Object.keys(full).length,'animated +',Object.keys(stat).length,'static files to',OUT);
})()
