/** Only redundant punctuation runs are changed. Literal spans remain byte-for-byte intact. */
const literals=/\.{2,}|…+|```[\s\S]*?```|`[^`\n]*`|https?:\/\/[^\s<>]+|(?:[A-Za-z]:[\\/]|\/)[^\s，。；！？]+|[“「『"][^”」』"\n]*[”」』"]|[A-Za-z_][A-Za-z0-9_\-]*(?:\.[A-Za-z0-9_\-]+)+|\d+(?:\.\d+)+/gu;
const weak=new Set([',','，','、']);
const end=new Set(['.','。','!','！','?','？']);
function clean(s) {
 const chars=Array.from(s);let out='';
 for(let i=0;i<chars.length;i++) {
  const c=chars[i];
  if(weak.has(c)) {
   let j=i+1;while(j<chars.length&&/[ \t]/u.test(chars[j]))j++;
   if(end.has(chars[j])) {
    const equivalent=x=>({'.':'。','!':'！','?':'？'}[x]??x);
    if(end.has(out.at(-1))&&equivalent(out.at(-1))===equivalent(chars[j])){i=j;continue;}
    const terminal=c==='，'||c==='、'?({'.':'。','!':'！','?':'？'}[chars[j]]??chars[j]):chars[j];
    const latinBefore=/[A-Za-z]$/u.test(out);
    out+=terminal;i=j;
    if(latinBefore&&/[.!?]/u.test(terminal)&&/[A-Za-z]/u.test(chars[j+1]??''))out+=' ';
    continue;
   }
   if(weak.has(chars[j]))continue;
   if(end.has(out.at(-1)))continue;
  }
  out+=c;
 }
 return out;
}
export function mapOutsideLiterals(text, transform) {
 const source=String(text??'');let out='',from=0;
 for(const m of source.matchAll(literals)){out+=transform(source.slice(from,m.index))+m[0];from=m.index+m[0].length;}
 return out+transform(source.slice(from));
}

export function normalizePunctuation(text) { return mapOutsideLiterals(text,clean); }

export function protectLiterals(text, transform) {
 const source=String(text??'');let prefix='TYPELEAST_LITERAL_';while(source.includes(prefix))prefix+='_';
 const saved=[];const masked=source.replace(literals,value=>{const token=prefix+saved.length+'_END';saved.push([token,value]);return token;});
 let out=transform(masked);for(const [token,value] of saved)out=out.split(token).join(value);return out;
}
