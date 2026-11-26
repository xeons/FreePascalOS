// Web Animations (checks after WPT's web-animations tests): the
// interfaces, document.timeline, Element.animate and its options,
// keyframes in both forms with computed offsets and their errors, the
// timing model through getComputedTiming, play states and pending play,
// pause, seeking, finish and its event and promise, cancel, reverse,
// playbackRate and updatePlaybackRate, getAnimations.
check("the interfaces exist", typeof Animation === "function" && typeof KeyframeEffect === "function" &&
  typeof AnimationEffect === "function" && typeof DocumentTimeline === "function" &&
  typeof AnimationTimeline === "function" && typeof AnimationPlaybackEvent === "function" &&
  typeof CSSAnimation === "function" && typeof CSSTransition === "function");
check("document.timeline", document.timeline instanceof DocumentTimeline && document.timeline === document.timeline &&
  typeof document.timeline.currentTime === "number");
check("Element.animate exists", typeof document.body.animate === "function" &&
  typeof document.getAnimations === "function");

document.body.innerHTML = '<div id="box"></div><div id="other"><span id="child"></span></div>';
var box = document.getElementById("box");

var animation = box.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 1000, id: "fade" });
check("animate returns a pending running Animation", animation instanceof Animation && animation.id === "fade" &&
  animation.playState === "running" && animation.pending === true && animation.currentTime === 0);
check("its effect is a KeyframeEffect on the element", animation.effect instanceof KeyframeEffect &&
  animation.effect.target === box && animation.timeline === document.timeline);
var frames = animation.effect.getKeyframes();
check("getKeyframes with computed offsets", frames.length === 2 && frames[0].offset === null &&
  frames[0].computedOffset === 0 && frames[1].computedOffset === 1 && frames[0].opacity === "0" &&
  frames[0].easing === "linear" && frames[0].composite === "auto");
check("getAnimations finds it", box.getAnimations().length === 1 && box.getAnimations()[0] === animation &&
  document.getAnimations().indexOf(animation) >= 0);

var timing = animation.effect.getComputedTiming();
check("getComputedTiming at the start", timing.duration === 1000 && timing.activeDuration === 1000 &&
  timing.endTime === 1000 && timing.localTime === 0 && timing.progress === 0 && timing.currentIteration === 0);

animation.pause();
check("pause makes it paused and pending", animation.playState === "paused" && animation.pending === true);
animation.currentTime = 250;
check("seeking a paused animation", animation.currentTime === 250 && animation.pending === false &&
  animation.effect.getComputedTiming().progress === 0.25);

// Keyframes in the property-indexed form, offsets spread evenly.
var effect = new KeyframeEffect(box, { opacity: [0, 0.5, 1], easing: "ease-in" }, 500);
var indexed = effect.getKeyframes();
check("property-indexed keyframes", indexed.length === 3 && indexed[1].computedOffset === 0.5 &&
  indexed[1].opacity === "0.5" && indexed[0].easing === "ease-in" && effect.getTiming().duration === 500);
var middle = new KeyframeEffect(null, [{ opacity: 0 }, { opacity: 0.2 }, { opacity: 0.4, offset: 0.8 },
  { opacity: 1 }]);
check("missing offsets are spread between their neighbours",
  Math.abs(middle.getKeyframes()[1].computedOffset - 0.4) < 1e-9);
function keyframeError(keyframes) {
  try { new KeyframeEffect(null, keyframes); } catch (e) { return e.constructor.name; }
  return "none";
}
check("offsets out of order or range throw TypeError", keyframeError([{ offset: 0.6 }, { offset: 0.4 }]) ===
  "TypeError" && keyframeError([{ offset: 1.5 }]) === "TypeError" &&
  keyframeError([{ easing: "bounce" }]) === "TypeError");
function timingError(options) {
  try { new KeyframeEffect(null, null, options); } catch (e) { return e.constructor.name; }
  return "none";
}
check("bad timing throws TypeError", timingError({ duration: -1 }) === "TypeError" &&
  timingError({ iterations: NaN }) === "TypeError" && timingError({ iterationStart: -1 }) === "TypeError" &&
  timingError({ fill: "sideways" }) === "TypeError" && timingError({ duration: "1s" }) === "TypeError");

// The timing model.
var timed = new Animation(new KeyframeEffect(null, null, { duration: 100, iterations: 3, delay: 50,
  direction: "alternate", fill: "both" }), document.timeline);
