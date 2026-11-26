// HTML Standard 4.8.11: the media element API of audio and video, for
// an engine that plays no media yet. Every resource fails the way an
// unsupported one does in other browsers: load() with a source moves to
// NETWORK_NO_SOURCE and fires error with a MediaError of
// MEDIA_ERR_SRC_NOT_SUPPORTED, canPlayType() is "", and play() rejects
// with NotSupportedError. The attributes keep what pages set (volume,
// muted, playback rates) so feature tests and players' setup run.
(function (natives, global, internal) {
  "use strict";
  const MediaElement = global.HTMLMediaElement;
  if (typeof MediaElement !== "function") return;
  const prototype = MediaElement.prototype;
  const mediaData = new WeakMap();

  const NETWORK_EMPTY = 0, NETWORK_IDLE = 1, NETWORK_LOADING = 2, NETWORK_NO_SOURCE = 3;
  const MEDIA_ERR_SRC_NOT_SUPPORTED = 4;

  class MediaError {
    constructor(token, code, message) {
      if (token !== internal.token) internal.illegal();
      mediaData.set(this, { code: code, message: message });
    }
    get code() { return errorState(this).code; }
    get message() { return errorState(this).message; }
  }
  function errorState(object) {
    const state = mediaData.get(object);
    if (state === undefined || !(object instanceof MediaError)) throw new TypeError("Illegal invocation");
    return state;
  }
  const errorCodes = { MEDIA_ERR_ABORTED: 1, MEDIA_ERR_NETWORK: 2, MEDIA_ERR_DECODE: 3, MEDIA_ERR_SRC_NOT_SUPPORTED: 4 };
  for (const name in errorCodes) {
    Object.defineProperty(MediaError, name, { value: errorCodes[name], enumerable: true });
    Object.defineProperty(MediaError.prototype, name, { value: errorCodes[name], enumerable: true });
  }
  internal.finishInterface(MediaError, "MediaError");

  // TimeRanges: always empty (nothing is buffered, played or seekable).
  class TimeRanges {
    constructor(token) {
      if (token !== internal.token) internal.illegal();
    }
    get length() { return 0; }
    start(index) {
      throw internal.domException("Failed to execute 'start' on 'TimeRanges': The index provided (" + index +
        ") is greater than or equal to the maximum bound (0).", "IndexSizeError");
    }
    end(index) {
      throw internal.domException("Failed to execute 'end' on 'TimeRanges': The index provided (" + index +
        ") is greater than or equal to the maximum bound (0).", "IndexSizeError");
    }
  }
  internal.finishInterface(TimeRanges, "TimeRanges");

  function state(element) {
    if (!(element instanceof MediaElement)) throw new TypeError("Illegal invocation");
    let data = mediaData.get(element);
    if (data === undefined) {
      data = { networkState: NETWORK_EMPTY, error: null, currentSrc: "", volume: 1, muted: null,
        playbackRate: 1, defaultPlaybackRate: 1, preservesPitch: true, pendingPlays: [], loadGeneration: 0 };
      mediaData.set(element, data);
    }
    return data;
  }

  function fireSimple(element, type) {
    internal.fire(element, new Event(type));
  }

  function notSupported() {
    return internal.domException("The element has no supported sources.", "NotSupportedError");
  }

  function rejectPendingPlays(data, error) {
    const pending = data.pendingPlays;
    data.pendingPlays = [];
    for (const reject of pending) reject(error);
  }

  // The source the resource selection algorithm would try: the src
  // attribute, else the first source child with one.
  function candidateSource(element) {
    if (element.hasAttribute("src")) return element.src;
    for (let child = element.firstElementChild; child !== null; child = child.nextElementSibling)
      if (child.localName === "source" && child.hasAttribute("src")) return child.src;
    return null;
  }

  function selectResource(element, data) {
    const source = candidateSource(element);
    if (source === null) {
      data.networkState = NETWORK_EMPTY;
      return;
    }
    data.networkState = NETWORK_LOADING;
    const generation = ++data.loadGeneration;
    internal.queueTask(function () {
      if (data.loadGeneration !== generation) return;
      data.currentSrc = source;
      data.error = new MediaError(internal.token, MEDIA_ERR_SRC_NOT_SUPPORTED,
        "MEDIA_ELEMENT_ERROR: Format error");
      data.networkState = NETWORK_NO_SOURCE;
      rejectPendingPlays(data, notSupported());
      fireSimple(element, "error");
    });
  }

  const members = {
    load() {
      const data = state(this);
      data.loadGeneration++;
      rejectPendingPlays(data, internal.domException("The play() request was interrupted by a new load request.",
        "AbortError"));
      if (data.networkState !== NETWORK_EMPTY) {
        fireSimple(this, "emptied");
      }
      data.error = null;
      data.currentSrc = "";
      selectResource(this, data);
    },
    play() {
      const data = state(this);
      if (data.error !== null && data.error.code === MEDIA_ERR_SRC_NOT_SUPPORTED)
        return Promise.reject(notSupported());
      const element = this;
      return new Promise(function (resolve, reject) {
        data.pendingPlays.push(reject);
        if (data.networkState === NETWORK_EMPTY) selectResource(element, data);
      });
    },
    pause() {
      const data = state(this);
      if (data.networkState === NETWORK_EMPTY) selectResource(this, data);
    },
    canPlayType(type) {
      state(this);
      return "";
    },
    fastSeek(time) {
      state(this);
    },
    addTextTrack(kind, label, language) {
      throw internal.domException("Text tracks are not supported.", "NotSupportedError");
    }
  };
  for (const name in members) internal.define(prototype, name, members[name]);

  function accessor(name, getter, setter) {
    Object.defineProperty(prototype, name, { get: getter, set: setter, enumerable: true, configurable: true });
  }
  accessor("error", function () { return state(this).error; });
  accessor("networkState", function () { return state(this).networkState; });
  accessor("readyState", function () { state(this); return 0; });
  accessor("currentSrc", function () { return state(this).currentSrc; });
  accessor("seeking", function () { state(this); return false; });
  accessor("ended", function () { state(this); return false; });
  accessor("duration", function () { state(this); return NaN; });
  accessor("currentTime", function () { state(this); return 0; }, function (value) {
    state(this);
    if (!Number.isFinite(Number(value)))
      throw new TypeError("Failed to set the 'currentTime' property on 'HTMLMediaElement': The provided double " +
        "value is non-finite.");
  });
  accessor("buffered", function () { state(this); return new TimeRanges(internal.token); });
  accessor("played", function () { state(this); return new TimeRanges(internal.token); });
  accessor("seekable", function () { state(this); return new TimeRanges(internal.token); });
  accessor("volume", function () { return state(this).volume; }, function (value) {
    const data = state(this);
    const volume = Number(value);
    if (!Number.isFinite(volume))
      throw new TypeError("Failed to set the 'volume' property on 'HTMLMediaElement': The provided double value " +
        "is non-finite.");
    if (volume < 0 || volume > 1)
      throw internal.domException("Failed to set the 'volume' property on 'HTMLMediaElement': The volume " +
        "provided (" + volume + ") is outside the range [0, 1].", "IndexSizeError");
    if (data.volume === volume) return;
    data.volume = volume;
    fireSimple(this, "volumechange");
  });
  accessor("muted", function () {
    const data = state(this);
    return data.muted === null ? this.hasAttribute("muted") : data.muted;
  }, function (value) {
    const data = state(this);
    const muted = !!value;
    const old = data.muted === null ? this.hasAttribute("muted") : data.muted;
    data.muted = muted;
    if (old !== muted) fireSimple(this, "volumechange");
  });
  accessor("playbackRate", function () { return state(this).playbackRate; }, function (value) {
    const data = state(this);
    const rate = Number(value);
    if (data.playbackRate === rate) return;
    data.playbackRate = rate;
    fireSimple(this, "ratechange");
  });
  accessor("defaultPlaybackRate", function () { return state(this).defaultPlaybackRate; }, function (value) {
    const data = state(this);
    const rate = Number(value);
    if (data.defaultPlaybackRate === rate) return;
    data.defaultPlaybackRate = rate;
    fireSimple(this, "ratechange");
  });
  accessor("preservesPitch", function () { return state(this).preservesPitch; }, function (value) {
    state(this).preservesPitch = !!value;
  });

  // HTML 4.8.11.2: a video's intrinsic size is 0 x 0 until it has
  // metadata (readyState HAVE_NOTHING), which is always here. Players
  // derive the aspect ratio from these, so they must be numbers.
  const VideoElement = global.HTMLVideoElement;
  if (typeof VideoElement === "function") {
    const videoSize = function () {
      if (!(this instanceof VideoElement)) throw new TypeError("Illegal invocation");
      return 0;
    };
    for (const name of ["videoWidth", "videoHeight"])
      Object.defineProperty(VideoElement.prototype, name, { get: videoSize, enumerable: true, configurable: true });
  }

  const constants = { NETWORK_EMPTY: NETWORK_EMPTY, NETWORK_IDLE: NETWORK_IDLE, NETWORK_LOADING: NETWORK_LOADING,
    NETWORK_NO_SOURCE: NETWORK_NO_SOURCE, HAVE_NOTHING: 0, HAVE_METADATA: 1, HAVE_CURRENT_DATA: 2,
    HAVE_FUTURE_DATA: 3, HAVE_ENOUGH_DATA: 4 };
  for (const name in constants) {
    Object.defineProperty(MediaElement, name, { value: constants[name], enumerable: true });
    Object.defineProperty(prototype, name, { value: constants[name], enumerable: true });
  }
})
