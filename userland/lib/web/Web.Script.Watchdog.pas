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
  The slow script watchdog: a page's scripts run on the page thread,
  which in a web view is the GUI thread, so a script that never ends (a
  loop without exit, promise jobs queueing each other for ever) would
  freeze the window. A binding context arms the watchdog when the page
  thread enters script and disarms it when it is back out (after the
  microtask checkpoint); a script still running ScriptRunLimit
  milliseconds after it was armed is interrupted: the engine's
  InterruptRequested is set, and the interpreter ends the script with an
  uncatchable termination at its next safe point (a backward jump or a
  call), which the context reports on the console. While the entry stays
  armed the request is repeated, so the scripts that follow in the same
  entry (the remaining promise jobs) end as well.

    Slot := ArmScriptWatchdog(Engine.Runtime);
    try ... run script ... finally DisarmScriptWatchdog(Slot); end;

  One thread serves every armed entry of the process (several pages,
  frames, workers), sleeping while none is armed. Arm and Disarm take a
  lock for a few instructions; the interrupt is only ever requested
  while the entry is armed, and Arm clears a request left over from the
  previous entry.
}
unit Web.Script.Watchdog;

{$mode objfpc}
{$H+}

interface

uses
  Js.Runtime;

const
  { How long a script may run before it is interrupted. The display
    server calls a window "Not responding" after 5 s. }
  DefaultScriptRunLimitMilliseconds = 10000;

var
  ScriptRunLimitMilliseconds: QWord = DefaultScriptRunLimitMilliseconds;

{ Starts watching a script entry on Runtime; returns its slot (-1 when
  every slot is taken: that entry is not watched). }
function ArmScriptWatchdog(Runtime: TJsRuntime): Integer;
{ Ends watching the entry; True if it was interrupted. }
function DisarmScriptWatchdog(Slot: Integer): Boolean;
{ How many entries the watchdog interrupted since the program started. }
function ScriptWatchdogInterruptions: Integer;

implementation

uses
  Classes,
  SysUtils;

const
  SlotCount = 64;
  CheckIntervalMilliseconds = 100;

type
  TWatchedEntry = record
    Runtime: TJsRuntime;
    StartedAt: QWord;
    Expired: Boolean;
  end;

  TWatchdogThread = class(TThread)
  protected
    procedure Execute; override;
  end;

var
  Lock: TRTLCriticalSection;
  WakeEvent: PRTLEvent;
  Entries: array[0..SlotCount - 1] of TWatchedEntry;
  ArmedCount: Integer;
  Interruptions: Integer;
  Watcher: TWatchdogThread;

{ Under the lock: interrupts the entries past their time; True while any
  entry is armed. }
function CheckEntries: Boolean;
var
  Index: Integer;
  Now: QWord;
begin
  Now := GetTickCount64;
  for Index := 0 to SlotCount - 1 do
    if Entries[Index].Runtime <> nil then
      if Entries[Index].Expired or (Now - Entries[Index].StartedAt >= ScriptRunLimitMilliseconds) then
      begin
        if not Entries[Index].Expired then
          Inc(Interruptions);
        Entries[Index].Expired := True;
        Entries[Index].Runtime.InterruptRequested := True;
      end;
  Result := ArmedCount > 0;
end;

procedure TWatchdogThread.Execute;
var
  Busy: Boolean;
begin
  while not Terminated do
  begin
    EnterCriticalSection(Lock);
    try
      Busy := CheckEntries;
    finally
      LeaveCriticalSection(Lock);
    end;
    if Busy then
      RTLEventWaitFor(WakeEvent, CheckIntervalMilliseconds)
    else
      RTLEventWaitFor(WakeEvent);
    RTLEventResetEvent(WakeEvent);
  end;
end;

function ArmScriptWatchdog(Runtime: TJsRuntime): Integer;
var
  Index: Integer;
  StartThread: Boolean;
begin
  Result := -1;
  StartThread := False;
  EnterCriticalSection(Lock);
  try
    for Index := 0 to SlotCount - 1 do
      if Entries[Index].Runtime = nil then
      begin
        Entries[Index].Runtime := Runtime;
        Entries[Index].StartedAt := GetTickCount64;
        Entries[Index].Expired := False;
        Runtime.InterruptRequested := False;
        Inc(ArmedCount);
        Result := Index;
        Break;
      end;
    if (Result >= 0) and (Watcher = nil) then
    begin
      Watcher := TWatchdogThread.Create(True);
      Watcher.FreeOnTerminate := False;
      StartThread := True;
    end;
  finally
    LeaveCriticalSection(Lock);
  end;
  if StartThread then
    Watcher.Start
  else if Result >= 0 then
    RTLEventSetEvent(WakeEvent);
end;

function DisarmScriptWatchdog(Slot: Integer): Boolean;
begin
  Result := False;
  if (Slot < 0) or (Slot >= SlotCount) then
    Exit;
  EnterCriticalSection(Lock);
  try
    if Entries[Slot].Runtime <> nil then
    begin
      Result := Entries[Slot].Expired;
      if Result then
        Entries[Slot].Runtime.InterruptRequested := False;
      Entries[Slot].Runtime := nil;
      Dec(ArmedCount);
    end;
  finally
    LeaveCriticalSection(Lock);
  end;
end;

function ScriptWatchdogInterruptions: Integer;
begin
  EnterCriticalSection(Lock);
  try
    Result := Interruptions;
  finally
    LeaveCriticalSection(Lock);
  end;
end;

initialization
  InitCriticalSection(Lock);
  WakeEvent := RTLEventCreate;

finalization
  if Watcher <> nil then
  begin
    Watcher.Terminate;
    RTLEventSetEvent(WakeEvent);
    Watcher.WaitFor;
    Watcher.Free;
  end;
  RTLEventDestroy(WakeEvent);
  DoneCriticalSection(Lock);

end.
