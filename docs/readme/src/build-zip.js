// Packs the deliverable: README.md + assets/, using the pristine animated SVGs from readme/full/.
// Run inside run_script:   const src = await readFile('readme/src/build-zip.js'); await eval(src);
// Set `var ZIP_SYSTEM = true` before eval to pack the whole system (src/, full/, preview) instead.
(async()=>{
const SYSTEM=typeof ZIP_SYSTEM!=='undefined'&&ZIP_SYSTEM;
const ANIMATED={'hero.svg':1,'diagrams/anatomy.svg':1,'diagrams/curve.svg':1,'diagrams/haptics.svg':1,'diagrams/pipeline.svg':1};
const BIN=/\.(png|jpg|jpeg|icns|zip)$/i;
const enc=new TextEncoder();const entries=[];
const add=async(name,path,text)=>{const data=text!==undefined?enc.encode(text):BIN.test(path)?new Uint8Array(await (await readFileBinary(path)).arrayBuffer()):enc.encode(await readFile(path));entries.push({name,data});};
const walk=async dir=>{const out=[];for(const n of await ls(dir)){const p=dir+'/'+n;if(/\.[A-Za-z0-9]+$/.test(n))out.push(p);else out.push(...await walk(p));}return out;};
await add('README.md','readme/README.md');
for(const p of await walk('readme/assets')){const rel=p.replace('readme/assets/','');if(ANIMATED[rel])await add('assets/'+rel,'readme/full/'+rel+'.txt');else await add('assets/'+rel,p);}
if(SYSTEM){
  for(const p of await walk('readme/full'))await add('system/full/'+p.replace('readme/full/',''),p);
  for(const p of await walk('readme/src'))await add('system/src/'+p.replace('readme/src/',''),p);
  await add('system/README Preview.dc.html','README Preview.dc.html');
  await add('system/HOWTO.md','readme/HOWTO.md');
}
const crcT=new Uint32Array(256).map((_,n)=>{let c=n;for(let k=0;k<8;k++)c=c&1?0xEDB88320^(c>>>1):c>>>1;return c>>>0;});
const crc=u=>{let c=0xFFFFFFFF;for(let i=0;i<u.length;i++)c=crcT[(c^u[i])&255]^(c>>>8);return (c^0xFFFFFFFF)>>>0;};
const parts=[],central=[];let off=0;
for(const e of entries){const nm=enc.encode(e.name),cc=crc(e.data),len=e.data.length;const lh=new DataView(new ArrayBuffer(30));lh.setUint32(0,0x04034b50,true);lh.setUint16(4,20,true);lh.setUint16(6,0x0800,true);lh.setUint16(12,0x21,true);lh.setUint32(14,cc,true);lh.setUint32(18,len,true);lh.setUint32(22,len,true);lh.setUint16(26,nm.length,true);parts.push(new Uint8Array(lh.buffer),nm,e.data);
 const ch=new DataView(new ArrayBuffer(46));ch.setUint32(0,0x02014b50,true);ch.setUint16(4,20,true);ch.setUint16(6,20,true);ch.setUint16(8,0x0800,true);ch.setUint16(14,0x21,true);ch.setUint32(16,cc,true);ch.setUint32(20,len,true);ch.setUint32(24,len,true);ch.setUint16(28,nm.length,true);ch.setUint32(42,off,true);central.push(new Uint8Array(ch.buffer),nm);off+=30+nm.length+len;}
const cs=central.reduce((x,y)=>x+y.length,0);const ed=new DataView(new ArrayBuffer(22));ed.setUint32(0,0x06054b50,true);ed.setUint16(8,entries.length,true);ed.setUint16(10,entries.length,true);ed.setUint32(12,cs,true);ed.setUint32(16,off,true);
const out=SYSTEM?'DuoFold-README-System.zip':'DuoFold-README.zip';
await saveFile(out,new Blob([...parts,...central,new Uint8Array(ed.buffer)],{type:'application/zip'}));
const md=await readFile('readme/README.md');const refs=[...new Set([...md.matchAll(/assets\/[\w\/.-]+\.(?:svg|png)/g)].map(m=>m[0]))];const have=new Set(entries.map(e=>e.name));
log(out,entries.length,'entries;',Math.round(entries.reduce((a,e)=>a+e.data.length,0)/1024),'KB; missing README refs:',refs.filter(x=>!have.has(x)).join(', ')||'none');
})()
