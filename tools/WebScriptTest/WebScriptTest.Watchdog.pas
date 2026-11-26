{
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
}

{
  The slow script watchdog (Web.Script.Watchdog): a script that never
  ends - a loop, promise jobs queueing each other, a timer callback
  that loops, a WebAssembly function that loops (the store's interrupt
  hook) - is stopped after the run limit and reported on the console,
  and the page's next scripts run normally. A script that allocates
  without end is stopped at the page's script heap limit
  (ContextHeapLimit) with an out of memory error.
}
unit WebScriptTest.Watchdog;

{$mode objfpc}
{$H+}

interface

procedure RunWatchdogTests;

implementation

uses
  SysUtils,
  TestChecks,
  Web.Script.Watchdog,
  Web.Bindings.Context,
  WebScriptTest.Harness;

const
  TestLimitMilliseconds = 300;
  { (module (func (export "spin") (loop (br 0)))) }
  SpinModule = 'new WebAssembly.Instance(new WebAssembly.Module(new Uint8Array([0, 97, 115, 109, 1, 0, 0, 0, 1, 4, ' +
    '1, 96, 0, 0, 3, 2, 1, 0, 7, 8, 1, 4, 115, 112, 105, 110, 0, 0, 10, 9, 1, 7, 0, 3, 64, 12, 0, 11, 11]))).exports.spin';
  StoppedText = 'was stopped';

{ Runs Source in Bed; True if it came back within a few seconds. }
function RunBounded(Bed: TTestBed; const Source: string): Boolean;
var
  Started: QWord;
begin
  Started := GetTickCount64;
  Bed.Run(Source);
  Result := GetTickCount64 - Started < 5000;
end;

procedure CheckStopped(const Name, Source: string);
var
  Bed: TTestBed;
  Before: Integer;
begin
  Bed := TTestBed.Create('watchdog-' + Name);
  try
    Before := ScriptWatchdogInterruptions;
    Check(RunBounded(Bed, Source), 'watchdog: ' + Name + ' is stopped');
    Check(ScriptWatchdogInterruptions = Before + 1, 'watchdog: ' + Name + ' counted once');
    Check(Pos(StoppedText, Bed.ConsoleText) > 0, 'watchdog: ' + Name + ' reported' + LineEnding + Bed.ConsoleText);
    { The page goes on: its next script runs and is not interrupted. }
    Check(Bed.Evaluate('var total = 0; for (var i = 0; i < 100000; i++) total += i; total') = '4999950000',
      'watchdog: a script after ' + Name + ' runs');
  finally
    Bed.Free;
  end;
end;

procedure CheckOutOfMemory;
const
  TestHeapLimit = 48 * 1024 * 1024;
var
  SavedLimit: Int64;
  Bed: TTestBed;
begin
  SavedLimit := ContextHeapLimit;
  ContextHeapLimit := TestHeapLimit;
  try
    Bed := TTestBed.Create('out-of-memory');
    try
      Check(RunBounded(Bed, 'var kept = []; for (;;) kept.push(new Array(1000).fill("x" + kept.length));'),
        'heap limit: endless allocation is stopped');
      Check(Pos('Out of memory', Bed.ConsoleText) > 0, 'heap limit: reported' + LineEnding + Bed.ConsoleText);
      Check(Bed.Evaluate('kept = null; var small = []; for (var i = 0; i < 1000; i++) small.push(i); small.length') =
        '1000', 'heap limit: the page runs on once the memory is let go');
    finally
      Bed.Free;
    end;
  finally
    ContextHeapLimit := SavedLimit;
  end;
end;

procedure RunWatchdogTests;
var
  Saved: QWord;
  Bed: TTestBed;
begin
  CheckOutOfMemory;
  Saved := ScriptRunLimitMilliseconds;
  ScriptRunLimitMilliseconds := TestLimitMilliseconds;
  try
    CheckStopped('an endless loop', 'while (true) {}');
    CheckStopped('an endless loop with try', 'for (;;) { try { while (true) {} } catch (e) {} }');
    CheckStopped('promise jobs queueing each other',
      'function again() { Promise.resolve().then(again); } again();');
    CheckStopped('a timer callback that loops', 'setTimeout(function () { while (true) {} }, 0);');
    CheckStopped('a WebAssembly loop', SpinModule + '();');
    CheckStopped('a WebAssembly loop caught and called again',
      'var spin = ' + SpinModule + '; for (;;) { try { spin(); } catch (e) {} }');
    { A script that ends in time is left alone. }
    Bed := TTestBed.Create('watchdog-quick');
    try
      Bed.Run('var start = Date.now(); while (Date.now() - start < 100) {} globalThis.finished = true;');
      Check(Bed.Evaluate('finished') = 'true', 'watchdog: a script within the limit finishes');
      Check(Pos(StoppedText, Bed.ConsoleText) = 0, 'watchdog: a script within the limit is not reported');
    finally
      Bed.Free;
    end;
  finally
    ScriptRunLimitMilliseconds := Saved;
  end;
end;

end.
