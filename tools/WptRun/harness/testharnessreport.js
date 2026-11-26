/*
  FreePascalOS
  Copyright (C) 2026 Brandon Scott

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
*/

/*
  wptrun's testharnessreport.js: wpt serve hands it out in place of the
  checkout's own (an alias in tools/WptRun/server/aliases.txt). Once
  testharness.js has every result it prints one console line:

    wptrun-result:{"url":...,"status":0,"message":null,"tests":[...]}

  which the runner reads from the session's console. As wptrunner does,
  the harness draws no results table (output: false).
*/
(function () {
  var marker = "wptrun-result:";

  function text(value) {
    if (value === null || value === undefined)
      return null;
    return String(value);
  }

  try {
    setup({ output: false, explicit_timeout: false });
  } catch (error) {
  }

  add_completion_callback(function (tests, harnessStatus) {
    var results = [];
    for (var index = 0; index < tests.length; index++)
      results.push({
        name: text(tests[index].name),
        status: tests[index].status,
        message: text(tests[index].message)
      });
    var report = {
      url: String(location.href),
      status: harnessStatus.status,
      message: text(harnessStatus.message),
      tests: results
    };
    console.log(marker + JSON.stringify(report));
  });
})();
