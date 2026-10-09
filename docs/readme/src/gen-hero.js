(async()=>{
const W=860,H=420,cx=W/2,M=100,R=28,dur='10s';
const r=n=>Math.round(n*100)/100,r4=n=>Math.round(n*10000)/10000,sm=t=>t*t*(3-2*t);
const SANS="-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Segoe UI', 'Helvetica Neue', Helvetica, Arial, sans-serif",DISP=SANS.replace('SF Pro Text','SF Pro Display');
const ctx=createCanvas(10,10).getContext('2d');const mw=(t,size,weight=400)=>{ctx.font=`${weight} ${size}px Helvetica, Arial, sans-serif`;return ctx.measureText(t).width*1.03;};
const P={pink:'#FF5FA2',peach:'#FFB08A',violet:'#6F5BFF',ink:'#07041F'};
// Balanced preset, as the app computes it: LidEffectRamp.pictureAngle (held lean), DepthGeometry eye distance, BlurGradient curves
const lid=t=>{const o=92,s=20;return t<.03?o:t<.3?o+(s-o)*sm((t-.03)/.27):t<.8?s:t<.96?s+(o-s)*sm((t-.8)/.16):o;};
const soft=(v,lim,k)=>v<=lim-k?v:v>=lim+k?lim:v-(v-(lim-k))**2/(4*k);
const held=a=>{const tr=85-a;return tr<=0?0:Math.min(soft(tr,70,17.5),65)*.6;};
const prog=a=>Math.min(Math.max((85-a)/65,0),1),blurS=p=>Math.pow(p,1.92),dimS=p=>Math.pow(p,.7);
const D=H*(6+.5*Math.cos(85*Math.PI/180));
const geo=a=>{const S=Math.min(held(a),88)*Math.PI/180,sn=Math.sin(S),cs=Math.cos(S);const sc=p=>D/(D+p*sn);return{sc,Y:p=>H-(H/2+(p*cs-H/2)*sc(p)),X:(x,p)=>cx+(x-cx)*sc(p)};};
const T=[0,.03];for(let j=1;j<=14;j++)T.push(r4(.03+.27*j/14));T.push(.8);for(let j=1;j<=8;j++)T.push(r4(.8+.16*j/8));T.push(1);
const KT=T.join(';');
const FR=typeof FREEZE!=='undefined'?FREEZE:null;
const an=(attr,f,tf=T)=>{const vals=tf.map(t=>f(lid(t)));const v0=FR!==null?f(lid(FR)):vals[0];return{a:`${attr}="${v0}"`,c:FR!==null?'':`<animate attributeName="${attr}" values="${vals.join(';')}" keyTimes="${tf.join(';')}" dur="${dur}" repeatCount="indefinite"/>`};};
const anT=(type,f)=>{const vals=T.map(t=>f(lid(t)));const v0=FR!==null?f(lid(FR)):vals[0];return{a:`transform="${type}(${v0})"`,c:FR!==null?'':`<animateTransform attributeName="transform" type="${type}" values="${vals.join(';')}" keyTimes="${KT}" dur="${dur}" repeatCount="indefinite"/>`};};
const PIC=await readFile('readme/src/world.jpg.txt'),PICB=await readFile('readme/src/world-blur.jpg.txt');
const icB=await readFileBinary('readme/src/icon-ic08.png');const ab=new Uint8Array(await icB.arrayBuffer());let bin='';for(let i=0;i<ab.length;i+=8192)bin+=String.fromCharCode.apply(null,ab.subarray(i,i+8192));const ICON='data:image/png;base64,'+btoa(bin);
let d=`<clipPath id="hc"><rect width="${W}" height="${H}" rx="${R}"/></clipPath><image id="pic" x="${-M}" y="${-M}" width="${W+2*M}" height="${H+M}" href="${PIC}" preserveAspectRatio="none"/>`;
let b='';
// rows of the picture carried to where the lean puts them (GlassLean.pictureGrid)
const N=52,PT=H+M;let strips='';
for(let i=0;i<N;i++){const p0=PT*i/N,p1=PT*(i+1)/N,y0=H-p0,y1=H-p1;d+=`<clipPath id="b${i}"><rect x="${-M}" y="${r(y1-2)}" width="${W+2*M}" height="${r(y0-y1+2)}"/></clipPath>`;
 const sx=a=>geo(a).sc(p0),sy=a=>{const g=geo(a);return (g.Y(p1)-g.Y(p0))/(y1-y0);};
 const tr=anT('translate',a=>`${r(cx*(1-sx(a)))} ${r(geo(a).Y(p0)-sy(a)*y0)}`),scl=anT('scale',a=>`${r4(sx(a))} ${r4(sy(a))}`);
 strips+=`<g ${tr.a}>${tr.c}<g ${scl.a}>${scl.c}<use href="#pic" clip-path="url(#b${i})"/></g></g>`;}
d+=`<g id="lean">${strips}</g>`;
// frost bands up the glass (FrostBandLayout), each fading in where its rows show
const FREG=`filterUnits="userSpaceOnUse" x="-40" y="-40" width="${W+80}" height="${H+80}" color-interpolation-filters="sRGB"`;
let bands='';
for(let i=1;i<=6;i++){const hPrev=Math.pow((i-1)/6,1/2.25),hCur=Math.pow(i/6,1/2.25);const sd=an('stdDeviation',a=>r(32*i/6*blurS(prog(a))));const y1=an('y1',a=>r(geo(a).Y(hPrev*H))),y2=an('y2',a=>r(geo(a).Y(hCur*H)));
 d+=`<filter id="fb${i}" ${FREG}><feGaussianBlur ${sd.a}>${sd.c}</feGaussianBlur></filter><linearGradient id="fg${i}" gradientUnits="userSpaceOnUse" x1="0" x2="0" ${y1.a} ${y2.a}>${y1.c}${y2.c}<stop offset="0" stop-color="#fff" stop-opacity="0"/><stop offset="1" stop-color="#fff"/></linearGradient><mask id="fm${i}" maskUnits="userSpaceOnUse" x="0" y="0" width="${W}" height="${H}"><rect width="${W}" height="${H}" fill="url(#fg${i})"/></mask>`;
 bands+=`<g mask="url(#fm${i})"><use href="#lean" filter="url(#fb${i})"/></g>`;}
// the outline: edges and rounded top corners blurred by a quarter of the picture's blur (FrostedGlassView.outlineShare), gamma as the app lays black over encoded values; black beyond
const k=R*.5523;const outline=a=>{const g=geo(a),S=(x,p)=>`${r(g.X(x,p))} ${r(g.Y(p))}`;return `M${S(0,-60)}L${S(W,-60)}L${S(W,H-R)}C${S(W,H-R+k)} ${S(W-R+k,H)} ${S(W-R,H)}L${S(R,H)}C${S(R-k,H)} ${S(0,H-R+k)} ${S(0,H-R)}Z`;};
const OB=[[1.2,-.2,.06],[2.6,.06,.2],[4.6,.2,.5],[7,.5,1.3]];let om='';
OB.forEach(([s0,hLo,hHi],j)=>{const sd=an('stdDeviation',a=>r(s0*blurS(prog(a))));const dd=an('d',outline);
 d+=`<filter id="of${j}" ${FREG}><feGaussianBlur ${sd.a}>${sd.c}</feGaussianBlur><feComponentTransfer><feFuncA type="gamma" amplitude="1" exponent="0.4545" offset="0"/></feComponentTransfer></filter>`;
 let g=`<path ${dd.a} fill="#fff" filter="url(#of${j})">${dd.c}</path>`;
 if(j>0){const yA=an('y1',a=>r(geo(a).Y((hLo-.03)*H))),yB=an('y2',a=>r(geo(a).Y((hLo+.03)*H)));d+=`<linearGradient id="ol${j}" gradientUnits="userSpaceOnUse" x1="0" x2="0" ${yA.a} ${yB.a}>${yA.c}${yB.c}<stop offset="0" stop-color="#fff" stop-opacity="0"/><stop offset="1" stop-color="#fff"/></linearGradient><mask id="oml${j}" maskUnits="userSpaceOnUse" x="-40" y="-40" width="${W+80}" height="${H+80}"><rect x="-40" y="-40" width="${W+80}" height="${H+80}" fill="url(#ol${j})"/></mask>`;g=`<g mask="url(#oml${j})">${g}</g>`;}
 om+=g;});
d+=`<mask id="om" maskUnits="userSpaceOnUse" x="0" y="0" width="${W}" height="${H}">${om}</mask>`;
// dimming up the glass (BlurGradient.dimming), where each height shows
let dst='';for(let q=0;q<=10;q++){const h=q/10,t=Math.min(h/.55,1);dst+=`<stop offset="${h}" stop-color="${P.ink}" stop-opacity="${r(Math.min(.62*(.2+.8*sm(t)),1))}"/>`;}
const dy2=an('y2',a=>r(geo(a).Y(.55*H)));d+=`<linearGradient id="dg" gradientUnits="userSpaceOnUse" x1="0" x2="0" y1="${H}" ${dy2.a}>${dy2.c}${dst}</linearGradient>`;
const dop=an('opacity',a=>r(dimS(prog(a))));
b+=`<g clip-path="url(#hc)"><rect width="${W}" height="${H}" fill="#000"/><g mask="url(#om)"><use href="#lean"/>${bands}<rect width="${W}" height="${H}" fill="url(#dg)" ${dop.a}>${dop.c}</rect></g>`;
// static UI
d+=`<linearGradient id="httl" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff"/><stop offset="1" stop-color="#FFE2C4"/></linearGradient><linearGradient id="hfill" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="${P.peach}"/><stop offset=".5" stop-color="${P.pink}"/><stop offset="1" stop-color="${P.violet}"/></linearGradient><linearGradient id="hrim" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".55"/><stop offset=".42" stop-color="#fff" stop-opacity=".08"/><stop offset="1" stop-color="${P.peach}" stop-opacity=".38"/></linearGradient><linearGradient id="hsh" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".14"/><stop offset=".5" stop-color="#fff" stop-opacity=".03"/><stop offset="1" stop-color="#fff" stop-opacity="0"/></linearGradient><linearGradient id="hfr" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#fff" stop-opacity=".3"/><stop offset=".5" stop-color="#fff" stop-opacity=".05"/><stop offset="1" stop-color="${P.peach}" stop-opacity=".25"/></linearGradient><filter id="hkg" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="4"/></filter><clipPath id="hgc"><rect x="572" y="270" width="252" height="124" rx="22"/></clipPath>`;
const ttlY=312,capTop=ttlY-56*.705,pillY=368,artTop=capTop-3,artH=pillY+26-artTop,isz=artH/(.898-.0977),iy=artTop-isz*.0977,ix=40-isz*.0977;
b+=`<image href="${ICON}" x="${r(ix)}" y="${r(iy)}" width="${r(isz)}" height="${r(isz)}"/>`;
const TX=(x,y,s,o)=>`<text x="${x}" y="${y}" font-family="${o.family||SANS}" font-size="${o.size}" font-weight="${o.weight||400}" fill="${o.fill||'#F4F2FF'}"${o.op?` fill-opacity="${o.op}"`:''}${o.anchor?` text-anchor="${o.anchor}"`:''}${o.ls?` letter-spacing="${o.ls}"`:''}${o.extra||''}>${s}</text>`;
b+=TX(186,ttlY,'Duo Fold',{size:56,weight:700,fill:'url(#httl)',family:DISP,ls:-1.2})+TX(188,344,'The iPhone Duo effect on macOS, done right.',{size:17,weight:500,op:.82});
{const pills=['macOS 14+','Apple Silicon &amp; Intel','No Permissions'];const ws=pills.map(c=>Math.round(mw(c.replace(/&amp;/g,'&'),10.5,600))+20);const gap=10;let px=188;pills.forEach((c,i)=>{const w=ws[i];b+=`<rect x="${r(px)}" y="${pillY}" width="${w}" height="26" rx="13" fill="#fff" fill-opacity=".1" stroke="#fff" stroke-opacity=".24"/>`+TX(r(px+10),pillY+17,c,{size:10.5,weight:600,op:.9});px+=w+gap;});}
b+=`<g clip-path="url(#hgc)"><image x="0" y="0" width="${W}" height="${H}" href="${PICB}" preserveAspectRatio="none"/><rect x="572" y="270" width="252" height="124" fill="#07041F" fill-opacity=".35"/><rect x="572" y="270" width="252" height="124" fill="#fff" fill-opacity=".07"/><rect x="572" y="270" width="252" height="124" fill="url(#hsh)"/></g><rect x="572.5" y="270.5" width="251" height="123" rx="21.5" stroke="url(#hrim)"/>`;
const tx0=594,tw=208,pos=a=>tx0+tw*a/130,fx=a=>pos(Math.max(Math.min(a,85),20)),TU=Array.from({length:121},(_,i)=>r4(i/120));
b+=TX(tx0,300,'Lid angle',{size:12.5,weight:500,op:.72});
{const vals=TU.map(t=>Math.round(lid(t)));const runs=[];let s=0;for(let i=1;i<=121;i++){if(i===121||vals[i]!==vals[s]){runs.push([vals[s],s/120,Math.min(i/120,1)]);s=i;}}const o={size:20,weight:650,anchor:'end',family:DISP};
 if(FR!==null)b+=TX(802,302,`${Math.round(lid(FR))}°`,o);else{b+=TX(802,302,`${vals[0]}°<set attributeName="opacity" to="0"/>`,o);for(const[v,t0,e]of runs){let vs,kt;if(t0<=0){vs='1;0';kt=`0;${r4(e)}`;}else if(e>=1){vs='0;1';kt=`0;${r4(t0)}`;}else{vs='0;1;0';kt=`0;${r4(t0)};${r4(e)}`;}b+=TX(802,302,`${v}°<animate attributeName="opacity" values="${vs}" keyTimes="${kt}" calcMode="discrete" dur="${dur}" repeatCount="indefinite"/>`,{...o,extra:' opacity="0"'});}}}
const ax=an('x',a=>r(fx(a)),TU),aw=an('width',a=>r(pos(85)-fx(a)),TU),ac=an('cx',a=>r(pos(a)),TU);
b+=`<rect x="${tx0}" y="329" width="${tw}" height="6" rx="3" fill="#fff" fill-opacity=".16"/><rect x="${r(pos(20))}" y="329" width="${r(pos(85)-pos(20))}" height="6" fill="${P.pink}" fill-opacity=".22"/><rect ${ax.a} y="329" ${aw.a} height="6" fill="url(#hfill)">${ax.c}${aw.c}</rect><rect x="${r(pos(85)-1)}" y="324" width="2" height="16" rx="1" fill="#fff" fill-opacity=".9"/><rect x="${r(pos(20)-1)}" y="326" width="2" height="12" rx="1" fill="#fff" fill-opacity=".5"/><circle ${ac.a} cy="332" r="12" fill="${P.pink}" fill-opacity=".55" filter="url(#hkg)">${ac.c}</circle><circle ${ac.a} cy="332" r="7.5" fill="#fff">${ac.c}</circle>`;
{const ST=[['Lid open · effect off',a=>a>85,'#FFE2C4'],['Closing · blur and lean building',a=>a<=85&&a>20,P.pink],['Full effect · frosted and leaning',a=>a<=20,'#A99BFF']];
 for(const[lab,on,col]of ST){const vis=FR!==null?(on(lid(FR))?1:0):null;const vals=TU.map(t=>on(lid(t))?1:0).join(';');const a=vis!==null?`opacity="${vis}"`:`opacity="${on(lid(0))?1:0}"`;const c=FR!==null?'':`<animate attributeName="opacity" values="${vals}" keyTimes="${TU.join(';')}" calcMode="discrete" dur="${dur}" repeatCount="indefinite"/>`;
  b+=`<g ${a}>${c}<circle cx="${tx0+5}" cy="368" r="4" fill="${col}"/>`+TX(tx0+16,372,lab,{size:11.5,weight:500,op:.78})+`</g>`;}}
b+=`</g><rect x=".5" y=".5" width="${W-1}" height="${H-1}" rx="${R-.5}" stroke="url(#hfr)"/>`;
const out=`<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}" fill="none" role="img" aria-label="Duo Fold: the iPhone Duo effect on macOS, done right. The screen leans back, blurs and dims as a lid gauge sweeps toward closed."><defs>${d}</defs>${b}</svg>\n`;
if(FR!==null)await saveFile(`readme/src/hero-t${FR}.svg`,out);else{await saveFile('readme/full/hero.svg.txt',out);await saveFile('readme/assets/hero.svg',out);}
log('hero KB',(out.length/1024).toFixed(0),'frozen at',FR);
})()
