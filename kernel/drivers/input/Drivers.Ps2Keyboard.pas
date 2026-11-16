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
  PS/2 keyboard driver.

  The keyboard sits behind the i8042 controller (data port 0x60,
  status/command port 0x64) and interrupts on IRQ 1. The controller's
  translation turns whatever the keyboard sends into scan code set 1:
  one byte per key press, the same byte plus 0x80 on release, and a 0xE0
  prefix for the keys added after the original PC keyboard.

  Key presses become characters for the console by the layout chosen
  with the kernel option keymap=us|uk|de|fr, as for every keyboard
  (Drivers.KeyboardTranslation: modifiers, locks, dead keys, escape
  sequences for the cursor keys).

  The characters become input of the device /dev/keyboard (a driver
  object "ps2keyboard" with one exclusive device, Io.InputDevice), which
  the console keeps open and reads (Io.ConsoleInput).

  The Caps, Num and Scroll Lock lights follow the locks, and the
  keyboard repeats held keys at the delay and rate the system asks for
  (Drivers.KeyboardRepeat), the nearest its typematic setting has. Both
  are commands of two bytes, each answered by the keyboard as an
  interrupt; one is sent at a time, and a change that comes meanwhile
  waits for it.
}
unit Drivers.Ps2Keyboard;

{$mode objfpc}

interface

{ Keys pressed on the PS/2 keyboard so far. }
function Ps2KeyboardKeyCount: QWord;

{ Returns False if there is no controller or no interrupt routing. }
function InitializePs2Keyboard: Boolean;

implementation

uses
  Io.PowerManagement,
  Kernel.Arch.TrapFrame,
  Kernel.Options,
  Hal.PortIo,
  Io.InterruptRouting,
  Runtime.Memory,
  Io.Manager,
  Io.InputDevice,
  Debug.Output,
  Drivers.KeyboardLayouts,
  Drivers.KeyboardTranslation,
  Drivers.KeyboardRepeat,
  Drivers.Ps2Controller;

const
  KeyboardIrq = 1;

  { Commands to the keyboard itself (through the data port), and its
    answers. }
  KeyboardSetLights = $ED;
  KeyboardSetTypematic = $F3;
  KeyboardAcknowledge = $FA;
  KeyboardResend = $FE;

  MaximumFlushBytes = 32;
  LayoutNameCapacity = 16;

  ScanCodeExtended = $E0;
  ScanCodeReleased = $80;

type
  { Setting the lights or the repeat takes two bytes, each answered by
    the keyboard; the answers arrive as interrupts like key presses. }
  TCommandState = (CommandIdle, CommandAwaitingCommandAnswer, CommandAwaitingValueAnswer);
  TKeyboardCommand = (CommandLights, CommandTypematic);

var
  Keyboard: TKeyboardState;
  ExtendedPrefix: Boolean;
  CommandState: TCommandState;
  CommandBeingSent: TKeyboardCommand;
  { Commands to send once the one under way is answered. }
  LightsOutdated: Boolean;
  TypematicOutdated: Boolean;
  KeyboardInput: PInputDevice;

procedure SendToKeyboard(Value: Byte);
begin
  Ps2WriteData(Value);
end;

{ --- Commands: the lock lights and the repeat ------------------------- }

{ The typematic byte nearest the repeat settings: bits 5-6 the delay
  (250 ms steps from 250), bits 0-4 the rate, whose period is
  (8 + bits 0-2) * 2 ^ bits 3-4 * 4.17 ms (30 to 2 repeats a second). }
function TypematicValue: Byte;
var
  Delay: LongWord;
  Code: LongWord;
  BestCode: LongWord;
  PeriodTimes100: LongWord;
  RateTimes100: LongWord;
  Difference: LongWord;
  BestDifference: LongWord;
  Wanted: LongWord;
begin
  Delay := (KeyRepeatDelay + 125) div 250;
  if Delay < 1 then
    Delay := 1;
  if Delay > 4 then
    Delay := 4;
  Wanted := KeyRepeatRate * 100;
  BestCode := 0;
  BestDifference := High(LongWord);
  for Code := 0 to 31 do
  begin
    PeriodTimes100 := (8 + (Code and 7)) * (LongWord(1) shl ((Code shr 3) and 3)) * 417;
    RateTimes100 := 10000000 div PeriodTimes100;
    if RateTimes100 > Wanted then
      Difference := RateTimes100 - Wanted
    else
      Difference := Wanted - RateTimes100;
    if Difference < BestDifference then
    begin
      BestDifference := Difference;
      BestCode := Code;
    end;
  end;
  Result := Byte(((Delay - 1) shl 5) or BestCode);
end;

function CommandValue: Byte;
begin
  if CommandBeingSent = CommandLights then
    Result := KeyboardLights(Keyboard)
  else
    Result := TypematicValue;
end;

{ Sends the next outdated command if none is under way; the rest happens
  as the keyboard answers. }
procedure SendNextCommand;
begin
  if CommandState <> CommandIdle then
    Exit;
  if LightsOutdated then
  begin
    LightsOutdated := False;
    CommandBeingSent := CommandLights;
    CommandState := CommandAwaitingCommandAnswer;
    SendToKeyboard(KeyboardSetLights);
  end
  else if TypematicOutdated then
  begin
    TypematicOutdated := False;
    CommandBeingSent := CommandTypematic;
    CommandState := CommandAwaitingCommandAnswer;
    SendToKeyboard(KeyboardSetTypematic);
  end;
end;

procedure UpdateLights;
begin
  LightsOutdated := True;
  SendNextCommand;
end;

procedure UpdateTypematic;
begin
  TypematicOutdated := True;
  SendNextCommand;
end;

{ Drivers.KeyboardRepeat's routine, at passive level: in turn with the
  interrupt, which follows the answers. }