timed.currentTime = 0;
check("before the delay with backwards fill", timed.effect.getComputedTiming().progress === 0 &&
  timed.effect.getComputedTiming().currentIteration === 0);
timed.currentTime = 175;
var midIteration = timed.effect.getComputedTiming();
check("alternate direction in the second iteration", midIteration.currentIteration === 1 &&
  Math.abs(midIteration.progress - 0.75) < 1e-9);
timed.currentTime = 400;
check("after the end with forwards fill", timed.effect.getComputedTiming().progress === 1 &&
  timed.effect.getComputedTiming().currentIteration === 2 && timed.effect.getComputedTiming().endTime === 350);
var unfilled = new Animation(new KeyframeEffect(null, null, { duration: 100 }), document.timeline);
unfilled.currentTime = 150;
check("after the end without fill: no progress", unfilled.effect.getComputedTiming().progress === null);
var eased = new Animation(new KeyframeEffect(null, null, { duration: 100, easing: "steps(2)" }), document.timeline);
eased.currentTime = 60;
check("the effect's easing transforms progress", eased.effect.getComputedTiming().progress === 0.5);
timed.effect.updateTiming({ duration: 200 });
check("updateTiming", timed.effect.getTiming().duration === 200 && timed.effect.getTiming().iterations === 3);

// Finishing.
var finishing = box.animate({ opacity: [1, 0] }, 1000);
var finishEvents = [];
finishing.onfinish = function (event) {
  finishEvents.push(event instanceof AnimationPlaybackEvent && event.currentTime === 1000);
};
var finishedResult = null;
finishing.finished.then(function (value) { finishedResult = value; });
finishing.finish();
check("finish() jumps to the end", finishing.playState === "finished" && finishing.currentTime === 1000 &&
  finishEvents.length === 1 && finishEvents[0] === true);
var infinite = box.animate(null, { duration: 100, iterations: Infinity });
var infiniteError = null;
try { infinite.finish(); } catch (e) { infiniteError = e; }
check("an infinite animation cannot finish", infiniteError !== null && infiniteError.name === "InvalidStateError");

// Cancelling.
var cancelled = box.animate(null, 1000);
var cancelEvents = 0;
cancelled.addEventListener("cancel", function () { cancelEvents++; });
var rejected = null;
cancelled.finished.catch(function (error) { rejected = error; });
cancelled.cancel();
check("cancel makes it idle and fires cancel", cancelled.playState === "idle" && cancelled.currentTime === null &&
  cancelled.startTime === null && cancelEvents === 1 && box.getAnimations().indexOf(cancelled) < 0);

// Reversing and playback rate.
var reversing = box.animate(null, 1000);
reversing.currentTime = 300;
reversing.reverse();
check("reverse plays backwards from where it was", reversing.playbackRate === 1 && reversing.pending === true);
var rated = box.animate(null, 1000);
rated.playbackRate = 2;
rated.currentTime = 400;
check("playbackRate", rated.playbackRate === 2 && rated.currentTime === 400);
rated.pause();
rated.updatePlaybackRate(0.5);
check("updatePlaybackRate waits for a pending pause", rated.playbackRate === 2);

// A new Animation with no effect.
var empty = new Animation();
check("a new Animation is idle", empty.playState === "idle" && empty.effect === null && empty.currentTime === null);
var readyResult = null;
var later = box.animate(null, 1000);
later.ready.then(function (value) { readyResult = value; });

var event = new AnimationPlaybackEvent("finish", { currentTime: 5, timelineTime: 10 });
check("AnimationPlaybackEvent", event.type === "finish" && event.currentTime === 5 && event.timelineTime === 10);

check("subtree getAnimations", (function () {
  var child = document.getElementById("child");
  var childAnimation = child.animate(null, 1000);
  var other = document.getElementById("other");
  return other.getAnimations().length === 0 && other.getAnimations({ subtree: true })[0] === childAnimation;
})());

// The harness runs timers until none are left: stop what would run on.
check("ready is pending until the next frame", later.pending === true);
document.getAnimations().forEach(function (running) {
  if (running !== later) running.cancel();
});
setTimeout(function () { later.cancel(); }, 40);

function after() {
  check("ready resolved at a frame", readyResult === later);
  check("finished resolves with the animation", finishedResult === finishing);
  check("a cancelled animation's finished promise rejects with AbortError", rejected !== null &&
    rejected.name === "AbortError");
}
