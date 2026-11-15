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

  The Caps, Num and Scroll Lock lights follow the locks.
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
  Drivers.Ps2Controller;

const
  KeyboardIrq = 1;

  { Commands to the keyboard itself (through the data port), and its
    answers. }
  KeyboardSetLights = $ED;
  KeyboardAcknowledge = $FA;
  KeyboardResend = $FE;

  MaximumFlushBytes = 32;
  LayoutNameCapacity = 16;

  ScanCodeExtended = $E0;
  ScanCodeReleased = $80;

type
  { Setting the lights takes two bytes, each answered by the keyboard;
    the answers arrive as interrupts like key presses. }
  TLightsState = (LightsIdle, LightsAwaitingCommandAnswer, LightsAwaitingValueAnswer);

var
  Keyboard: TKeyboardState;
  ExtendedPrefix: Boolean;
  LightsState: TLightsState;
  { The locks changed while the lights were being set. }
  LightsOutdated: Boolean;
  KeyboardInput: PInputDevice;

procedure SendToKeyboard(Value: Byte);
begin
  Ps2WriteData(Value);
end;

{ --- Lock lights ----------------------------------------------------- }

function LightsValue: Byte;
begin
  Result := KeyboardLights(Keyboard);
end;

{ Starts setting the lights; the rest happens as the keyboard answers. }
procedure UpdateLights;
begin
  if LightsState <> LightsIdle then
  begin
    LightsOutdated := True;
    Exit;
  end;
  LightsOutdated := False;
  LightsState := LightsAwaitingCommandAnswer;
  SendToKeyboard(KeyboardSetLights);
end;

{ Handles an answer of the keyboard; returns False if Value is not one
  (then it is a scan code). }
function HandleKeyboardAnswer(Value: Byte): Boolean;
begin
  Result := False;
  if LightsState = LightsIdle then
    Exit;
  if Value = KeyboardAcknowledge then
  begin
    if LightsState = LightsAwaitingCommandAnswer then
    begin
      LightsState := LightsAwaitingValueAnswer;
      SendToKeyboard(LightsValue);
    end
    else
    begin
      LightsState := LightsIdle;
      if LightsOutdated then
        UpdateLights;
    end;
    Exit(True);
  end;
  if Value = KeyboardResend then
  begin
    { The keyboard did not take the byte: start over. }
    LightsState := LightsIdle;
    UpdateLights;
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
function ConfigureController: Boolean;
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

{ The first port on, and the lights as they should be. }
procedure StartKeyboard;
begin
  Ps2SendCommand(Ps2CommandEnableFirstPort);
  Ps2FlushOutputBuffer;
  LightsState := LightsIdle;
  UpdateLights;
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
