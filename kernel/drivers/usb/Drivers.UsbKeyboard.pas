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
  USB keyboards: the keyboard half of a HID interface (Drivers.UsbHid
  finds the interface and hands its keyboard reports here).

  Reports come in the boot protocol's form: a byte of modifier bits
  (Ctrl, Shift, Alt, GUI, left and right), a reserved byte, and the
  usage codes of up to six keys held. A boot keyboard sends that itself;
  a keyboard in the report protocol has its reports turned into it
  (Drivers.HidReports.ReadKeyboardAsBoot). Comparing a report with the
  one before gives the keys pressed and released; they are mapped onto
  the PS/2 scan codes and go through the same translation as the PS/2
  keyboard (Drivers.KeyboardTranslation: layout, dead keys, locks).
  Each keyboard has an input device "usbkeyboardN" that the console
  reads like the PS/2 keyboard.

  USB keyboards do not repeat keys themselves (SET_IDLE 0 asks them to
  report only changes), so the driver does: the last key pressed (not
  a modifier nor a lock key) is pressed again after the key repeat
  delay and then at the repeat rate (Drivers.KeyboardRepeat, the same
  settings the PS/2 keyboard's typematic gets), by a kernel timer, until
  it is released, another key is pressed, or the keyboard goes away.
  Reports and the timer's call both run at dispatch level, possibly on
  two processors: the keyboard's lock keeps them apart.

  A lock key that changes the locks sets the keyboard's lights
  (Drivers.UsbKeyboardLights, sent by a thread with SET_REPORT through
  the HID driver's routine).
}
unit Drivers.UsbKeyboard;

{$mode objfpc}
{$pointermath on}

interface

uses
  Kernel.SpinLock,
  Kernel.Timers,
  Kernel.DeferredCalls,
  Drivers.HidReports,
  Drivers.KeyboardTranslation,
  Drivers.UsbKeyboardLights;

type
  PUsbKeyboard = ^TUsbKeyboard;
  TUsbKeyboard = record
    Keys: TKeyboardState;
    Previous: TBootKeyboardReport;
    { Keeps reports and the repeat timer's call apart. }
    Lock: TSpinLock;
    RepeatTimer: TTimer;
    RepeatCall: TDeferredCall;
    { The key that repeats (a scan code), 0 if none. }
    RepeatScanCode: Word;
    Repeats: QWord;
    IsGone: Boolean;
    Lights: TKeyboardLights;
  end;

{ A new keyboard with its input device (usbkeyboardN), attached to the
  console; nil if there are too many already. }
function CreateUsbKeyboard: PUsbKeyboard;
{ A report from the keyboard, in the boot protocol's form (called at
  dispatch level). }
procedure HandleUsbKeyboardReport(Keyboard: PUsbKeyboard; const Report: TBootKeyboardReport);
{ Every key counts as released (after waking from suspend to RAM), the
  repeat stops, and the lights are sent again. }
procedure ResetUsbKeyboard(Keyboard: PUsbKeyboard);
{ Unplugged: the repeat stops for good. }
procedure StopUsbKeyboard(Keyboard: PUsbKeyboard);
{ How the keyboard's lights are set (nil: it has none). }
procedure SetUsbKeyboardLightsRoutine(Keyboard: PUsbKeyboard; Routine: TSendLightsRoutine; Context: Pointer);
{ Keys pressed on every USB keyboard so far. }
function UsbKeyboardKeyCount: QWord;
{ Repeated presses of held keys on every USB keyboard so far. }
function UsbKeyboardRepeatCount: QWord;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Kernel.PriorityLevel,
  Memory.KernelHeap,
  Drivers.KeyboardRepeat,
  Io.Manager,
  Io.InputDevice,
  Io.ConsoleInput,
  Debug.Output;

const
  MaximumKeyboards = 4;
  Extended = $100;
  { Lock keys toggle on each press: they do not repeat. }
  ScanCapsLock = $3A;
  ScanNumLock = $45;
  ScanScrollLock = $46;

  { HID usage codes 00h-64h as set 1 scan codes (Extended: after E0);
    0 for keys left out. }
  UsageToScanCode: array[0..$64] of Word = (
    0, 0, 0, 0,
    $1E, $30, $2E, $20, $12, $21, $22, $23, $17, $24, $25, $26, $32, $31, $18, $19,  { a-p }
    $10, $13, $1F, $14, $16, $2F, $11, $2D, $15, $2C,                               { q-z }
    $02, $03, $04, $05, $06, $07, $08, $09, $0A, $0B,                               { 1-0 }
    $1C, $01, $0E, $0F, $39, $0C, $0D, $1A, $1B, $2B, $2B, $27, $28, $29, $33, $34, { enter .. . }
    $35, $3A,                                                                       { / caps }
    $3B, $3C, $3D, $3E, $3F, $40, $41, $42, $43, $44, $57, $58,                     { F1-F12 }
    0, $46, 0,                                                                      { print scroll pause }
    Extended or $52, Extended or $47, Extended or $49, Extended or $53,             { insert home pgup del }
    Extended or $4F, Extended or $51, Extended or $4D, Extended or $4B,             { end pgdn right left }
    Extended or $50, Extended or $48,                                               { down up }
    $45, Extended or $35, $37, $4A, $4E, Extended or $1C,                           { num / * - + enter }
    $4F, $50, $51, $4B, $4C, $4D, $47, $48, $49, $52, $53,                          { keypad 1-9 0 . }
    $56);                                                                           { ISO key }

  { The modifier bits, in report order, as scan codes. }
  ModifierScanCodes: array[0..7] of Word = (
    $1D, $2A, $38, Extended or $5B, Extended or $1D, $36, Extended or $38, Extended or $5C);

var
  KeyboardDriver: PDriverObject;
  Keyboards: array[0..MaximumKeyboards - 1] of PUsbKeyboard;
  KeyboardCount: Integer;

function UsbKeyboardKeyCount: QWord;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to KeyboardCount - 1 do
    Result := Result + Keyboards[Index]^.Keys.KeyCount;
end;

function UsbKeyboardRepeatCount: QWord;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 0 to KeyboardCount - 1 do
    Result := Result + Keyboards[Index]^.Repeats;
end;

{ The PS/2 order of KeyboardLights as HID lights. }
function HidLights(Ps2Lights: Byte): Byte;
begin
  Result := 0;
  if (Ps2Lights and LightNumLock) <> 0 then
    Result := Result or HidLightNumLock;
  if (Ps2Lights and LightCapsLock) <> 0 then
    Result := Result or HidLightCapsLock;
  if (Ps2Lights and LightScrollLock) <> 0 then
    Result := Result or HidLightScrollLock;
end;

{ Keyboard's lock held. }
procedure SendKey(Keyboard: PUsbKeyboard; ScanCode: Word; Released: Boolean);
begin
  if ScanCode = 0 then
    Exit;
  if TranslateKey(Keyboard^.Keys, Byte(ScanCode), (ScanCode and Extended) <> 0, Released) then
    SetWantedLights(@Keyboard^.Lights, HidLights(KeyboardLights(Keyboard^.Keys)));
end;

function KeyRepeats(ScanCode: Word): Boolean;
begin
  Result := (ScanCode <> 0) and (ScanCode <> ScanCapsLock) and (ScanCode <> ScanNumLock) and
    (ScanCode <> ScanScrollLock);
end;

{ Keyboard's lock held. }
procedure StopRepeat(Keyboard: PUsbKeyboard);
begin
  Keyboard^.RepeatScanCode := 0;
  CancelTimer(Keyboard^.RepeatTimer);
end;

{ Keyboard's lock held: ScanCode was just pressed. }
procedure StartRepeat(Keyboard: PUsbKeyboard; ScanCode: Word);
begin
  if not KeyRepeats(ScanCode) or Keyboard^.IsGone then
    Exit;
  Keyboard^.RepeatScanCode := ScanCode;
  SetTimer(Keyboard^.RepeatTimer, KeyRepeatDelay, Keyboard^.RepeatCall);
end;

{ The repeat timer's call, at dispatch level: the key, if still held,
  is pressed again and the timer set for the next repeat. Cancelling
  cannot take back a call already queued, so the key is checked here. }
procedure RepeatHeldKey(Context: Pointer);
var
  Keyboard: PUsbKeyboard;
  PreviousLevel: TPriorityLevel;
  Rate: LongWord;
begin
  Keyboard := PUsbKeyboard(Context);
  PreviousLevel := AcquireSpinLock(Keyboard^.Lock);
  if (Keyboard^.RepeatScanCode <> 0) and not Keyboard^.IsGone and not Keyboard^.RepeatTimer.IsSet then
  begin
    SendKey(Keyboard, Keyboard^.RepeatScanCode, False);
    Inc(Keyboard^.Repeats);
    Rate := KeyRepeatRate;
    if Rate = 0 then
      Rate := 1;
    SetTimer(Keyboard^.RepeatTimer, 1000 div Rate, Keyboard^.RepeatCall);
  end;
  ReleaseSpinLock(Keyboard^.Lock, PreviousLevel);
end;

function ReportHolds(const Report: TBootKeyboardReport; Usage: Byte): Boolean;
var
  Index: Integer;
begin
  for Index := 2 to BootKeyboardReportSize - 1 do
    if Report[Index] = Usage then
      Exit(True);
  Result := False;
end;

{ Compares a report with the one before: modifiers first (so Shift is
  down before the letter it shifts), then released and pressed keys. }
procedure HandleUsbKeyboardReport(Keyboard: PUsbKeyboard; const Report: TBootKeyboardReport);
var
  Bit: Integer;
  Index: Integer;
  Usage: Byte;
  ScanCode: Word;
  PreviousLevel: TPriorityLevel;
begin
  { Too many keys at once: the keyboard cannot tell which. }
  if Report[2] = KeyUsageErrorRollOver then
    Exit;
  PreviousLevel := AcquireSpinLock(Keyboard^.Lock);
  for Bit := 0 to 7 do
    if ((Report[0] xor Keyboard^.Previous[0]) and (1 shl Bit)) <> 0 then
      SendKey(Keyboard, ModifierScanCodes[Bit], (Report[0] and (1 shl Bit)) = 0);
  for Index := 2 to BootKeyboardReportSize - 1 do
  begin
    Usage := Keyboard^.Previous[Index];
    if (Usage <= High(UsageToScanCode)) and (Usage <> 0) and not ReportHolds(Report, Usage) then
    begin
      ScanCode := UsageToScanCode[Usage];
      if ScanCode = Keyboard^.RepeatScanCode then
        StopRepeat(Keyboard);
      SendKey(Keyboard, ScanCode, True);
    end;
  end;
  for Index := 2 to BootKeyboardReportSize - 1 do
  begin
    Usage := Report[Index];
    if (Usage <= High(UsageToScanCode)) and (Usage <> 0) and not ReportHolds(Keyboard^.Previous, Usage) then
    begin
      ScanCode := UsageToScanCode[Usage];
      SendKey(Keyboard, ScanCode, False);
      { The newest key repeats, as on a PS/2 keyboard. }
      StopRepeat(Keyboard);
      StartRepeat(Keyboard, ScanCode);
    end;
  end;
  Keyboard^.Previous := Report;
  ReleaseSpinLock(Keyboard^.Lock, PreviousLevel);
end;

procedure ResetUsbKeyboard(Keyboard: PUsbKeyboard);
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(Keyboard^.Lock);
  StopRepeat(Keyboard);
  FillMemory(@Keyboard^.Previous[0], SizeOf(Keyboard^.Previous), 0);
  ReleaseSpinLock(Keyboard^.Lock, PreviousLevel);
  ResendLights(@Keyboard^.Lights);
end;

procedure StopUsbKeyboard(Keyboard: PUsbKeyboard);
var
  PreviousLevel: TPriorityLevel;
begin
  PreviousLevel := AcquireSpinLock(Keyboard^.Lock);
  Keyboard^.IsGone := True;
  StopRepeat(Keyboard);
  ReleaseSpinLock(Keyboard^.Lock, PreviousLevel);
  SetSendLightsRoutine(@Keyboard^.Lights, nil, nil);
end;

procedure SetUsbKeyboardLightsRoutine(Keyboard: PUsbKeyboard; Routine: TSendLightsRoutine; Context: Pointer);
begin
  SetSendLightsRoutine(@Keyboard^.Lights, Routine, Context);
end;

function CreateKeyboardDevice(Name: PChar): PInputDevice;
const
  OwnerReadWrite = $180; { rw------- }
var
  Dispatch: TDispatchTable;
  Device: PDeviceObject;
begin
  Result := nil;
  if KeyboardDriver = nil then
  begin
    FillMemory(@Dispatch, SizeOf(Dispatch), 0);
    Dispatch[IoFunctionRead] := @ReadInputDevice;
    KeyboardDriver := CreateDriver('usbkeyboard', Dispatch);
  end;
  Device := CreateDevice(KeyboardDriver, Name, DeviceKindCharacter, OwnerReadWrite, SizeOf(TInputDevice));
  if Device = nil then
    Exit;
  Device^.IsExclusive := True;
  Result := PInputDevice(Device^.Extension);
  InitializeInputDevice(Result^);
end;

function CreateUsbKeyboard: PUsbKeyboard;
var
  Keyboard: PUsbKeyboard;
  Input: PInputDevice;
  Name: array[0..15] of Char;
begin
  Result := nil;
  if KeyboardCount = MaximumKeyboards then
    Exit;
  Keyboard := PUsbKeyboard(AllocateZeroedKernelMemory(SizeOf(TUsbKeyboard)));
  if Keyboard = nil then
    Exit;
  CopyText(@Name[0], 'usbkeyboard', SizeOf(Name));
  Name[11] := Char(Ord('0') + KeyboardCount);
  Name[12] := #0;
  Input := CreateKeyboardDevice(@Name[0]);
  if Input = nil then
  begin
    FreeKernelMemory(Keyboard);
    Exit;
  end;
  InitializeKeyboardState(Keyboard^.Keys, Input);
  InitializeSpinLock(Keyboard^.Lock);
  InitializeTimer(Keyboard^.RepeatTimer);
  InitializeDeferredCall(Keyboard^.RepeatCall, @RepeatHeldKey, Keyboard);
  Keyboard^.Lights.Wanted := HidLights(KeyboardLights(Keyboard^.Keys));
  CopyText(@Keyboard^.Lights.Name[0], @Name[0], SizeOf(Keyboard^.Lights.Name));
  RegisterKeyboardLights(@Keyboard^.Lights);
  Keyboards[KeyboardCount] := Keyboard;
  Inc(KeyboardCount);
  AttachConsoleInput(@Name[0]);
  DebugBeginMessage;
  DebugWriteTag('input');
  DebugWrite('USB keyboard ');
  DebugWriteLine(@Name[0]);
  DebugEndMessage;
  Result := Keyboard;
end;

end.
