#!/usr/bin/env node
// Optional developer check. Synthetic speech only; no microphone or provider credentials.
import {parseArgs} from 'node:util';
import {spawnSync} from 'node:child_process';
import {mkdtemp,mkdir,readFile,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join,resolve} from 'node:path';
import {SpeechModels} from '../../service/lib/speech-models.js';
import {validateWav} from '../../service/lib/wav.js';
import {splitExplanation} from '../../service/lib/explanation-context.js';
const {values}=parseArgs({options:{'models-dir':{type:'string'},output:{type:'string'}}});
if(process.platform!=='darwin'||!values['models-dir']||!values.output)throw Error('Requires macOS, --models-dir EXISTING_PUBLIC_WEIGHTS and --output REPORT.json. No download is performed.');
const temp=await mkdtemp(join(tmpdir(),'typeleast-markers-'));
const report=[];
try {
    for(const [voice,id] of [['Tingting','tingting'],['Eddy (中文（中国大陆）)','eddy'],['Reed (中文（中国大陆）)','reed']]) {
        for(const [kind,start,end] of [['short','备注','说完了'],['legacy','补充背景开始','补充背景结束']]) {
            const aiff=join(temp,id+'-'+kind+'.aiff'),wav=join(temp,id+'-'+kind+'.wav');
            for(const [command,args] of [['say',['-v',voice,'-o',aiff,`我想买一台电脑。${start}，电脑用于剪辑视频，${end}。预算不超过一万元。`]],['afconvert',['-f','WAVE','-d','LEI16@16000','-c','1',aiff,wav]]]) {
                const process=spawnSync(command,args,{stdio:'pipe'});if(process.status!==0)throw Error('Synthetic audio generation failed: '+command);
            }
            // afconvert may include ancillary chunks. Rebuild the canonical PCM header.
            const input=await readFile(wav);let offset=12,data;
            while(offset+8<=input.length){const name=input.toString('ascii',offset,offset+4),size=input.readUInt32LE(offset+4);if(name==='data'){data=input.subarray(offset+8,offset+8+size);break;}offset+=8+size+(size%2);}
            if(!data)throw Error('No PCM data');
            const canonical=Buffer.alloc(44+data.length);canonical.write('RIFF');canonical.writeUInt32LE(36+data.length,4);canonical.write('WAVEfmt ',8);canonical.writeUInt32LE(16,16);canonical.writeUInt16LE(1,20);canonical.writeUInt16LE(1,22);canonical.writeUInt32LE(16000,24);canonical.writeUInt32LE(32000,28);canonical.writeUInt16LE(2,32);canonical.writeUInt16LE(16,34);canonical.write('data',36);canonical.writeUInt32LE(data.length,40);data.copy(canonical,44);validateWav(canonical,120);await writeFile(wav,canonical);
            report.push({voice:id,kind,wav});
        }
    }
    const model=new SpeechModels({modelsDir:resolve(values['models-dir']),selectionPath:join(temp,'selection.json'),numThreads:2});
    model.start('qwen3-asr-0.6b',{download:false});await model.job;if(!model.snapshot().ready)throw Error('Existing 0.6B model could not load');
    for(const item of report){const recognized=await model.transcribe(await readFile(item.wav),'zh');delete item.wav;item.raw=recognized.text;const parsed=splitExplanation(item.raw,'note');item.balanced=parsed.used&&!parsed.issue;item.body=parsed.text;}
    await writeFile(resolve(values.output),JSON.stringify({model:'qwen3-asr-0.6b',synthetic:true,report},null,2)+'\n');
    console.log(JSON.stringify(report.map(({voice,kind,balanced})=>({voice,kind,balanced}))));
} finally {await rm(temp,{recursive:true,force:true});}
