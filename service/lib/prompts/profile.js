/**
 * The hidden description of the user's work. Each app sends the corrections and intentions
 * stored in its history when it starts; the answer is added to later cleanup prompts.
 */
import { PROFILE_LIMIT } from "./cleanup.js";
import { unwrap } from "../validate.js";

/** How many history items, and how much of them, one description is built from. */
export const PROFILE_INPUT = { items: 100, chars: 24000 };

export const PROFILE_PROMPT = `下面是用户过去口述的整理记录，每条包含模型纠正过的术语和用户意图。据此写一段描述：这位用户通常在做什么工作、涉及哪些领域、常用哪些专有名词和工具，供以后整理这位用户的口述时参考。只写记录里能看出的内容，不推测个人身份。不超过 ${PROFILE_LIMIT} 个字符。只输出这段描述。`;

/** The newest items first, bounded; "" when there is nothing to learn from. */
export function profileMessage(items) {
  const lines = [];
  let size = 0;
  for (const item of Array.isArray(items) ? items.slice(0, PROFILE_INPUT.items) : []) {
    const corrections = (Array.isArray(item?.corrections) ? item.corrections : [])
      .filter(c => typeof c?.from === "string" && typeof c?.to === "string")
      .slice(0, 40).map(c => `${c.from.slice(0, 120)} → ${c.to.slice(0, 120)}`);
    const intention = typeof item?.intention === "string" ? item.intention.trim().slice(0, 600) : "";
    if (!corrections.length && !intention) continue;
    const line = JSON.stringify({ corrections, intention });
    if (size + line.length > PROFILE_INPUT.chars) break;
    lines.push(line);
    size += line.length;
  }
  return lines.join("\n");
}

/** The model's answer as one bounded paragraph. */
export function readProfile(text) {
  const plain = unwrap(String(text ?? "")).text.replace(/\s+/gu, " ").trim();
  return Array.from(plain).slice(0, PROFILE_LIMIT).join("");
}
