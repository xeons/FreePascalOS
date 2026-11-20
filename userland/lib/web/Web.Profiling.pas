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
  Where a page's thread spends its time: the engine marks its phases
  (parsing, style sheets, style, box building, layout, painting,
  scripts, image decoding) and, once a program has started profiling
  with a fine clock, each phase's own time (not counting phases nested
  in it) and the number of times it ran add up here. Only the thread
  that started profiling is counted (decoder threads are not).

    StartProfiling(@MyMicrosecondClock);
    ... load, lay out, paint ...
    for Phase := Low(TWebPhase) to High(TWebPhase) do
      WriteLn(PhaseName(Phase), ' ', PhaseMilliseconds(Phase):0:1);

  It also says what the thread is doing right now (the innermost phase
  and a short detail such as a script's URL), for a watchdog on another
  thread that reports where a page hangs. Without StartProfiling every
  mark is one test of a global.
}
unit Web.Profiling;

{$mode objfpc}
{$H+}

interface

type
  TWebPhase = (PhaseIdle, PhaseHtmlParse, PhaseStyleSheetParse, PhaseStyle, PhaseBoxes, PhaseLayout, PhasePaint,
    PhaseScript, PhaseImageDecode, PhaseTask);

  { Microseconds from any fixed point. }
  TProfilingClock = function: Double;

const
  MaximumPhaseDepth = 64;
  DetailLength = 200;

var
  { True between StartProfiling and StopProfiling. }
  WebProfilingEnabled: Boolean = False;

procedure StartProfiling(Clock: TProfilingClock);
procedure StopProfiling;
procedure ResetProfile;

{ Marks; they nest (each phase is charged its own time only). Calls
  from other threads than the profiled one are ignored. }
procedure EnterPhase(Phase: TWebPhase);
procedure LeavePhase;
{ What the current phase works on (a URL, an element). }
procedure SetPhaseDetail(const Text: string);

function PhaseName(Phase: TWebPhase): string;
function PhaseMilliseconds(Phase: TWebPhase): Double;
function PhaseCount(Phase: TWebPhase): Int64;
{ The longest single run of the phase (its own time). }
function PhaseLongestMilliseconds(Phase: TWebPhase): Double;

{ For another thread (the watchdog): the innermost phase now, how long
  it has run, the phases it is nested in, and its detail. Racy by
  design; good enough to say where a thread hangs. }
function CurrentPhase: TWebPhase;
function CurrentPhaseMilliseconds: Double;
function CurrentPhaseStack: string;
function CurrentPhaseDetail: string;

implementation

type
  TPhaseFrame = record
    Phase: TWebPhase;
    Started: Double;
    Own: Double;
  end;

var
  ProfileClock: TProfilingClock = nil;
  ProfiledThread: TThreadID;
  Totals: array[TWebPhase] of Double;
  Counts: array[TWebPhase] of Int64;
  Longest: array[TWebPhase] of Double;
  Frames: array[0..MaximumPhaseDepth - 1] of TPhaseFrame;
  Depth: Integer = 0;
  Overflow: Integer = 0;
  LastMark: Double;
  CurrentDetail: string[DetailLength];

procedure ResetProfile;
var
  Phase: TWebPhase;
begin
  for Phase := Low(TWebPhase) to High(TWebPhase) do
  begin
    Totals[Phase] := 0;
    Counts[Phase] := 0;
    Longest[Phase] := 0;
  end;
end;

procedure StartProfiling(Clock: TProfilingClock);
begin
  ProfileClock := Clock;
  ProfiledThread := GetCurrentThreadId;
  Depth := 0;
  Overflow := 0;
  CurrentDetail := '';
  ResetProfile;
  LastMark := ProfileClock();
  WebProfilingEnabled := Assigned(Clock);
end;

procedure StopProfiling;
begin
  WebProfilingEnabled := False;
end;

function OnProfiledThread: Boolean; inline;
begin
  Result := WebProfilingEnabled and (GetCurrentThreadId = ProfiledThread);
end;

{ Charges the time since the last mark to the innermost phase. }
procedure ChargeInnermost(Now: Double);
var
  Phase: TWebPhase;
begin
  if Depth > 0 then
  begin
    Frames[Depth - 1].Own := Frames[Depth - 1].Own + (Now - LastMark);
    Phase := Frames[Depth - 1].Phase;
  end
  else
    Phase := PhaseIdle;
  Totals[Phase] := Totals[Phase] + (Now - LastMark);
  LastMark := Now;
end;

procedure EnterPhase(Phase: TWebPhase);
var
  Now: Double;
begin
  if not OnProfiledThread then
    Exit;
  if Depth >= MaximumPhaseDepth then
  begin
    Inc(Overflow);
    Exit;
  end;
  Now := ProfileClock();
  ChargeInnermost(Now);
  Frames[Depth].Phase := Phase;
  Frames[Depth].Started := Now;
  Frames[Depth].Own := 0;
  Inc(Depth);
  Inc(Counts[Phase]);
end;

procedure LeavePhase;
var
  Now: Double;
  Phase: TWebPhase;
begin
  if not OnProfiledThread then
    Exit;
  if Overflow > 0 then
  begin
    Dec(Overflow);
    Exit;
  end;
  if Depth = 0 then
    Exit;
  Now := ProfileClock();
  ChargeInnermost(Now);
  Phase := Frames[Depth - 1].Phase;
  if Frames[Depth - 1].Own > Longest[Phase] then
    Longest[Phase] := Frames[Depth - 1].Own;
  Dec(Depth);
  if Depth = 0 then
    CurrentDetail := '';
end;

procedure SetPhaseDetail(const Text: string);
begin
  if OnProfiledThread then
    CurrentDetail := Copy(Text, 1, DetailLength);
end;

function PhaseName(Phase: TWebPhase): string;
const
  Names: array[TWebPhase] of string = ('idle', 'html-parse', 'css-parse', 'style', 'boxes', 'layout', 'paint',
    'script', 'image-decode', 'other-tasks');
begin
  Result := Names[Phase];
end;

function PhaseMilliseconds(Phase: TWebPhase): Double;
begin
  Result := Totals[Phase] / 1000;
end;

function PhaseCount(Phase: TWebPhase): Int64;
begin
  Result := Counts[Phase];
end;

function PhaseLongestMilliseconds(Phase: TWebPhase): Double;
begin
  Result := Longest[Phase] / 1000;
end;

function CurrentPhase: TWebPhase;
var
  Level: Integer;
begin
  Level := Depth;
  if (Level <= 0) or (Level > MaximumPhaseDepth) then
    Exit(PhaseIdle);
  Result := Frames[Level - 1].Phase;
end;

function CurrentPhaseMilliseconds: Double;
var
  Level: Integer;
begin
  Level := Depth;
  if (Level <= 0) or (Level > MaximumPhaseDepth) or not Assigned(ProfileClock) then
    Exit(0);
  Result := (ProfileClock() - Frames[Level - 1].Started) / 1000;
end;

function CurrentPhaseStack: string;
var
  Level, Index: Integer;
begin
  Result := '';
  Level := Depth;
  if Level > MaximumPhaseDepth then
    Level := MaximumPhaseDepth;
  for Index := 0 to Level - 1 do
  begin
    if Result <> '' then
      Result := Result + ' > ';
    Result := Result + PhaseName(Frames[Index].Phase);
  end;
  if Result = '' then
    Result := PhaseName(PhaseIdle);
end;

function CurrentPhaseDetail: string;
var
  Copied: string[DetailLength];
begin
  Copied := CurrentDetail;
  Result := Copied;
end;

end.
