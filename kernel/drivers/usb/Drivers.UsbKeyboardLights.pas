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
  The lock lights of USB keyboards.

  A lock key is handled at dispatch level (in the report's deferred
  call), but telling the keyboard to light up takes a control transfer
  (SET_REPORT), which waits. So the keyboard only notes the lights it
  wants (SetWantedLights) and wakes the "UsbLights" thread, which sends
  each keyboard whose lights differ from the last ones sent what it now
  wants, through the routine the HID driver gave (it knows the report's
  layout and the interface). A keyboard that refuses is not asked again
  until its lights change once more.
}
unit Drivers.UsbKeyboardLights;

{$mode objfpc}

interface

const
  NothingSent = High(PtrUInt);

type
  { Sends Lights (HidLight* bits) to the keyboard; False if it failed. }
  TSendLightsRoutine = function(Context: Pointer; Lights: Byte): Boolean;

  PKeyboardLights = ^TKeyboardLights;
  TKeyboardLights = record
    Routine: TSendLightsRoutine;
    Context: Pointer;
    { What the keyboard should show, and what it was last sent
      (NothingSent: nothing yet, or forgotten after waking). }
    Wanted: PtrUInt;
    Sent: PtrUInt;
    IsRegistered: Boolean;
    { The keyboard's input device, for the log. }
    Name: array[0..15] of Char;
  end;

{ Registers Lights (kept by the caller for good) with the thread, which
  is started the first time. Passive level. }
procedure RegisterKeyboardLights(Lights: PKeyboardLights);
{ Sets the routine that sends the lights (nil: the keyboard has none). }
procedure SetSendLightsRoutine(Lights: PKeyboardLights; Routine: TSendLightsRoutine; Context: Pointer);
{ The keyboard should show Wanted (HidLight* bits); any level. }
procedure SetWantedLights(Lights: PKeyboardLights; Wanted: Byte);
{ The keyboard forgot what it showed (woken from suspend to RAM): it is
  sent its lights again. }
procedure ResendLights(Lights: PKeyboardLights);
{ Lights reports sent so far (for coretest's input check). }
function LightsReportsSent: QWord;

implementation

uses
  Runtime.Atomic,
  Drivers.HidReports,
  Kernel.Events,
  Kernel.Threads,
  Processes.Thread,
  Debug.Output;

const
  MaximumKeyboards = 8;

var
  Keyboards: array[0..MaximumKeyboards - 1] of PKeyboardLights;
  KeyboardCount: PtrUInt;
  LightsChanged: TEvent;
  ThreadStarted: Boolean;
  ReportsSent: Int64;

function LightsReportsSent: QWord;
begin
  Result := QWord(AtomicFetchAndAdd(ReportsSent, 0));
end;

procedure WriteLightsSent(Lights: PKeyboardLights; Wanted: Byte; Sent: Boolean);
begin
  DebugBeginMessage;
  DebugWriteTag('input');
  DebugWrite(@Lights^.Name[0]);
  if Sent then
    DebugWrite(' lights:')
  else
    DebugWrite(' refused the lights:');
  if Wanted = 0 then
    DebugWrite(' off');
  if (Wanted and HidLightNumLock) <> 0 then
    DebugWrite(' Num Lock');
  if (Wanted and HidLightCapsLock) <> 0 then
    DebugWrite(' Caps Lock');
  if (Wanted and HidLightScrollLock) <> 0 then
    DebugWrite(' Scroll Lock');
  DebugWriteLine('');
  DebugEndMessage;
end;

procedure SendWhatChanged;
var
  Index: PtrUInt;
  Lights: PKeyboardLights;
  Wanted: PtrUInt;
  Sent: Boolean;
begin
  Index := 0;
  while Index < AtomicLoad(KeyboardCount) do
  begin
    Lights := Keyboards[Index];
    Inc(Index);
    Wanted := AtomicLoad(Lights^.Wanted);
    if (Lights^.Routine = nil) or (Wanted = Lights^.Sent) then
      Continue;
    { Noted first: a change while sending is sent next time round. }
    Lights^.Sent := Wanted;
    Sent := Lights^.Routine(Lights^.Context, Byte(Wanted));
    if Sent then
      AtomicIncrement(ReportsSent);
    WriteLightsSent(Lights, Byte(Wanted), Sent);
  end;
end;

procedure RunLightsThread(Context: Pointer);
begin
  while True do
  begin
    WaitForEvent(LightsChanged);
    SendWhatChanged;
  end;
end;

procedure RegisterKeyboardLights(Lights: PKeyboardLights);
begin
  if not ThreadStarted then
  begin
    InitializeEvent(LightsChanged, EventKindSynchronization, False);
    if CreateSystemThread(@RunLightsThread, nil, DefaultThreadPriority, 'UsbLights', False) = nil then
    begin
      DebugWriteLine('[usb] no thread for the keyboard lights');
      Exit;
    end;
    ThreadStarted := True;
  end;
  if AtomicLoad(KeyboardCount) = MaximumKeyboards then
    Exit;
  Lights^.Sent := NothingSent;
  Keyboards[KeyboardCount] := Lights;
  AtomicStore(KeyboardCount, KeyboardCount + 1);
  Lights^.IsRegistered := True;
end;

procedure SetSendLightsRoutine(Lights: PKeyboardLights; Routine: TSendLightsRoutine; Context: Pointer);
begin
  Lights^.Context := Context;
  Lights^.Routine := Routine;
  if Lights^.IsRegistered then
    SignalEvent(LightsChanged);
end;

procedure SetWantedLights(Lights: PKeyboardLights; Wanted: Byte);
begin
  AtomicStore(Lights^.Wanted, PtrUInt(Wanted));
  if Lights^.IsRegistered then
    SignalEvent(LightsChanged);
end;

procedure ResendLights(Lights: PKeyboardLights);
begin
  Lights^.Sent := NothingSent;
  if Lights^.IsRegistered then
    SignalEvent(LightsChanged);
end;

end.
