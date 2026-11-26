// The media element API of an engine that plays no media: sources fail
// as unsupported ones do (error event, MediaError 4, NETWORK_NO_SOURCE),
// play() rejects with NotSupportedError, canPlayType is "", and what a
// page sets (volume, muted, rates) is kept.
var audio = new Audio();
check("load, play, pause and canPlayType are methods", typeof audio.load === "function" &&
  typeof audio.play === "function" && typeof audio.pause === "function" && audio.canPlayType("audio/mpeg") === "");
check("an empty element", audio.networkState === HTMLMediaElement.NETWORK_EMPTY && audio.readyState === 0 &&
  audio.error === null && audio.paused && isNaN(audio.duration) && audio.currentTime === 0 &&
  audio.buffered.length === 0 && audio.currentSrc === "");
check("constants on the interface and its prototype", HTMLMediaElement.HAVE_ENOUGH_DATA === 4 &&
  audio.NETWORK_NO_SOURCE === 3 && MediaError.MEDIA_ERR_SRC_NOT_SUPPORTED === 4);
var volumeChanges = 0;
audio.addEventListener("volumechange", function () { volumeChanges++; });
audio.volume = 0.5;
audio.muted = true;
check("volume and muted are kept", audio.volume === 0.5 && audio.muted && volumeChanges === 2);
var outOfRange = null;
try {
  audio.volume = 2;
} catch (error) {
  outOfRange = error;
}
check("a volume outside [0, 1] is an IndexSizeError", outOfRange !== null && outOfRange.name === "IndexSizeError");
audio.playbackRate = 2;
check("playbackRate is kept", audio.playbackRate === 2);
var errors = 0;
audio.addEventListener("error", function () { errors++; });
audio.src = "sound.mp3";
audio.load();
check("loading a source", audio.networkState === HTMLMediaElement.NETWORK_LOADING);
var playError = null;
audio.play().then(function () { playError = "resolved"; }, function (error) { playError = error; });
var defaultMuted = document.createElement("video");
defaultMuted.setAttribute("muted", "");
check("muted follows the muted attribute until set", defaultMuted.muted === true);

function after() {
  check("the source fails as unsupported", errors === 1 && audio.error instanceof MediaError &&
    audio.error.code === MediaError.MEDIA_ERR_SRC_NOT_SUPPORTED &&
    audio.networkState === HTMLMediaElement.NETWORK_NO_SOURCE && /sound\.mp3$/.test(audio.currentSrc));
  check("play() rejects with NotSupportedError", playError !== null && playError.name === "NotSupportedError");
}
