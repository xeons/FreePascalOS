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
  that loops - is stopped after the run limit and reported on the
  console, and the page's next scripts run normally.
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
  WebScriptTest.Harness;

const
  TestLimitMilliseconds = 300;
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

procedure RunWatchdogTests;
var
  Saved: QWord;
  Bed: TTestBed;
begin
  Saved := ScriptRunLimitMilliseconds;
  ScriptRunLimitMilliseconds := TestLimitMilliseconds;
  try
    CheckStopped('an endless loop', 'while (true) {}');
    CheckStopped('an endless loop with try', 'for (;;) { try { while (true) {} } catch (e) {} }');
    CheckStopped('promise jobs queueing each other',
      'function again() { Promise.resolve().then(again); } again();');
    CheckStopped('a timer callback that loops', 'setTimeout(function () { while (true) {} }, 0);');
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
