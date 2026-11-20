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
  sampled by interrupting the thread with SIGUSR1, symbolized from the
  line information), again every StallSeconds while it stays stuck,
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
  UnixType,
  Web.Profiling;

const
  MaximumSampleDepth = 48;

type
  TWatchdogThread = class(TThread)
  protected
    procedure Execute; override;
  public
    StallSeconds, HardLimitSeconds: Integer;
  end;

function pthread_kill(Thread: TThreadID; Signal: cint): cint; cdecl; external 'c' name 'pthread_kill';

var
  Watchdog: TWatchdogThread = nil;
  PageThread: TThreadID;
  Beats: LongWord = 0;
  Samples: array[0..MaximumSampleDepth - 1] of CodePointer;
  SampleCount: LongInt = 0;
  SampleTaken: LongInt = 0;

procedure Beat;
begin
  InterlockedIncrement(Beats);
end;

{$ifdef CPUX86_64}
{ Linux x86-64 ucontext_t: gregs start at 40; RBP is register 10, RIP 16. }
procedure SampleHandler(Signal: cint; Info: PSigInfo; Context: Pointer); cdecl;
var
  Frame, Previous: Pointer;
  Count: LongInt;
begin
  Count := 0;
  Samples[Count] := PCodePointer(PByte(Context) + 40 + 16 * 8)^;
  Inc(Count);
  Frame := PPointer(PByte(Context) + 40 + 10 * 8)^;
  Previous := nil;
  while (Count < MaximumSampleDepth) and (Frame <> nil) and (PtrUInt(Frame) > PtrUInt(Previous)) and
    ((Previous = nil) or (PtrUInt(Frame) - PtrUInt(Previous) < 4 * 1024 * 1024)) and (PtrUInt(Frame) and 7 = 0) do
  begin
    Samples[Count] := PCodePointer(PByte(Frame) + 8)^;
    Inc(Count);
    Previous := Frame;
    Frame := PPointer(Frame)^;
  end;
  SampleCount := Count;
  InterlockedExchange(SampleTaken, 1);
end;

procedure InstallSampleHandler;
var
  Action: SigActionRec;
begin
  FillChar(Action, SizeOf(Action), 0);
  Action.sa_handler := SigActionHandler(@SampleHandler);
  Action.sa_flags := SA_SIGINFO or SA_RESTART;
  fpSigAction(SIGUSR1, @Action, nil);
end;
{$endif}

function SamplePageThreadStack: string;
var
  Index, Waited: Integer;
begin
  Result := '';
  {$ifdef CPUX86_64}
  InterlockedExchange(SampleTaken, 0);
  if pthread_kill(PageThread, SIGUSR1) <> 0 then
    Exit('  (cannot interrupt the page thread)');
  Waited := 0;
  while (SampleTaken = 0) and (Waited < 100) do
  begin
    Sleep(10);
    Inc(Waited);
  end;
  if SampleTaken = 0 then
    Exit('  (the page thread did not answer)');
  for Index := 0 to SampleCount - 1 do
    Result := Result + '  ' + BackTraceStrFunc(Samples[Index]) + LineEnding;
  {$else}
  Result := '  (stack samples need x86-64)';
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
    Sleep(1000);
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
  PageThread := GetCurrentThreadId;
  {$ifdef CPUX86_64}
  InstallSampleHandler;
  {$endif}
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
  Watchdog.WaitFor;
  FreeAndNil(Watchdog);
end;

end.
