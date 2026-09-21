import Anthropic from "@anthropic-ai/sdk";

let client: Anthropic | undefined;
/** Legacy Claude routes initialize their client only when used. */
export function getAnthropic(): Anthropic {
  return client ??= new Anthropic();
}
