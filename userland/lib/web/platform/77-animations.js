// Web Animations Level 1: AnimationTimeline and DocumentTimeline
// (document.timeline), AnimationEffect and KeyframeEffect (keyframes in
// both forms, computed offsets, the timing model), Animation (play,
// pause, finish, cancel, reverse, updatePlaybackRate, persist,
// commitStyles, ready and finished promises, finish, cancel and remove
// events), AnimationPlaybackEvent, Element.animate and getAnimations,
// and the CSS animations and transitions the layout runs as
// CSSAnimation and CSSTransition objects. The timing model is here; each
// frame every effect's progress goes to styling through the natives
// (Web.Style.ScriptAnimations), which interpolates the keyframes.
// Composite modes other than replace are applied as replace, and
// replaced animations are not removed automatically.
(function (natives, global, internal) {
  "use strict";
  const token = internal.token;
  const requestFrame = global.requestAnimationFrame;
  const performance = global.performance;

  // ---- timelines ----

  const timelineData = new WeakMap();
  class AnimationTimeline {
    constructor(key) {
      if (key !== token) internal.illegal();
    }
    get currentTime() {
      const state = timelineData.get(this);
      return state === undefined ? null : performance.now() - state.originTime;
    }
  }
  internal.finishInterface(AnimationTimeline, "AnimationTimeline");

  class DocumentTimeline extends AnimationTimeline {
    constructor(options) {
      super(token);
      const originTime = options == null || options.originTime === undefined ? 0 : Number(options.originTime);
      if (!isFinite(originTime)) throw new TypeError("originTime must be a finite number");
      timelineData.set(this, { originTime: originTime });
    }
  }
  internal.finishInterface(DocumentTimeline, "DocumentTimeline");

  let documentTimeline = null;
  function defaultTimeline() {
    if (documentTimeline === null) documentTimeline = new DocumentTimeline();
    return documentTimeline;
  }
  Object.defineProperty(global.Document.prototype, "timeline", { configurable: true, enumerable: true,
    get: function () { return defaultTimeline(); } });

  // ---- keyframes ----

  const easingPattern = new RegExp("^(linear|ease|ease-in|ease-out|ease-in-out|step-start|step-end|" +
    "cubic-bezier\\(.*\\)|steps\\(.*\\)|linear\\(.*\\))$");
  function checkEasing(value) {
    const text = String(value).trim();
    if (!easingPattern.test(text)) throw new TypeError("'" + value + "' is not a valid easing function");
    return text;
  }

  // backgroundColor -> background-color; cssFloat -> float.
  function cssName(property) {
    if (property === "cssFloat") return "float";
    if (property === "cssOffset") return "offset";
    if (property.startsWith("--")) return property;
    return property.replace(/[A-Z]/g, function (letter) { return "-" + letter.toLowerCase(); });
  }
  function scriptName(property) {
    if (property === "float") return "cssFloat";
    if (property.startsWith("--")) return property;
    return property.replace(/-([a-z])/g, function (match, letter) { return letter.toUpperCase(); });
  }

  const reservedMembers = ["offset", "easing", "composite"];
  function propertiesOf(source) {
    const properties = [];
    for (const key of Object.keys(source)) {
      if (reservedMembers.indexOf(key) >= 0) continue;
      properties.push(key);
    }
    return properties.sort();
  }

  function compositeOf(value) {
    if (value === undefined || value === null || value === "auto") return "auto";
    const text = String(value);
    if (text !== "replace" && text !== "add" && text !== "accumulate")
      throw new TypeError("'" + text + "' is not a valid composite operation");
    return text;
  }

  // "Process a keyframes argument": the array form and the
  // property-indexed form, as a list of {offset, easing, composite,
  // values: {scriptName: text}}.
  function processKeyframes(object) {
    if (object === null || object === undefined) return [];
    if (typeof object !== "object") throw new TypeError("keyframes must be an object or null");
    const frames = [];
    if (typeof object[Symbol.iterator] === "function") {
      for (const item of object) {
        if (item !== null && typeof item !== "object") throw new TypeError("a keyframe must be an object");
        const source = item === null ? {} : item;
        const frame = { offset: null, easing: "linear", composite: "auto", values: {} };
        if (source.offset !== undefined && source.offset !== null) {
          frame.offset = Number(source.offset);
          if (!isFinite(frame.offset)) throw new TypeError("a keyframe offset must be a finite number");
        }
        if (source.easing !== undefined) frame.easing = checkEasing(source.easing);
        frame.composite = compositeOf(source.composite);
        for (const property of propertiesOf(source)) frame.values[property] = String(source[property]);
        frames.push(frame);
      }
    } else {
      const lists = {};
      let longest = 0;
      for (const property of propertiesOf(object)) {
        const value = object[property];
        const list = Array.isArray(value) ? value.map(String) : [String(value)];
        lists[property] = list;
        if (list.length > longest) longest = list.length;
      }
      // Each property's values spread evenly over [0, 1].
      const byOffset = new Map();
      for (const property of Object.keys(lists)) {
        const list = lists[property];
        for (let index = 0; index < list.length; index++) {
          const offset = list.length === 1 ? 1 : index / (list.length - 1);
          let frame = byOffset.get(offset);
          if (frame === undefined) {
            frame = { offset: null, computed: offset, easing: "linear", composite: "auto", values: {} };
            byOffset.set(offset, frame);
          }
          frame.values[property] = list[index];
        }
      }
      const offsets = Array.from(byOffset.keys()).sort(function (a, b) { return a - b; });
      for (const offset of offsets) frames.push(byOffset.get(offset));
      const explicitOffsets = object.offset === undefined ? [] :
        (Array.isArray(object.offset) ? object.offset : [object.offset]);
      for (let index = 0; index < explicitOffsets.length && index < frames.length; index++)
        if (explicitOffsets[index] !== null) frames[index].offset = Number(explicitOffsets[index]);
      const easings = object.easing === undefined ? [] :
        (Array.isArray(object.easing) ? object.easing : [object.easing]);
      for (let index = 0; index < frames.length && easings.length > 0; index++)
        frames[index].easing = checkEasing(easings[index % easings.length]);
      const composites = object.composite === undefined ? [] :
        (Array.isArray(object.composite) ? object.composite : [object.composite]);
      for (let index = 0; index < frames.length && composites.length > 0; index++)
        frames[index].composite = compositeOf(composites[index % composites.length]);
    }
    let previous = -Infinity;
    for (const frame of frames) {
      if (frame.offset === null) continue;
      if (frame.offset < 0 || frame.offset > 1) throw new TypeError("keyframe offsets must be in [0, 1]");
      if (frame.offset < previous) throw new TypeError("keyframe offsets must be in order");
      previous = frame.offset;
    }
    computeOffsets(frames);
    return frames;
  }

  // Computed keyframe offsets: the first and last default to 0 and 1, the
  // ones between spread evenly between their neighbours.
  function computeOffsets(frames) {
    if (frames.length === 0) return;
    for (const frame of frames) frame.computed = frame.offset;
    if (frames.length === 1 && frames[0].computed === null) {
      frames[0].computed = 1;
      return;
    }
    if (frames[0].computed === null) frames[0].computed = 0;
    if (frames[frames.length - 1].computed === null) frames[frames.length - 1].computed = 1;
    let start = 0;
    for (let index = 1; index < frames.length; index++) {
      if (frames[index].computed === null) continue;
      const span = index - start;
      for (let between = start + 1; between < index; between++)
        frames[between].computed = frames[start].computed +
          (frames[index].computed - frames[start].computed) * (between - start) / span;
      start = index;
    }
  }

  // ---- effects ----

  let nextEffectHandle = 0;
  const effectData = new WeakMap();
  const timingMembers = ["delay", "endDelay", "fill", "iterationStart", "iterations", "duration", "direction",
    "easing"];

  function defaultTiming() {
    return { delay: 0, endDelay: 0, fill: "auto", iterationStart: 0, iterations: 1, duration: "auto",
      direction: "normal", easing: "linear" };
  }

  // Validates and applies an OptionalEffectTiming dictionary.
  function applyTiming(timing, input) {
    if (input === undefined || input === null) return;
    if (typeof input === "number") {
      if (isNaN(input) || input < 0) throw new TypeError("duration must be a non-negative number");
      timing.duration = input;
      return;
    }
    if (typeof input !== "object") throw new TypeError("timing must be a number or a dictionary");
    const next = Object.assign({}, timing);
    if (input.delay !== undefined) {
      next.delay = Number(input.delay);
      if (!isFinite(next.delay)) throw new TypeError("delay must be finite");
    }
    if (input.endDelay !== undefined) {
      next.endDelay = Number(input.endDelay);
      if (!isFinite(next.endDelay)) throw new TypeError("endDelay must be finite");
    }
    if (input.fill !== undefined) {
      const fill = String(input.fill);
      if (["none", "forwards", "backwards", "both", "auto"].indexOf(fill) < 0)
        throw new TypeError("'" + fill + "' is not a fill mode");
      next.fill = fill;
    }
    if (input.iterationStart !== undefined) {
      next.iterationStart = Number(input.iterationStart);
      if (!(next.iterationStart >= 0) || !isFinite(next.iterationStart))
        throw new TypeError("iterationStart must be a finite non-negative number");
    }
    if (input.iterations !== undefined) {
      next.iterations = Number(input.iterations);
      if (isNaN(next.iterations) || next.iterations < 0) throw new TypeError("iterations must be non-negative");
    }
    if (input.duration !== undefined) {
      if (typeof input.duration === "string") {
        if (input.duration !== "auto") throw new TypeError("duration must be a number or 'auto'");
        next.duration = "auto";
      } else {
        next.duration = Number(input.duration);
        if (isNaN(next.duration) || next.duration < 0) throw new TypeError("duration must be non-negative");
      }
    }
    if (input.direction !== undefined) {
      const direction = String(input.direction);
      if (["normal", "reverse", "alternate", "alternate-reverse"].indexOf(direction) < 0)
        throw new TypeError("'" + direction + "' is not a playback direction");
      next.direction = direction;
    }
    if (input.easing !== undefined) next.easing = checkEasing(input.easing);
    Object.assign(timing, next);
  }

  function iterationDuration(timing) {
    return timing.duration === "auto" ? 0 : timing.duration;
  }
  function activeDuration(timing) {
    const duration = iterationDuration(timing);
    if (duration === 0 || timing.iterations === 0) return 0;
    return duration * timing.iterations;
  }
  function endTime(timing) {
    return Math.max(timing.delay + activeDuration(timing) + timing.endDelay, 0);
  }

  // The timing model (Web Animations 4.6-4.10) at a local time.
  function computedTiming(timing, localTime, playbackRate) {
    const active = activeDuration(timing);
    const end = endTime(timing);
    const result = { endTime: end, activeDuration: active, localTime: localTime, progress: null,
      currentIteration: null, inEffect: false };
    if (localTime === null) return result;
    const backwards = playbackRate < 0;
    const beforeBoundary = Math.max(Math.min(timing.delay, end), 0);
    const activeAfter = Math.max(Math.min(timing.delay + active, end), 0);
    let phase;
    if (localTime < beforeBoundary || (backwards && localTime === beforeBoundary)) phase = "before";
    else if (localTime > activeAfter || (!backwards && localTime === activeAfter)) phase = "after";
    else phase = "active";
    const fill = timing.fill === "auto" ? "none" : timing.fill;
    let activeTime = null;
    if (phase === "before") {
      if (fill === "backwards" || fill === "both") activeTime = Math.max(localTime - timing.delay, 0);
    } else if (phase === "active") {
      activeTime = localTime - timing.delay;
    } else if (fill === "forwards" || fill === "both") {
      activeTime = Math.max(Math.min(localTime - timing.delay, active), 0);
    }
    if (activeTime === null) return result;
    const duration = iterationDuration(timing);
    let overall = duration === 0 ? (phase === "before" ? 0 : timing.iterations) : activeTime / duration;
    overall += timing.iterationStart;
    let simple = isFinite(overall) ? overall % 1 : timing.iterationStart % 1;
    if (simple === 0 && (phase === "active" || phase === "after") && active === activeTime &&
        timing.iterations !== 0 && overall !== 0)
      simple = 1;
    let iteration;
    if (phase === "after" && !isFinite(timing.iterations)) iteration = Infinity;
    else if (simple === 1) iteration = Math.floor(overall) - 1;
    else iteration = Math.floor(overall);
    let forwards = true;
    if (timing.direction === "reverse") forwards = false;
    else if (timing.direction === "alternate") forwards = iteration % 2 === 0 || !isFinite(iteration);
    else if (timing.direction === "alternate-reverse") forwards = iteration % 2 !== 0 && isFinite(iteration);
    let directed = forwards ? simple : 1 - simple;
    const transformed = timing.easing === "linear" ? directed : natives.easeProgress(timing.easing, directed);
    result.progress = transformed;
    result.currentIteration = iteration;
    result.inEffect = true;
    return result;
  }

  class AnimationEffect {
    constructor(key) {
      if (key !== token) internal.illegal();
    }
    getTiming() {
      const timing = effectData.get(this).timing;
      const copy = {};
      for (const member of timingMembers) copy[member] = timing[member];
      return copy;
    }
    getComputedTiming() {
      const state = effectData.get(this);
      const timing = state.timing;
      const result = computedTiming(timing, localTimeOf(this), state.animation ? rateOf(state.animation) : 1);
      const copy = this.getTiming();
      copy.fill = timing.fill === "auto" ? "none" : timing.fill;
      copy.duration = iterationDuration(timing);
      copy.endTime = result.endTime;
      copy.activeDuration = result.activeDuration;
      copy.localTime = result.localTime;
      copy.progress = result.progress;
      copy.currentIteration = result.currentIteration;
      return copy;
    }
    updateTiming(timing) {
      const state = effectData.get(this);
      applyTiming(state.timing, timing === undefined ? {} : timing);
      if (state.animation) updateAnimation(state.animation, false);
      else pushProgress(this);
    }
  }
  internal.finishInterface(AnimationEffect, "AnimationEffect");

  function pushKeyframes(effect) {
    const state = effectData.get(effect);
    if (state.target === null) return;
    const offsets = [], easings = [], declarations = [];
    for (const frame of state.frames) {
      offsets.push(frame.computed);
      easings.push(frame.easing);
      let text = "";
      for (const property of Object.keys(frame.values))
        text += cssName(property) + ": " + frame.values[property] + "; ";
      declarations.push(text);
    }
    natives.animationKeyframes(state.target, state.handle, offsets, easings, declarations);
  }

  function pushProgress(effect) {
    const state = effectData.get(effect);
    if (state.target === null) return;
    const timing = computedTiming(state.timing, localTimeOf(effect), state.animation ? rateOf(state.animation) : 1);
    natives.animationProgress(state.target, state.handle, timing.inEffect, timing.inEffect ? timing.progress : 0);
  }

  function detachTarget(effect) {
    const state = effectData.get(effect);
    if (state.target !== null) natives.animationRemove(state.target, state.handle);
  }

  class KeyframeEffect extends AnimationEffect {
    constructor(target, keyframes, options) {
      super(token);
      const state = { handle: ++nextEffectHandle, target: null, pseudoElement: null, frames: [],
        composite: "replace", timing: defaultTiming(), animation: null };
      effectData.set(this, state);
      if (target instanceof KeyframeEffect && keyframes === undefined) {
        // new KeyframeEffect(source): a copy.
        const source = effectData.get(target);
        state.target = source.target;
        state.frames = source.frames.map(function (frame) { return Object.assign({}, frame,
          { values: Object.assign({}, frame.values) }); });
        state.composite = source.composite;
        Object.assign(state.timing, source.timing);
      } else {
        if (target !== null && !(target instanceof Element)) throw new TypeError("the target must be an Element");
        state.target = target;
        state.frames = processKeyframes(keyframes);
        applyTiming(state.timing, options);
        if (options !== null && typeof options === "object") {
          if (options.composite !== undefined) {
            const composite = String(options.composite);
            if (["replace", "add", "accumulate"].indexOf(composite) < 0)
              throw new TypeError("'" + composite + "' is not a composite operation");
            state.composite = composite;
          }
          if (options.pseudoElement !== undefined && options.pseudoElement !== null)
            state.pseudoElement = String(options.pseudoElement);
        }
      }
      pushKeyframes(this);
    }
    get target() { return effectData.get(this).target; }
    set target(value) {
      if (value !== null && !(value instanceof Element)) throw new TypeError("the target must be an Element");
      detachTarget(this);
      effectData.get(this).target = value;
      pushKeyframes(this);
      pushProgress(this);
    }
    get pseudoElement() { return effectData.get(this).pseudoElement; }
    get composite() { return effectData.get(this).composite; }
    set composite(value) {
      const composite = String(value);
      if (["replace", "add", "accumulate"].indexOf(composite) < 0) return;
      effectData.get(this).composite = composite;
    }
    getKeyframes() {
      return effectData.get(this).frames.map(function (frame) {
        const result = { offset: frame.offset, computedOffset: frame.computed, easing: frame.easing,
          composite: frame.composite };
        for (const property of Object.keys(frame.values)) result[property] = frame.values[property];
        return result;
      });
    }
    setKeyframes(keyframes) {
      effectData.get(this).frames = processKeyframes(keyframes);
      pushKeyframes(this);
      pushProgress(this);
    }
  }
  internal.finishInterface(KeyframeEffect, "KeyframeEffect");

  // ---- animations ----

  const animationData = new WeakMap();
  const liveAnimations = new Set();
  let frameRequested = false;

  function rateOf(animation) { return animationData.get(animation).playbackRate; }

  function localTimeOf(effect) {
    const state = effectData.get(effect);
    return state.animation ? currentTimeOf(state.animation) : null;
  }

  function timelineTime(animation) {
    const timeline = animationData.get(animation).timeline;
    return timeline === null ? null : timeline.currentTime;
  }

  function currentTimeOf(animation) {
    const state = animationData.get(animation);
    if (state.holdTime !== null) return state.holdTime;
    const now = timelineTime(animation);
    if (now === null || state.startTime === null) return null;
    return (now - state.startTime) * state.playbackRate;
  }

  function effectEnd(animation) {
    const effect = animationData.get(animation).effect;
    return effect === null ? 0 : endTime(effectData.get(effect).timing);
  }

  function playStateOf(animation) {
    const state = animationData.get(animation);
    const current = currentTimeOf(animation);
    if (current === null && state.startTime === null && state.pendingTask === null) return "idle";
    if (state.pendingTask === "pause" || (state.startTime === null && state.pendingTask !== "play")) return "paused";
    if (current !== null && ((state.playbackRate > 0 && current >= effectEnd(animation)) ||
        (state.playbackRate < 0 && current <= 0)))
      return "finished";
    return "running";
  }

  function newPromise() {
    let resolve, reject;
    const promise = new Promise(function (yes, no) { resolve = yes; reject = no; });
    promise.catch(function () {});
    return { promise: promise, resolve: resolve, reject: reject, settled: false };
  }

  function wantFrames() {
    if (frameRequested) return;
    frameRequested = true;
    requestFrame.call(global, tick);
  }

  function setCurrentTimeSilently(animation, seekTime) {
    const state = animationData.get(animation);
    const now = timelineTime(animation);
    if (state.holdTime !== null || state.startTime === null || now === null || state.playbackRate === 0)
      state.holdTime = seekTime;
    else
      state.startTime = now - seekTime / state.playbackRate;
    if (now === null) state.startTime = null;
    state.previousCurrentTime = null;
  }

  function fireEvent(animation, type) {
    const event = new AnimationPlaybackEvent(type, { currentTime: currentTimeOf(animation),
      timelineTime: timelineTime(animation) });
    try {
      internal.fire(animation, event);
    } catch (error) {
      natives.reportError(error);
    }
  }

  // "Update an animation's finished state".
  function updateFinishedState(animation, didSeek, synchronouslyNotify) {
    const state = animationData.get(animation);
    const unconstrained = currentTimeOf(animation);
    if (unconstrained !== null && state.startTime !== null && state.pendingTask === null) {
      const end = effectEnd(animation);
      if (state.playbackRate > 0 && unconstrained >= end) {
        if (didSeek) state.holdTime = unconstrained;
        else state.holdTime = state.previousCurrentTime === null ? end : Math.max(state.previousCurrentTime, end);
      } else if (state.playbackRate < 0 && unconstrained <= 0) {
        if (didSeek) state.holdTime = unconstrained;
        else state.holdTime = state.previousCurrentTime === null ? 0 : Math.min(state.previousCurrentTime, 0);
      } else if (state.playbackRate !== 0 && timelineTime(animation) !== null) {
        if (didSeek && state.holdTime !== null)
          state.startTime = timelineTime(animation) - state.holdTime / state.playbackRate;
        state.holdTime = null;
      }
    }
    state.previousCurrentTime = currentTimeOf(animation);
    const finished = playStateOf(animation) === "finished";
    if (finished && !state.finished.settled) {
      state.finished.settled = true;
      state.finished.resolve(animation);
      fireEvent(animation, "finish");
    } else if (!finished && state.finished.settled) {
      state.finished = newPromise();
    }
  }

  function updateAnimation(animation, didSeek) {
    updateFinishedState(animation, didSeek, false);
    const state = animationData.get(animation);
    if (state.effect !== null) pushProgress(state.effect);
    if (playStateOf(animation) === "running" || state.pendingTask !== null) wantFrames();
  }

  // A frame: pending tasks finish with the frame's time, then every live
  // animation's effect is brought up to date.
  function tick() {
    frameRequested = false;
    for (const animation of Array.from(liveAnimations)) {
      const state = animationData.get(animation);
      if (state.pendingTask !== null) runPendingTask(animation);
      updateAnimation(animation, false);
      if (playStateOf(animation) === "idle") liveAnimations.delete(animation);
    }
  }

  function runPendingTask(animation) {
    const state = animationData.get(animation);
    const readyTime = timelineTime(animation);
    if (state.pendingTask === "play") {
      if (state.pendingPlaybackRate !== null) {
        state.playbackRate = state.pendingPlaybackRate;
        state.pendingPlaybackRate = null;
      }
      if (state.holdTime !== null) {
        if (state.playbackRate === 0) state.startTime = readyTime;
        else state.startTime = readyTime - state.holdTime / state.playbackRate;
        state.holdTime = null;
      }
    } else if (state.pendingTask === "pause") {
      if (state.startTime !== null && state.holdTime === null)
        state.holdTime = (readyTime - state.startTime) * state.playbackRate;
      if (state.pendingPlaybackRate !== null) {
        state.playbackRate = state.pendingPlaybackRate;
        state.pendingPlaybackRate = null;
      }
      state.startTime = null;
    }
    state.pendingTask = null;
    if (!state.ready.settled) {
      state.ready.settled = true;
      state.ready.resolve(animation);
    }
  }

  // "Play an animation" with the auto-rewind flag.
  function playAnimation(animation, autoRewind) {
    const state = animationData.get(animation);
    const rate = state.pendingPlaybackRate !== null ? state.pendingPlaybackRate : state.playbackRate;
    const current = currentTimeOf(animation);
    const end = effectEnd(animation);
    let seekTime = null;
    let hasPendingReadyPromise = false;
    if (state.pendingTask !== null) hasPendingReadyPromise = true;
    if (rate > 0 && autoRewind && (current === null || current < 0 || current >= end)) seekTime = 0;
    else if (rate < 0 && autoRewind && (current === null || current <= 0 || current > end)) {
      if (end === Infinity) throw new DOMException("cannot play an infinite animation backwards",
        "InvalidStateError");
      seekTime = end;
    } else if (rate === 0 && current === null) seekTime = 0;
    if (seekTime !== null) {
      state.startTime = null;
      state.holdTime = seekTime;
    }
    if (state.holdTime !== null) state.startTime = null;
    if (state.pendingTask === "pause") state.pendingTask = null;
    if (state.holdTime === null && seekTime === null && state.pendingTask === null &&
        state.pendingPlaybackRate === null)
      return;
    if (!hasPendingReadyPromise || state.ready.settled) state.ready = newPromise();
    state.pendingTask = "play";
    liveAnimations.add(animation);
    updateFinishedState(animation, false, false);
    if (state.effect !== null) pushProgress(state.effect);
    wantFrames();
  }

  class Animation extends EventTarget {
    constructor(effect, timeline) {
      super();
      if (effect !== undefined && effect !== null && !(effect instanceof AnimationEffect))
        throw new TypeError("the effect must be an AnimationEffect");
      const state = { effect: null, timeline: timeline === undefined ? defaultTimeline() : timeline,
        startTime: null, holdTime: null, playbackRate: 1, pendingPlaybackRate: null, pendingTask: null,
        previousCurrentTime: null, id: "", replaceState: "active", ready: newPromise(), finished: newPromise(),
        order: ++animationOrder };
      state.ready.settled = true;
      state.ready.resolve(this);
      animationData.set(this, state);
      if (effect !== undefined && effect !== null) this.effect = effect;
    }
    get id() { return animationData.get(this).id; }
    set id(value) { animationData.get(this).id = String(value); }
    get effect() { return animationData.get(this).effect; }
    set effect(value) {
      const state = animationData.get(this);
      if (value === state.effect) return;
      if (value !== null && !(value instanceof AnimationEffect)) throw new TypeError("the effect must be an AnimationEffect");
      if (state.effect !== null) {
        effectData.get(state.effect).animation = null;
        detachTarget(state.effect);
      }
      if (value !== null) {
        const valueState = effectData.get(value);
        if (valueState.animation !== null) valueState.animation.effect = null;
        valueState.animation = this;
        pushKeyframes(value);
      }
      state.effect = value;
      updateAnimation(this, false);
    }
    get timeline() { return animationData.get(this).timeline; }
    set timeline(value) {
      const state = animationData.get(this);
      const previous = currentTimeOf(this);
      state.timeline = value;
      if (previous !== null) setCurrentTimeSilently(this, previous);
      updateAnimation(this, false);
    }
    get startTime() { return animationData.get(this).startTime; }
    set startTime(value) {
      const state = animationData.get(this);
      const now = timelineTime(this);
      const time = value === null ? null : Number(value);
      if (now === null && time !== null) state.holdTime = null;
      const previous = currentTimeOf(this);
      if (state.pendingPlaybackRate !== null) {
        state.playbackRate = state.pendingPlaybackRate;
        state.pendingPlaybackRate = null;
      }
      state.startTime = time;
      if (time !== null) {
        if (state.playbackRate !== 0) state.holdTime = null;
      } else {
        state.holdTime = previous;
      }
      if (state.pendingTask !== null) {
        state.pendingTask = null;
        if (!state.ready.settled) {
          state.ready.settled = true;
          state.ready.resolve(this);
        }
      }
      liveAnimations.add(this);
      updateAnimation(this, true);
    }
    get currentTime() { return currentTimeOf(this); }
    set currentTime(value) {
      if (value === null) {
        if (currentTimeOf(this) !== null) throw new TypeError("the current time cannot be set to null");
        return;
      }
      const state = animationData.get(this);
      setCurrentTimeSilently(this, Number(value));
      if (state.pendingTask === "pause") {
        state.holdTime = Number(value);
        if (state.pendingPlaybackRate !== null) {
          state.playbackRate = state.pendingPlaybackRate;
          state.pendingPlaybackRate = null;
        }
        state.startTime = null;
        state.pendingTask = null;
        if (!state.ready.settled) {
          state.ready.settled = true;
          state.ready.resolve(this);
        }
      }
      liveAnimations.add(this);
      updateAnimation(this, true);
    }
    get playbackRate() { return animationData.get(this).playbackRate; }
    set playbackRate(value) {
      const state = animationData.get(this);
      const previous = currentTimeOf(this);
      state.pendingPlaybackRate = null;
      state.playbackRate = Number(value);
      if (previous !== null) setCurrentTimeSilently(this, previous);
      updateAnimation(this, true);
    }
    get playState() { return playStateOf(this); }
    get replaceState() { return animationData.get(this).replaceState; }
    get pending() { return animationData.get(this).pendingTask !== null; }
    get ready() { return animationData.get(this).ready.promise; }
    get finished() { return animationData.get(this).finished.promise; }
    play() { playAnimation(this, true); }
    pause() {
      const state = animationData.get(this);
      if (state.pendingTask === "pause") return;
      if (playStateOf(this) === "paused") return;
      const current = currentTimeOf(this);
      let seekTime = null;
      if (current === null) {
        if (state.playbackRate >= 0) seekTime = 0;
        else {
          if (effectEnd(this) === Infinity)
            throw new DOMException("cannot pause an infinite animation running backwards", "InvalidStateError");
          seekTime = effectEnd(this);
        }
      }
      if (seekTime !== null) state.holdTime = seekTime;
      const hasPendingReadyPromise = state.pendingTask !== null;
      if (state.pendingTask === "play") state.pendingTask = null;
      else if (!hasPendingReadyPromise || state.ready.settled) state.ready = newPromise();
      if (state.ready.settled) state.ready = newPromise();
      state.pendingTask = "pause";
      liveAnimations.add(this);
      updateAnimation(this, false);
    }
    finish() {
      const state = animationData.get(this);
      const rate = state.pendingPlaybackRate !== null ? state.pendingPlaybackRate : state.playbackRate;
      const end = effectEnd(this);
      if (rate === 0 || (rate > 0 && end === Infinity))
        throw new DOMException("the animation cannot be finished", "InvalidStateError");
      if (state.pendingPlaybackRate !== null) {
        state.playbackRate = state.pendingPlaybackRate;
        state.pendingPlaybackRate = null;
      }
      setCurrentTimeSilently(this, rate > 0 ? end : 0);
      const now = timelineTime(this);
      if (state.startTime === null && now !== null)
        state.startTime = now - (rate > 0 ? end : 0) / state.playbackRate;
      if (state.pendingTask === "pause" && state.startTime !== null) {
        state.holdTime = null;
        state.pendingTask = null;
        state.ready.settled = true;
        state.ready.resolve(this);
      }
      if (state.pendingTask === "play" && state.startTime !== null) {
        state.pendingTask = null;
        state.ready.settled = true;
        state.ready.resolve(this);
      }
      updateFinishedState(this, true, true);
      if (state.effect !== null) pushProgress(state.effect);
    }
    cancel() {
      const state = animationData.get(this);
      if (playStateOf(this) !== "idle") {
        if (state.pendingTask !== null) {
          state.pendingTask = null;
          if (!state.ready.settled) {
            state.ready.settled = true;
            state.ready.reject(new DOMException("the animation was cancelled", "AbortError"));
          }
          state.ready = newPromise();
          state.ready.settled = true;
          state.ready.resolve(this);
        }
        if (!state.finished.settled) {
          state.finished.settled = true;
          state.finished.reject(new DOMException("the animation was cancelled", "AbortError"));
        }
        state.finished = newPromise();
        fireEvent(this, "cancel");
      }
      state.startTime = null;
      state.holdTime = null;
      liveAnimations.delete(this);
      if (state.effect !== null) pushProgress(state.effect);
    }
    reverse() {
      const state = animationData.get(this);
      if (timelineTime(this) === null)
        throw new DOMException("the animation has no active timeline", "InvalidStateError");
      const original = state.pendingPlaybackRate;
      state.pendingPlaybackRate = -(original !== null ? original : state.playbackRate);
      try {
        playAnimation(this, true);
      } catch (error) {
        state.pendingPlaybackRate = original;
        throw error;
      }
    }
    updatePlaybackRate(rate) {
      const state = animationData.get(this);
      state.pendingPlaybackRate = Number(rate);
      const playState = playStateOf(this);
      if (state.pendingTask !== null) return;
      if (playState === "idle" || playState === "paused") {
        state.playbackRate = state.pendingPlaybackRate;
        state.pendingPlaybackRate = null;
      } else if (playState === "finished") {
        const now = timelineTime(this);
        const unconstrained = now !== null && state.startTime !== null ?
          (now - state.startTime) * state.playbackRate : null;
        if (state.pendingPlaybackRate === 0) state.startTime = now;
        else if (unconstrained !== null && now !== null) state.startTime = now - unconstrained / state.pendingPlaybackRate;
        state.playbackRate = state.pendingPlaybackRate;
        state.pendingPlaybackRate = null;
        updateAnimation(this, false);
      } else {
        playAnimation(this, false);
      }
    }
    persist() { animationData.get(this).replaceState = "persisted"; }
    // Writes the animated values into the target's style attribute.
    commitStyles() {
      const state = animationData.get(this);
      if (state.effect === null) return;
      const effect = effectData.get(state.effect);
      if (effect.target === null) return;
      if (!effect.target.isConnected)
        throw new DOMException("the target is not rendered", "InvalidStateError");
      const computed = global.getComputedStyle(effect.target);
      const names = new Set();
      for (const frame of effect.frames) for (const property of Object.keys(frame.values)) names.add(property);
      for (const property of names) {
        const name = cssName(property);
        effect.target.style.setProperty(name, computed.getPropertyValue(name));
      }
    }
  }
  internal.defineHandler(Animation.prototype, "finish");
  internal.defineHandler(Animation.prototype, "cancel");
  internal.defineHandler(Animation.prototype, "remove");
  internal.finishInterface(Animation, "Animation");
  let animationOrder = 0;

  const playbackEventData = new WeakMap();
  class AnimationPlaybackEvent extends Event {
    constructor(type, eventInitDict) {
      super(type, eventInitDict);
      const init = eventInitDict == null ? {} : eventInitDict;
      playbackEventData.set(this, {
        currentTime: init.currentTime === undefined || init.currentTime === null ? null : Number(init.currentTime),
        timelineTime: init.timelineTime === undefined || init.timelineTime === null ? null : Number(init.timelineTime) });
    }
    get currentTime() { return playbackEventData.get(this).currentTime; }
    get timelineTime() { return playbackEventData.get(this).timelineTime; }
  }
  internal.finishInterface(AnimationPlaybackEvent, "AnimationPlaybackEvent");

  // ---- CSS animations and transitions as Animation objects ----

  const cssObjects = new WeakMap();
  function cssKey(info) { return (info.transition ? "t:" : "a:") + info.name; }

  // The animations the layout runs for an element, as the same objects
  // each time while they run.
  function cssAnimationsOf(element) {
    const infos = natives.cssAnimations(element);
    let map = cssObjects.get(element);
    if (map === undefined) {
      map = new Map();
      cssObjects.set(element, map);
    }
    const result = [];
    const seen = new Set();
    for (const info of infos) {
      const key = cssKey(info);
      seen.add(key);
      let object = map.get(key);
      if (object === undefined) {
        object = info.transition ? new CSSTransition(token, element, info) : new CSSAnimation(token, element, info);
        map.set(key, object);
      } else {
        cssData.get(object).info = info;
      }
      if (info.transition || !info.ended || info.fill === "forwards" || info.fill === "both") result.push(object);
    }
    for (const key of Array.from(map.keys())) if (!seen.has(key)) map.delete(key);
    return result;
  }

  const cssData = new WeakMap();
  function cssTiming(info) {
    return { delay: info.delay, endDelay: 0, fill: info.fill, iterationStart: 0, iterations: info.iterations,
      duration: info.duration, direction: info.direction, easing: "linear" };
  }

  class CSSEffect extends KeyframeEffect {
    constructor(element, owner) {
      super(element, null);
      effectData.get(this).cssOwner = owner;
    }
    getTiming() { return cssTiming(cssData.get(effectData.get(this).cssOwner).info); }
    getComputedTiming() {
      const info = cssData.get(effectData.get(this).cssOwner).info;
      const timing = cssTiming(info);
      const result = computedTiming(timing, info.localTime, 1);
      timing.endTime = result.endTime;
      timing.activeDuration = result.activeDuration;
      timing.localTime = result.localTime;
      timing.progress = result.progress;
      timing.currentIteration = result.currentIteration;
      return timing;
    }
  }

  function cssControl(object, action, value) {
    const state = cssData.get(object);
    natives.cssAnimationControl(state.element, state.info.transition, state.info.name, action, value || 0);
  }

  class CSSAnimation extends Animation {
    constructor(key, element, info) {
      if (key !== token) internal.illegal();
      super(null);
      cssData.set(this, { element: element, info: info });
      animationData.get(this).cssEffect = new CSSEffect(element, this);
    }
    get animationName() { return cssData.get(this).info.name; }
    get effect() { return animationData.get(this).cssEffect; }
    get currentTime() { return cssData.get(this).info.localTime; }
    set currentTime(value) { cssControl(this, "seek", Number(value)); cssData.get(this).info.localTime = Number(value); }
    get startTime() {
      const now = defaultTimeline().currentTime;
      return cssData.get(this).info.paused ? null : now - cssData.get(this).info.localTime;
    }
    get playState() {
      const info = cssData.get(this).info;
      if (info.paused) return "paused";
      if (info.ended) return "finished";
      return "running";
    }
    get pending() { return false; }
    play() { cssControl(this, "play"); cssData.get(this).info.paused = false; }
    pause() { cssControl(this, "pause"); cssData.get(this).info.paused = true; }
    cancel() { cssControl(this, "cancel"); }
    finish() {
      const info = cssData.get(this).info;
      cssControl(this, "seek", info.delay + info.duration * info.iterations);
    }
  }
  internal.finishInterface(CSSAnimation, "CSSAnimation");

  class CSSTransition extends Animation {
    constructor(key, element, info) {
      if (key !== token) internal.illegal();
      super(null);
      cssData.set(this, { element: element, info: info });
      animationData.get(this).cssEffect = new CSSEffect(element, this);
    }
    get transitionProperty() { return cssData.get(this).info.name; }
    get effect() { return animationData.get(this).cssEffect; }
    get currentTime() { return cssData.get(this).info.localTime; }
    set currentTime(value) { cssControl(this, "seek", Number(value)); }
    get startTime() { return defaultTimeline().currentTime - cssData.get(this).info.localTime; }
    get playState() { return "running"; }
    get pending() { return false; }
    cancel() { cssControl(this, "cancel"); }
  }
  internal.finishInterface(CSSTransition, "CSSTransition");

  // ---- Element.animate and getAnimations ----

  function isRelevant(animation) {
    const state = animationData.get(animation);
    if (state.effect === null) return false;
    const playState = playStateOf(animation);
    if (playState === "idle") return false;
    if (playState !== "finished") return true;
    const timing = computedTiming(effectData.get(state.effect).timing, currentTimeOf(animation), state.playbackRate);
    return timing.inEffect;
  }

  function scriptAnimationsFor(test) {
    const result = [];
    for (const animation of liveAnimations) {
      const state = animationData.get(animation);
      if (state.effect === null || state.cssEffect !== undefined) continue;
      const target = effectData.get(state.effect).target;
      if (target !== null && test(target) && isRelevant(animation)) result.push(animation);
    }
    result.sort(function (a, b) { return animationData.get(a).order - animationData.get(b).order; });
    return result;
  }

  function animationsUnder(root, subtree, includeRoot) {
    const css = [];
    const visit = function (element) {
      for (const animation of cssAnimationsOf(element)) css.push(animation);
    };
    if (includeRoot) visit(root);
    if (subtree) for (const element of root.querySelectorAll("*")) visit(element);
    const transitions = css.filter(function (animation) { return animation instanceof CSSTransition; });
    const others = css.filter(function (animation) { return animation instanceof CSSAnimation; });
    const scripted = scriptAnimationsFor(function (target) {
      return target === root || (subtree && root.contains(target));
    });
    return transitions.concat(others, scripted);
  }

  internal.define(global.Element.prototype, "animate", function animate(keyframes, options) {
    const effect = new KeyframeEffect(this, keyframes, options);
    const animation = new Animation(effect, defaultTimeline());
    if (options !== null && typeof options === "object" && options.id !== undefined) animation.id = String(options.id);
    animation.play();
    return animation;
  });
  internal.define(global.Element.prototype, "getAnimations", function getAnimations(options) {
    const subtree = options != null && !!options.subtree;
    return animationsUnder(this, subtree, true);
  });
  internal.define(global.Document.prototype, "getAnimations", function getAnimations() {
    if (this.documentElement === null) return scriptAnimationsFor(function () { return false; });
    return animationsUnder(this.documentElement, true, true).filter(function (animation) {
      const state = animationData.get(animation);
      if (state.cssEffect !== undefined) return true;
      return effectData.get(state.effect).target.isConnected;
    });
  });
  internal.define(global.ShadowRoot.prototype, "getAnimations", function getAnimations() {
    const root = this;
    return scriptAnimationsFor(function (target) { return root.contains(target); });
  });
})
