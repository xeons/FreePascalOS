import { slow } from "./tla-slow.mjs";
import { fast } from "./tla-fast.mjs";
console.log("user sees", slow, fast);
export const user = slow + "/" + fast;
