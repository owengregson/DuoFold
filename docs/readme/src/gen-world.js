// Draws the "screen" the hero blurs and leans, then rasterises it with the margin the app uses.
// Run inside run_script:   const src = await readFile('readme/src/gen-world.js'); await eval(src);
// Outputs: readme/src/world.svg, readme/src/world.jpg.txt (base64 data URI, 2x, with a 100 px
// edge-stretched margin on the sides and top), readme/src/world-blur.jpg.txt (small blurred copy
// for the hero's gauge card). gen-hero.js reads the two .txt files.
(async()=>{
const W=860,H=420,P={pink:'#FF5FA2',mag:'#D63F8C',peach:'#FFB08A',cream:'#FFE2C4',coral:'#FF8A7A',violet:'#6F5BFF',lav:'#8E84B8',paper:'#F6F1FF'},LIL='#C9C1FF';
const r=n=>Math.round(n*100)/100;
let seed=11;const rnd=()=>(seed=(seed*16807)%2147483647)/2147483647;
const lights=(x,y,w,ins,lt)=>['#FF5F57','#FEBC2E','#28C840'].map((c,i)=>`<circle cx="${r(x+ins*.9+i*lt*2.9)}" cy="${r(y+ins*.9)}" r="${r(lt)}" fill="${c}"/>`).join('');
const win=(x,y,w,h,share)=>{const rad=w*.045,lt=w*.022,ins=w*.06;let s=`<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="${r(rad)}" fill="${P.paper}" fill-opacity=".96" filter="url(#ws)"/>`+lights(x,y,w,ins,lt);const ph=h*share,py=y+h-ins-ph;s+=`<rect x="${r(x+ins)}" y="${r(py)}" width="${r(w-2*ins)}" height="${r(ph)}" rx="${r(w*.02)}" fill="url(#ph)"/>`;const lh=w*.04;let ly=y+ins*.9+lt+lh*1.4;for(const f of [.9,.66,.8,.52,.72]){if(ly+lh>py-lh*.8)break;s+=`<rect x="${r(x+ins)}" y="${r(ly)}" width="${r((w-2*ins)*f)}" height="${r(lh)}" rx="${r(lh/2)}" fill="${P.lav}" fill-opacity=".65"/>`;ly+=lh*2;}return s;};
const edwin=(x,y,w,h)=>{seed=11;const rad=w*.04,lt=w*.022,ins=w*.06;let s=`<rect x="${x}" y="${y}" width="${w}" height="${h}" rx="${r(rad)}" fill="#1A1B36" fill-opacity=".97" filter="url(#ws)"/><rect x="${x+.5}" y="${y+.5}" width="${w-1}" height="${h-1}" rx="${r(rad)}" stroke="#fff" stroke-opacity=".12"/>`+lights(x,y,w,ins,lt);const sb=w*.26;s+=`<rect x="${r(x+sb)}" y="${r(y+ins*1.9)}" width="1" height="${r(h-ins*2.4)}" fill="#fff" fill-opacity=".08"/>`;const lh=Math.max(w*.02,1.2);for(let i=0;i<7;i++){const yy=y+ins*2.4+i*lh*2.4;if(yy>y+h-ins)break;s+=`<rect x="${r(x+ins*.9+(i%3?lh*1.5:0))}" y="${r(yy)}" width="${r(sb*(.45+rnd()*.3))}" height="${r(lh)}" rx="${r(lh/2)}" fill="${i===2?P.pink:P.lav}" fill-opacity="${i===2?.8:.45}"/>`;}const cols=[P.pink,P.peach,LIL,P.cream,P.lav];for(let i=0;;i++){const yy=y+ins*2.4+i*lh*2;if(yy>y+h-ins*1.1)break;let xx=x+sb+ins*.7+(i%4===0?0:lh*2*Math.floor(1+rnd()*3));const segs=1+Math.floor(rnd()*3);for(let k=0;k<segs;k++){const ww=w*(.05+rnd()*.14);if(xx+ww>x+w-ins)break;s+=`<rect x="${r(xx)}" y="${r(yy)}" width="${r(ww)}" height="${r(lh)}" rx="${r(lh/2)}" fill="${cols[Math.floor(rnd()*5)]}" fill-opacity=".85"/>`;xx+=ww+lh*1.2;}}return s;};
const menubar=(x,y,w,h)=>{let s=`<rect x="${x}" y="${y}" width="${w}" height="${h}" fill="#fff" fill-opacity=".13"/>`;const bh=h*.28,by=y+(h-bh)/2;let xx=x+h*.8;s+=`<circle cx="${r(xx)}" cy="${r(y+h/2)}" r="${r(h*.2)}" fill="#fff" fill-opacity=".85"/>`;xx+=h*.7;for(const f of [1.5,1.2,1.3,1.6,1.1]){s+=`<rect x="${r(xx)}" y="${r(by)}" width="${r(h*f)}" height="${r(bh)}" rx="${r(bh/2)}" fill="#fff" fill-opacity="${xx<x+h*2?.85:.6}"/>`;xx+=h*f+h*.6;}let rx=x+w-h*.8;for(const f of [2.2,.7,.7,.7]){rx-=h*f;s+=`<rect x="${r(rx)}" y="${r(by)}" width="${r(h*f)}" height="${r(bh)}" rx="${r(bh/2)}" fill="#fff" fill-opacity=".7"/>`;rx-=h*.55;}return s;};
const rg=(id,st)=>`<radialGradient id="${id}">${st.map(([o,c,a=1])=>`<stop offset="${o}" stop-color="${c}" stop-opacity="${a}"/>`).join('')}</radialGradient>`;
const defs=`<linearGradient id="bg" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#2A1E78"/><stop offset=".55" stop-color="#141A5E"/><stop offset="1" stop-color="#080C30"/></linearGradient>`+rg('pk',[[0,P.pink,.95],[.45,P.mag,.55],[1,P.mag,0]])+rg('pc',[[0,P.cream,1],[.35,P.peach,.75],[1,P.coral,0]])+rg('vi',[[0,P.violet,.65],[1,P.violet,0]])+`<filter id="ws" x="-25%" y="-25%" width="150%" height="160%"><feDropShadow dx="0" dy="8" stdDeviation="12" flood-color="#0A0530" flood-opacity=".5"/></filter><linearGradient id="ph" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#FFA27E"/><stop offset=".5" stop-color="#E0559A"/><stop offset="1" stop-color="#7B5CFF"/></linearGradient>`;
const body=`<rect width="${W}" height="${H}" fill="url(#bg)"/><ellipse cx="130" cy="455" rx="360" ry="260" fill="url(#pc)"/><ellipse cx="730" cy="120" rx="340" ry="260" fill="url(#pk)"/><ellipse cx="330" cy="150" rx="240" ry="190" fill="url(#vi)"/><ellipse cx="600" cy="440" rx="280" ry="170" fill="url(#pk)" opacity=".5"/>${menubar(0,0,W,24)}${edwin(30,50,262,178)}${win(528,46,284,182,.42)}${win(304,88,234,150,.4)}`;
const K=2;
await saveFile('readme/src/world.svg',`<svg xmlns="http://www.w3.org/2000/svg" width="${W*K}" height="${H*K}" viewBox="0 0 ${W} ${H}"><defs>${defs}</defs>${body}</svg>`);
// Rasterise. readImage needs the committed file, so this half runs on the previous save when the
// script is run twice; run it twice the first time (or once after world.svg already exists).
let img;try{img=await readImage('readme/src/world.svg');}catch(e){log('world.svg not committed yet; run again to rasterise');return;}
const M=100,MK=M*K;
const cv=createCanvas((W+2*M)*K,(H+M)*K),c=cv.getContext('2d');c.imageSmoothingEnabled=true;c.imageSmoothingQuality='high';
c.drawImage(img,MK,MK,W*K,H*K);
c.drawImage(img,0,0,1,img.height,0,MK,MK,H*K);c.drawImage(img,img.width-1,0,1,img.height,MK+W*K,MK,MK,H*K);
c.drawImage(img,0,0,img.width,1,MK,0,W*K,MK);c.drawImage(img,0,0,1,1,0,0,MK,MK);c.drawImage(img,img.width-1,0,1,1,MK+W*K,0,MK,MK);
const toURI=async(canvas,q)=>{const b=await canvas.convertToBlob({type:'image/jpeg',quality:q});const u=new Uint8Array(await b.arrayBuffer());let s='';for(let i=0;i<u.length;i+=8192)s+=String.fromCharCode.apply(null,u.subarray(i,i+8192));return 'data:image/jpeg;base64,'+btoa(s);};
await saveFile('readme/src/world.jpg.txt',await toURI(cv,.82));
const sw=215,sh=105,sc=createCanvas(sw,sh),s2=sc.getContext('2d');s2.drawImage(img,0,0,sw,sh);
const id=s2.getImageData(0,0,sw,sh),d=id.data;
const box=(src,dst,rad,vert)=>{for(let y=0;y<sh;y++)for(let x=0;x<sw;x++){let a=[0,0,0],n=0;for(let k=-rad;k<=rad;k++){const xx=vert?x:Math.min(Math.max(x+k,0),sw-1),yy=vert?Math.min(Math.max(y+k,0),sh-1):y,i=(yy*sw+xx)*4;a[0]+=src[i];a[1]+=src[i+1];a[2]+=src[i+2];n++;}const o=(y*sw+x)*4;dst[o]=a[0]/n;dst[o+1]=a[1]/n;dst[o+2]=a[2]/n;dst[o+3]=255;}};
let A=Float32Array.from(d),B=new Float32Array(d.length);for(let p=0;p<3;p++){box(A,B,3,false);box(B,A,3,true);}
for(let i=0;i<d.length;i++)d[i]=A[i];s2.putImageData(id,0,0);
await saveFile('readme/src/world-blur.jpg.txt',await toURI(sc,.85));
log('world rasterised');
})()
