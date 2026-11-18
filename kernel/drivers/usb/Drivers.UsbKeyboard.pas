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
  reads like the PS/2 keyboard. Keys do not repeat while held, and the
  lock lights stay off.
}
unit Drivers.UsbKeyboard;

{$mode objfpc}
{$pointermath on}

interface

uses
  Drivers.HidReports,
  Drivers.KeyboardTranslation;

type
  PUsbKeyboard = ^TUsbKeyboard;
  TUsbKeyboard = record
    Keys: TKeyboardState;
    Previous: TBootKeyboardReport;
  end;

{ A new keyboard with its input device (usbkeyboardN), attached to the
  console; nil if there are too many already. }
function CreateUsbKeyboard: PUsbKeyboard;
{ A report from the keyboard, in the boot protocol's form (called at
  dispatch level). }
procedure HandleUsbKeyboardReport(Keyboard: PUsbKeyboard; const Report: TBootKeyboardReport);
{ Every key counts as released (after waking from suspend to RAM). }
procedure ResetUsbKeyboard(Keyboard: PUsbKeyboard);
{ Keys pressed on every USB keyboard so far. }
function UsbKeyboardKeyCount: QWord;

implementation

uses
  Runtime.Memory,
  Runtime.Text,
  Memory.KernelHeap,
  Io.Manager,
  Io.InputDevice,
  Io.ConsoleInput,
  Debug.Output;

const
  MaximumKeyboards = 4;
  Extended = $100;

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

procedure SendKey(Keyboard: PUsbKeyboard; ScanCode: Word; Released: Boolean);
begin
  if ScanCode <> 0 then
    TranslateKey(Keyboard^.Keys, Byte(ScanCode), (ScanCode and Extended) <> 0, Released);
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
begin
  { Too many keys at once: the keyboard cannot tell which. }
  if Report[2] = KeyUsageErrorRollOver then
    Exit;
  for Bit := 0 to 7 do
    if ((Report[0] xor Keyboard^.Previous[0]) and (1 shl Bit)) <> 0 then
      SendKey(Keyboard, ModifierScanCodes[Bit], (Report[0] and (1 shl Bit)) = 0);
  for Index := 2 to BootKeyboardReportSize - 1 do
  begin
    Usage := Keyboard^.Previous[Index];
    if (Usage <= High(UsageToScanCode)) and (Usage <> 0) and not ReportHolds(Report, Usage) then
      SendKey(Keyboard, UsageToScanCode[Usage], True);
  end;
  for Index := 2 to BootKeyboardReportSize - 1 do
  begin
    Usage := Report[Index];
    if (Usage <= High(UsageToScanCode)) and (Usage <> 0) and not ReportHolds(Keyboard^.Previous, Usage) then
      SendKey(Keyboard, UsageToScanCode[Usage], False);
  end;
  Keyboard^.Previous := Report;
end;

procedure ResetUsbKeyboard(Keyboard: PUsbKeyboard);
begin
  FillMemory(@Keyboard^.Previous[0], SizeOf(Keyboard^.Previous), 0);
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
