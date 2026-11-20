import { b, readA } from "./cycle-b.mjs";
export let a = "A";
console.log("cycle-a body:", b, readA());
export function getA() { return a; }
