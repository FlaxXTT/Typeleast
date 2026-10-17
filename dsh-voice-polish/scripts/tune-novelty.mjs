import { preciseNovelty, novelty } from '../lib/validate.js';

/**
 * Calibration table: made-up transcripts shaped like real dictation (fillers,
 * self-corrections, rambles) paired with faithful clean-ups, plus deliberate fabrications. A usable threshold
 * has to separate these two groups with margin.
 */
const CASES = [
  ['legit: filler complaint',
   "此外，表格的呃这些列宽还不够整齐。比如呃嗯。 啊日期这一列还是太窄了。",
   "此外，表格的列宽还不够整齐，比如“日期”这一列还是太窄了。"],
  ['legit: self-correction',
   "um so we're going to send it tuesday, no wait, wednesday",
   "We're going to send it Wednesday."],
  ['legit: filler removal',
   "另外，这份会议纪要你帮我理一下嘛，重复的地方删掉，那些嗯啊的也去掉，顺序呢也帮我调一调，行吗？",
   "另外，这份会议纪要请帮我理一下：删掉重复的地方，去掉嗯、啊这类停顿，再调一调顺序。行吗？"],
  ['legit: list restructuring',
   "so we need to do three things first update the parser second add tests third write the docs",
   "We need to do three things:\n1. Update the parser.\n2. Add tests.\n3. Write the docs."],
  ['legit: retention ramble restructured',
   "嗯，先说一件事啊，手机相册里攒了好多截图嘛，我不太想留那么多，因为空间越来越小了",
   "先说一件事：手机相册里攒了很多截图，我不想留那么多，因为空间越来越小了。"],
  ['FABRICATION: adds recipient + deadline',
   "此外，表格的呃这些列宽还不够整齐。",
   "此外，请把整理结果发给张伟，并在周五前完成季度预算审批。"],
  ['FABRICATION: adds requirements',
   "帮我做一个语音输入软件",
   "帮我做一个语音输入软件，需要支持 Windows 和 Linux，并且要集成到 VS Code，预算不超过两千元。"],
  ['FABRICATION: whole new topic',
   "we need to finish the migration before the release",
   "Book the Berlin offsite, confirm catering with finance, and notify the legal team."],
];

let worstLegit = 0;
let bestFabrication = 1;
for (const [label, raw, output] of CASES) {
  const p = preciseNovelty(raw, output);
  const c = novelty(raw, output);
  if (label.startsWith('FABRICATION')) bestFabrication = Math.min(bestFabrication, p);
  else worstLegit = Math.max(worstLegit, p);
  console.log(label.padEnd(40) + 'precise=' + p.toFixed(3) + '  coarse=' + c.toFixed(3));
}
console.log('');
console.log('worst legitimate   = ' + worstLegit.toFixed(3));
console.log('best fabrication   = ' + bestFabrication.toFixed(3));
console.log('separation gap     = ' + (bestFabrication - worstLegit).toFixed(3));
console.log('midpoint threshold = ' + ((worstLegit + bestFabrication) / 2).toFixed(3));
