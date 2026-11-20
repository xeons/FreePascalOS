import { getA, a } from "./cycle-a.mjs";
export const b = "B";
export function readA() { try { return a; } catch (e) { return e.constructor.name; } }
console.log("cycle-b body, getA is", typeof getA, "a:", readA());
