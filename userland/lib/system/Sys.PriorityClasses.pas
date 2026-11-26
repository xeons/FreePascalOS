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
  Priority classes (CallSetPriorityClass): where a process's threads
  stand against other processes' - the display server in the System
  class, the desktop and the task manager Interactive, programs Normal,
  a browser's renderers Background or Idle (see Kernel.PriorityClasses).
}
unit Sys.PriorityClasses;

{$mode objfpc}{$H+}

interface

uses
  Abi.SystemCalls;

{ Puts process ProcessId (0: this one) in PriorityClass (PriorityClass*);
  0 or an error (ErrorNotPermitted above Normal unless the caller is in
  that class itself, or root). }
function SetPriorityClass(ProcessId: QWord; PriorityClass: LongWord): LongInt;
{ The class of process ProcessId (0: this one), or -1. }
function GetPriorityClass(ProcessId: QWord): LongInt;
{ "idle", "background", "normal", "interactive", "system". }
function PriorityClassName(PriorityClass: LongWord): string;
{ The class named Name (as above), or -1. }
function PriorityClassByName(const Name: string): LongInt;

implementation

uses
  Sys.Errors;

function SetPriorityClass(ProcessId: QWord; PriorityClass: LongWord): LongInt;
var
  CallResult: Int64;
begin
  CallResult := SystemCall(CallSetPriorityClass, ProcessId, PriorityClass, 0, 0, 0, 0);
  if CallResult < 0 then
    Result := ErrorCodeOf(CallResult)
  else
    Result := ErrorNone;
end;

function GetPriorityClass(ProcessId: QWord): LongInt;
var
  CallResult: Int64;
begin
  CallResult := SystemCall(CallSetPriorityClass, ProcessId, PriorityClassQuery, 0, 0, 0, 0);
  if CallResult < 0 then
    Result := -1
  else
    Result := LongInt(CallResult);
end;

function PriorityClassName(PriorityClass: LongWord): string;
begin
  case PriorityClass of
    PriorityClassIdle: Result := 'idle';
    PriorityClassBackground: Result := 'background';
    PriorityClassNormal: Result := 'normal';
    PriorityClassInteractive: Result := 'interactive';
    PriorityClassSystem: Result := 'system';
  else
    Result := 'unknown';
  end;
end;

function PriorityClassByName(const Name: string): LongInt;
var
  PriorityClass: LongWord;
begin
  for PriorityClass := PriorityClassIdle to PriorityClassHighest do
    if PriorityClassName(PriorityClass) = Name then
      Exit(LongInt(PriorityClass));
  Result := -1;
end;

end.
