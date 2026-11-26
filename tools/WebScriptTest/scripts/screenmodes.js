// The Fullscreen API and the Pointer Lock API (checks after WPT's
// fullscreen and pointerlock tests) against the test environment, whose
// host grants or refuses as screenModeAnswer() says.
document.body.innerHTML = '<div id="stage"><p id="inner">x</p></div><div id="host"></div>';
var stage = document.getElementById("stage");
var host = document.getElementById("host");
var log = [];

check("the API is there", typeof stage.requestFullscreen === "function" &&
  typeof document.exitFullscreen === "function" && document.fullscreenEnabled === true &&
  document.fullscreenElement === null && document.fullscreen === false &&
  typeof stage.requestPointerLock === "function" && typeof document.exitPointerLock === "function" &&
  document.pointerLockElement === null && "onfullscreenchange" in document && "onpointerlockchange" in document);
check("MouseEvent has movementX and movementY", new MouseEvent("mousemove", { movementX: 3, movementY: -2 }).movementX === 3 &&
  new MouseEvent("mousemove", { movementY: -2 }).movementY === -2 && new MouseEvent("x").movementX === 0);

document.addEventListener("fullscreenchange", function (e) {
  log.push("change:" + e.target.id + ":" + (document.fullscreenElement ? document.fullscreenElement.id : null));
});
document.addEventListener("fullscreenerror", function (e) { log.push("error:" + (e.target.id || "document")); });

var entered = false;
stage.requestFullscreen().then(function () { entered = true; });
check("the fullscreen element is set at once", document.fullscreenElement === stage && stage.matches(":fullscreen") &&
  !document.getElementById("inner").matches(":fullscreen"));
check("fullscreenchange waits for the next frame", log.length === 0);

var detached = document.createElement("div");
var detachedError = null;
detached.requestFullscreen().catch(function (e) { detachedError = e; });

// A shadow tree's element is retargeted.
var root = host.attachShadow({ mode: "open" });
var shadowed = document.createElement("span");
root.appendChild(shadowed);

var deniedError = null;
var pointerLog = [];
document.addEventListener("pointerlockchange", function () {
  pointerLog.push("change:" + (document.pointerLockElement ? document.pointerLockElement.id : null));
});
document.addEventListener("pointerlockerror", function () { pointerLog.push("error"); });

function step2() {
  check("fullscreenchange fired at the element and the promise resolved",
    log.indexOf("change:stage:stage") >= 0 && entered);
  check("a detached element is refused with fullscreenerror and a TypeError", detachedError instanceof TypeError &&
    log.indexOf("error:document") >= 0);
  log = [];
  document.exitFullscreen().then(function () { log.push("exited"); });
  check("exitFullscreen clears it at once", document.fullscreenElement === null && !stage.matches(":fullscreen"));
  setTimeout(step3, 40);
}

function step3() {
  check("exitFullscreen fires fullscreenchange and resolves", log.join(",") === "change:stage:null,exited");
  log = [];
  shadowed.requestFullscreen();
  check("fullscreenElement is retargeted to the shadow host", document.fullscreenElement === host &&
    root.fullscreenElement === shadowed);
  endScreenMode("fullscreen");
  check("the host leaving fullscreen clears it", document.fullscreenElement === null);
  screenModeAnswer("denied");
  stage.requestFullscreen().catch(function (e) { deniedError = e; });
  setTimeout(step4, 40);
}

function step4() {
  check("a refused request rejects and fires fullscreenerror", deniedError instanceof TypeError &&
    log.indexOf("error:stage") >= 0);
  var lockError = null;
  stage.requestPointerLock().catch(function (e) { lockError = e; });
  screenModeAnswer("granted");
  setTimeout(function () {
    check("a refused pointer lock rejects with NotAllowedError and fires pointerlockerror",
      lockError !== null && lockError.name === "NotAllowedError" && pointerLog.join(",") === "error");
    pointerLog = [];
    stage.requestPointerLock();
    check("the pointer lock element", document.pointerLockElement === stage);
    setTimeout(step5, 10);
  }, 10);
}

function step5() {
  check("pointerlockchange fires at the document", pointerLog.join(",") === "change:stage");
  pointerLog = [];
  document.exitPointerLock();
  check("exitPointerLock", document.pointerLockElement === null);
  stage.requestPointerLock();
  stage.remove();
  check("removing the locked element unlocks", document.pointerLockElement === null);
}

setTimeout(step2, 40);

function after() {
  check("pointerlockchange after exit and removal", pointerLog.length === 3 && document.pointerLockElement === null);
}