procedure KeyRepeatChanged;
begin
  Ps2RunInTurnWithInterrupts(@UpdateTypematic);
end;

{ Handles an answer of the keyboard; returns False if Value is not one
  (then it is a scan code). }
function HandleKeyboardAnswer(Value: Byte): Boolean;
begin
  Result := False;
  if CommandState = CommandIdle then
    Exit;
  if Value = KeyboardAcknowledge then
  begin
    if CommandState = CommandAwaitingCommandAnswer then
    begin
      CommandState := CommandAwaitingValueAnswer;
      SendToKeyboard(CommandValue);
    end
    else
    begin
      CommandState := CommandIdle;
      SendNextCommand;
    end;
    Exit(True);
  end;
  if Value = KeyboardResend then
  begin
    { The keyboard did not take the byte: start that command over. }
    CommandState := CommandIdle;
    if CommandBeingSent = CommandLights then
      LightsOutdated := True
    else
      TypematicOutdated := True;
    SendNextCommand;
    Exit(True);
  end;
end;

procedure HandleScanCode(ScanCode: Byte);
var
  Extended: Boolean;
begin
  if HandleKeyboardAnswer(ScanCode) then
    Exit;
  if ScanCode = ScanCodeExtended then
  begin
    ExtendedPrefix := True;
    Exit;
  end;
  Extended := ExtendedPrefix;
  ExtendedPrefix := False;
  if TranslateKey(Keyboard, ScanCode and not ScanCodeReleased, Extended,
    (ScanCode and ScanCodeReleased) <> 0) then
    UpdateLights;
end;

procedure HandleKeyboardInterrupt(Frame: PTrapFrame; Context: Pointer);
begin
  { Mouse bytes waiting are taken too, for the mouse's driver. }
  Ps2ServiceController;
end;

{ The layout from the keymap option; US if none or unknown. }
procedure ChooseLayout;
var
  Name: array[0..LayoutNameCapacity - 1] of Char;
begin
  SelectKeyboardLayout('us');
  if not GetKernelOptionValue('keymap', @Name[0], LayoutNameCapacity) then
    Exit;
  if not SelectKeyboardLayout(@Name[0]) then
  begin
    DebugBeginMessage;
    DebugWriteTag('input');
    DebugWrite('unknown keymap "');
    DebugWrite(@Name[0]);
    DebugWriteLine('", using us');
    DebugEndMessage;
  end;
end;

function CreateKeyboardDevice: Boolean;
const
  OwnerReadWrite = $180; { rw------- }
var
  Dispatch: TDispatchTable;
  Driver: PDriverObject;
  Device: PDeviceObject;
begin
  FillMemory(@Dispatch, SizeOf(Dispatch), 0);
  Dispatch[IoFunctionRead] := @ReadInputDevice;
  Driver := CreateDriver('ps2keyboard', Dispatch);
  Device := CreateDevice(Driver, 'keyboard', DeviceKindCharacter, OwnerReadWrite,
    SizeOf(TInputDevice));
  if Device = nil then
    Exit(False);
  Device^.IsExclusive := True;
  KeyboardInput := PInputDevice(Device^.Extension);
  InitializeInputDevice(KeyboardInput^);
  InitializeKeyboardState(Keyboard, KeyboardInput);
  Result := True;
end;

function Ps2KeyboardKeyCount: QWord;
begin
  Result := Keyboard.KeyCount;
end;

{ Both ports off, then the first port's interrupt and scan code
  translation on (the second port's off). }
function ConfigureControllerByPolling: Boolean;
var
  Configuration: Byte;
begin
  Result := False;
  Ps2SendCommand(Ps2CommandDisableFirstPort);
  Ps2SendCommand(Ps2CommandDisableSecondPort);
  Ps2FlushOutputBuffer;
  if not Ps2ReadConfiguration(Configuration) then
    Exit;
  Configuration := (Configuration or Ps2ConfigurationFirstPortInterrupt or Ps2ConfigurationTranslation) and
    not Ps2ConfigurationSecondPortInterrupt;
  Ps2WriteConfiguration(Configuration);
  Result := True;
end;

function ConfigureController: Boolean;
begin
  Ps2BeginPolling;
  Result := ConfigureControllerByPolling;
  Ps2EndPolling;
end;

{ The first port on, and the lights as they should be. }
procedure StartKeyboard;
begin
  Ps2SendCommand(Ps2CommandEnableFirstPort);
  Ps2FlushOutputBuffer;
  CommandState := CommandIdle;
  LightsOutdated := True;
  TypematicOutdated := True;
  Ps2RunInTurnWithInterrupts(@SendNextCommand);
end;

{ Waking from suspend to RAM reset the controller. }
procedure ResumeKeyboard(Context: Pointer);
begin
  if ConfigureController then
    StartKeyboard;
end;

function InitializePs2Keyboard: Boolean;
begin
  Result := False;
  if not Ps2ControllerIsPresent then
    Exit;
  ChooseLayout;

  if not ConfigureController then
    Exit;
  if not CreateKeyboardDevice then
    Exit;
  SetPs2KeyboardRoutine(@HandleScanCode);
  SetKeyRepeatChangedRoutine(@KeyRepeatChanged);
  if not ConnectIsaInterrupt(KeyboardIrq, @HandleKeyboardInterrupt, nil) then
    Exit;
  StartKeyboard;
  RegisterPowerHandler('PS/2 keyboard', PowerStageDevices, nil, @ResumeKeyboard, nil);

  DebugBeginMessage;
  DebugWriteTag('input');
  DebugWrite('PS/2 keyboard on IRQ 1, layout ');
  DebugWriteLine(CurrentKeyboardLayoutName);
  DebugEndMessage;
  Result := True;
end;

end.
