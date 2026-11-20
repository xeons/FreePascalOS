export let count = 0;
export function increment() { return ++count; }
export default function () { return "anonymous default"; }
export const answer = 42, [first, second] = [1, 2], { nested: renamedNested } = { nested: "deep" };
export class Shape { area() { return 0; } }
let hidden = "hidden";
export { hidden as "quoted name", hidden as visible };
