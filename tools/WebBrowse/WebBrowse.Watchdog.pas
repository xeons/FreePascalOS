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
  A thread that watches the page thread: the page thread beats (Beat)
  each time round its loop; when no beat comes for StallSeconds the
  watchdog prints where the page thread is (libweb's current phase,
  its nesting and detail from Web.Profiling, and on x86-64 a stack
  from WebBrowse.Sampler), again every StallSeconds while it stays stuck,
  and ends the process after HardLimitSeconds without a beat.
}
unit WebBrowse.Watchdog;

{$mode objfpc}
{$H+}

interface

procedure StartWatchdog(StallSeconds, HardLimitSeconds: Integer);
procedure StopWatchdog;
procedure Beat;
{ Prints the page thread's stack now (from the watchdog or a handler). }
function SamplePageThreadStack: string;

implementation

uses
  SysUtils,
  Classes,
  BaseUnix,
  Web.Profiling,
  WebBrowse.Sampler;

type
  TWatchdogThread = class(TThread)
  protected
    procedure Execute; override;
  public
    StallSeconds, HardLimitSeconds: Integer;
  end;

var
  Watchdog: TWatchdogThread = nil;
  Beats: LongWord = 0;
  { Set to stop the watchdog at once rather than at its next second. }
  StopRequested: PRTLEvent = nil;

procedure Beat;
begin
  InterlockedIncrement(Beats);
end;

function SamplePageThreadStack: string;
var
  Sample: TStackSample;
begin
  {$ifdef CPUX86_64}
  if TakeSample(Sample) then
    Result := DescribeSample(Sample)
  else
    Result := '  (the page thread did not answer)' + LineEnding;
  {$else}
  Result := '  (stack samples need x86-64)' + LineEnding;
  {$endif}
end;

procedure Report(Seconds: Integer);
begin
  WriteLn(StdErr, Format('watchdog: no progress for %d s; in %s (%.0f ms)', [Seconds, CurrentPhaseStack,
    CurrentPhaseMilliseconds]));
  if CurrentPhaseDetail <> '' then
    WriteLn(StdErr, 'watchdog: working on ', CurrentPhaseDetail);
  Write(StdErr, SamplePageThreadStack);
  Flush(StdErr);
end;

procedure TWatchdogThread.Execute;
var
  LastBeats: LongWord;
  StillFor: Integer;
begin
  LastBeats := Beats;
  StillFor := 0;
  while not Terminated do
  begin
    RTLEventWaitFor(StopRequested, 1000);
    if Terminated then
      Break;
    if Beats <> LastBeats then
    begin
      LastBeats := Beats;
      StillFor := 0;
      Continue;
    end;
    Inc(StillFor);
    if (StallSeconds > 0) and (StillFor mod StallSeconds = 0) then
      Report(StillFor);
    if (HardLimitSeconds > 0) and (StillFor >= HardLimitSeconds) then
    begin
      WriteLn(StdErr, 'watchdog: giving up after ', StillFor, ' s without progress');
      Flush(StdErr);
      FpExit(3);
    end;
  end;
end;

procedure StartWatchdog(StallSeconds, HardLimitSeconds: Integer);
begin
  StopRequested := RTLEventCreate;
  Watchdog := TWatchdogThread.Create(True);
  Watchdog.StallSeconds := StallSeconds;
  Watchdog.HardLimitSeconds := HardLimitSeconds;
  Watchdog.FreeOnTerminate := False;
  Watchdog.Start;
end;

procedure StopWatchdog;
begin
  if Watchdog = nil then
    Exit;
  Watchdog.Terminate;
  RTLEventSetEvent(StopRequested);
  Watchdog.WaitFor;
  FreeAndNil(Watchdog);
  RTLEventDestroy(StopRequested);
  StopRequested := nil;
end;

end.
