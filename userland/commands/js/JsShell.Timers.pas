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
  The js shell's timers (setTimeout, setInterval) and its event loop:
  run the promise jobs, then the timer due first (sleeping until it is
  due), and again, until nothing is left.
}
unit JsShell.Timers;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  Js.Values,
  Js.Engine;

{ A timer calling Callback (with Arguments) after Delay milliseconds,
  again every Delay when Repeating. Its id. }
function AddTimer(Engine: TJsEngine; Callback: TJsValue; const Arguments: array of TJsValue; Delay: Double;
  Repeating: Boolean): Integer;
procedure RemoveTimer(Engine: TJsEngine; Id: Integer);
{ The event loop: jobs and timers until none are left. EJsError when a
  callback throws. }
procedure RunPendingWork(Engine: TJsEngine);

implementation

uses
  Js.Platform;

type
  TTimer = record
    Id: Integer;
    Due: Double;
    Interval: Double;
    Repeating: Boolean;
    Callback: Integer;
    Arguments: array of Integer;
  end;

var
  Timers: array of TTimer;
  NextId: Integer = 1;

function AddTimer(Engine: TJsEngine; Callback: TJsValue; const Arguments: array of TJsValue; Delay: Double;
  Repeating: Boolean): Integer;
var
  Index: Integer;
  Timer: TTimer;
begin
  if not (Delay >= 1) then
    Delay := 1;
  Timer.Id := NextId;
  Inc(NextId);
  Timer.Due := JsMonotonicTime() + Delay;
  Timer.Interval := Delay;
  Timer.Repeating := Repeating;
  Timer.Callback := Engine.Protect(Callback);
  Timer.Arguments := nil;
  SetLength(Timer.Arguments, Length(Arguments));
  for Index := 0 to High(Arguments) do
    Timer.Arguments[Index] := Engine.Protect(Arguments[Index]);
  SetLength(Timers, Length(Timers) + 1);
  Timers[High(Timers)] := Timer;
  Result := Timer.Id;
end;

procedure ReleaseTimer(Engine: TJsEngine; const Timer: TTimer);
var
  Index: Integer;
begin
  Engine.Unprotect(Timer.Callback);
  for Index := 0 to High(Timer.Arguments) do
    Engine.Unprotect(Timer.Arguments[Index]);
end;

procedure RemoveTimer(Engine: TJsEngine; Id: Integer);
var
  Index: Integer;
begin
  for Index := 0 to High(Timers) do
    if Timers[Index].Id = Id then
    begin
      ReleaseTimer(Engine, Timers[Index]);
      Timers[Index] := Timers[High(Timers)];
      SetLength(Timers, Length(Timers) - 1);
      Exit;
    end;
end;

procedure RunPendingWork(Engine: TJsEngine);
var
  Index, Best: Integer;
  Wait: Double;
  Timer: TTimer;
  Arguments: array of TJsValue;
begin
  while True do
  begin
    Engine.RunJobs;
    if Length(Timers) = 0 then
      Exit;
    Best := 0;
    for Index := 1 to High(Timers) do
      if Timers[Index].Due < Timers[Best].Due then
        Best := Index;
    Wait := Timers[Best].Due - JsMonotonicTime();
    if Wait > 0 then
      Sleep(Trunc(Wait));
    Timer := Timers[Best];
    Arguments := nil;
    SetLength(Arguments, Length(Timer.Arguments));
    for Index := 0 to High(Timer.Arguments) do
      Arguments[Index] := Engine.Protected(Timer.Arguments[Index]);
    if Timer.Repeating then
      Timers[Best].Due := JsMonotonicTime() + Timer.Interval
    else
    begin
      Timers[Best] := Timers[High(Timers)];
      SetLength(Timers, Length(Timers) - 1);
    end;
    try
      Engine.Call(Engine.Protected(Timer.Callback), JsUndefined, Arguments);
    finally
      if not Timer.Repeating then
        ReleaseTimer(Engine, Timer);
    end;
  end;
end;

end.
