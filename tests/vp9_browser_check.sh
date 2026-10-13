#!/usr/bin/env bash
# Development-only Chromium oracle; Node drives its private debugging pipe.
set -euo pipefail
node --input-type=module - "$@" <<'JS'
// Development-only Chromium transparency check; no npm packages or server.
import {readFileSync, writeFileSync, mkdirSync} from 'node:fs';
import {resolve} from 'node:path';
import {spawn} from 'node:child_process';
const [prefix, ws, hs, fs] = process.argv.slice(2);
const width = Number(ws), height = Number(hs), frames = Number(fs);
const video = readFileSync(`${prefix}.webm`).toString('base64');
const expected = readFileSync(`${prefix}.alpha.rec.yuv`).toString('base64');
const page = `<!doctype html><meta charset="utf-8"><body>WAIT<script>
(async () => {
 const w=${width},h=${height},frames=${frames};
 const expected=Uint8Array.from(atob('${expected}'),c=>c.charCodeAt(0));
 const stride=w*h+2*Math.ceil(w/2)*Math.ceil(h/2);
 const video=document.createElement('video'); video.muted=true; video.preload='auto';
 const loaded=new Promise((ok,fail)=>{video.onloadeddata=ok;video.onerror=()=>fail(new Error('video decode error'));});
 video.src='data:video/webm;base64,${video}'; document.body.append(video); await loaded;
 const canvas=document.createElement('canvas');canvas.width=w;canvas.height=h;
 document.body.append(canvas);const ctx=canvas.getContext('2d',{willReadFrequently:true});
 let fractional=0,transparent=0,opaque=0,maxAlpha=0,maxComposite=0;
 for(let f=0;f<frames;f++){
  if(f){const seeked=new Promise(ok=>video.onseeked=ok);video.currentTime=f/30+0.001;await seeked;}
  ctx.clearRect(0,0,w,h);ctx.drawImage(video,0,0);
  const rgba=ctx.getImageData(0,0,w,h).data;
  for(let i=0;i<w*h;i++){
   const a=rgba[i*4+3],e=expected[f*stride+i];maxAlpha=Math.max(maxAlpha,Math.abs(a-e));
   if(e===0)transparent++;else if(e===255)opaque++;else fractional++;
  }
  for(const bg of [[23,71,149],[201,33,17]]){
   ctx.fillStyle='rgb('+bg.join(',')+')';ctx.fillRect(0,0,w,h);ctx.drawImage(video,0,0);
   const pixels=ctx.getImageData(0,0,w,h).data;
   for(let i=0;i<w*h;i++)for(let c=0;c<3;c++){
    const a=expected[f*stride+i]/255;
    const e=Math.round(rgba[i*4+c]*a+bg[c]*(1-a));
    maxComposite=Math.max(maxComposite,Math.abs(pixels[i*4+c]-e));
   }
  }
 }
 if(maxAlpha>1||maxComposite>2||!fractional||!transparent||!opaque)throw new Error(JSON.stringify({maxAlpha,maxComposite,fractional,transparent,opaque}));
 document.body.textContent='PASS browser transparency '+JSON.stringify({frames,maxAlpha,maxComposite,fractional,transparent,opaque});
})().catch(e=>document.body.textContent='FAIL '+e.stack);
</script>`;
const html = resolve(`${prefix}.html`);
writeFileSync(html, page);
const profile = resolve(`${prefix}.chromium-profile`);
mkdirSync(profile, {recursive:true});
const child = spawn(process.env.CHROMIUM || 'chromium', [
 '--headless','--disable-gpu','--no-sandbox',`--user-data-dir=${profile}`,
 '--allow-file-access-from-files','--autoplay-policy=no-user-gesture-required',
 '--remote-debugging-pipe','about:blank'
], {stdio:['ignore','ignore','pipe','pipe','pipe']});
let stderr='', buffer='', nextId=0;
const pending=new Map();
child.stderr.on('data', bytes=>stderr+=bytes);
child.stdio[4].on('data',bytes=>{
 buffer+=bytes.toString();
 let at;
 while((at=buffer.indexOf('\0'))>=0){
  const text=buffer.slice(0,at);buffer=buffer.slice(at+1);
  if(!text)continue;
  const message=JSON.parse(text), request=pending.get(message.id);
  if(request){pending.delete(message.id);message.error?request.reject(message.error):request.resolve(message.result);}
 }
});
function call(method,params={},sessionId){
 return new Promise((resolve,reject)=>{
  const id=++nextId;pending.set(id,{resolve,reject});
  child.stdio[3].write(JSON.stringify({id,method,params,sessionId})+'\0');
 });
}
const timer=setTimeout(()=>{console.error('Chromium timeout',stderr);child.kill();process.exit(1);},25000);
try{
 const {targetId}=await call('Target.createTarget',{url:`file://${html}`});
 const {sessionId}=await call('Target.attachToTarget',{targetId,flatten:true});
 let result;
 for(let i=0;i<200;i++){
  const response=await call('Runtime.evaluate',{expression:'document.body?.textContent || ""',returnByValue:true},sessionId);
  const value=response.result.value || '';
  if(value.startsWith('FAIL'))throw new Error(value);
  if(value.startsWith('PASS')){result=value;break;}
  await new Promise(ok=>setTimeout(ok,100));
 }
 if(!result)throw new Error('Browser did not finish');
 console.log(result);
}catch(error){console.error(error,stderr);process.exitCode=1;}
finally{clearTimeout(timer);child.kill();}

JS
