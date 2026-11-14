{
  PS/2 keyboard driver.

  The keyboard sits behind the i8042 controller (data port 0x60,
  status/command port 0x64) and interrupts on IRQ 1. The controller's
  translation turns whatever the keyboard sends into scan code set 1:
  one byte per key press, the same byte plus 0x80 on release, and a 0xE0
  prefix for the keys added after the original PC keyboard.

  Key presses become characters for the console, by the layout chosen
  with the kernel option keymap=us|uk|de|fr (Drivers.KeyboardLayouts):
  Shift and Caps Lock for capitals, AltGr (the right Alt key) for the
  third character of a key, Ctrl with a letter for control characters
  (Ctrl-C is 3, Ctrl-D is 4), and the arrow, Home, End, Insert and Delete
  keys as the escape sequences a terminal sends (ESC [ A, ...).
  Characters beyond ASCII are sent in UTF-8.

  With Num Lock on the numeric keypad gives digits, with it off the
  cursor and editing keys printed on it. The Caps, Num and Scroll Lock
  lights follow the locks.
}
unit Drivers.Ps2Keyboard;

{$mode objfpc}

interface

{ Returns False if there is no controller or no interrupt routing. }
function InitializePs2Keyboard: Boolean;

implementation

uses
  Kernel.Arch.TrapFrame,
  Kernel.Options,
  Hal.PortIo,
  Io.InterruptRouting,
  Io.Console,
  Debug.Output,
  Drivers.KeyboardLayouts;

const
  KeyboardIrq = 1;

  DataPort = $60;
  StatusPort = $64;
  CommandPort = $64;

  StatusOutputFull = $01;
  StatusInputFull = $02;
  { The byte in the output buffer came from the mouse port. }
  StatusFromAuxiliary = $20;

  CommandReadConfiguration = $20;
  CommandWriteConfiguration = $60;
  CommandDisableSecondPort = $A7;
  CommandDisableFirstPort = $AD;
  CommandEnableFirstPort = $AE;

  ConfigurationFirstPortInterrupt = $01;
  ConfigurationSecondPortInterrupt = $02;
  ConfigurationTranslation = $40;

  { Commands to the keyboard itself (through the data port), and its
    answers. }
  KeyboardSetLights = $ED;
  KeyboardAcknowledge = $FA;
  KeyboardResend = $FE;

  LightScrollLock = $01;
  LightNumLock = $02;
  LightCapsLock = $04;

  MaximumWaitIterations = 100000;
  MaximumFlushBytes = 32;
  LayoutNameCapacity = 16;

  ScanCodeExtended = $E0;
  ScanCodeReleased = $80;

  ScanLeftShift = $2A;
  ScanRightShift = $36;
  ScanControl = $1D;
  ScanAlt = $38;
  ScanCapsLock = $3A;
  ScanNumLock = $45;
  ScanScrollLock = $46;
  ScanFirstKeypad = $47;
  ScanLastKeypad = $53;

  KeyEscape = #27;

  { The numeric keypad, 0x47-0x53, with Num Lock on. }
  KeypadDigits: array[ScanFirstKeypad..ScanLastKeypad] of Char = (
    '7', '8', '9', '-', '4', '5', '6', '+', '1', '2', '3', '0', '.');

type
  { Setting the lights takes two bytes, each answered by the keyboard;
    the answers arrive as interrupts like key presses. }
  TLightsState = (LightsIdle, LightsAwaitingCommandAnswer, LightsAwaitingValueAnswer);

var
  ShiftPressed: Boolean;
  ControlPressed: Boolean;
  AltGrPressed: Boolean;
  CapsLockOn: Boolean;
  NumLockOn: Boolean;
  ScrollLockOn: Boolean;
  ExtendedPrefix: Boolean;
  LightsState: TLightsState;
  { The locks changed while the lights were being set. }
  LightsOutdated: Boolean;

function WaitUntilWritable: Boolean;
var
  Iteration: LongWord;
begin
  for Iteration := 1 to MaximumWaitIterations do
    if (ReadPortByte(StatusPort) and StatusInputFull) = 0 then
      Exit(True);
  Result := False;
end;

function WaitUntilReadable: Boolean;
var
  Iteration: LongWord;
begin
  for Iteration := 1 to MaximumWaitIterations do
    if (ReadPortByte(StatusPort) and StatusOutputFull) <> 0 then
      Exit(True);
  Result := False;
end;

procedure SendCommand(Command: Byte);
begin
  WaitUntilWritable;
  WritePortByte(CommandPort, Command);
end;

procedure SendToKeyboard(Value: Byte);
begin
  WaitUntilWritable;
  WritePortByte(DataPort, Value);
end;

procedure FlushOutputBuffer;
var
  Count: Integer;
begin
  Count := 0;
  while ((ReadPortByte(StatusPort) and StatusOutputFull) <> 0) and (Count < MaximumFlushBytes) do
  begin
    ReadPortByte(DataPort);
    Inc(Count);
  end;
end;

{ --- Lock lights ----------------------------------------------------- }

function LightsValue: Byte;
begin
  Result := 0;
  if ScrollLockOn then
    Result := Result or LightScrollLock;
  if NumLockOn then
    Result := Result or LightNumLock;
  if CapsLockOn then
    Result := Result or LightCapsLock;
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

{ --- Characters ------------------------------------------------------ }

procedure DeliverText(Text: PChar);
begin
  while Text^ <> #0 do
  begin
    DeliverConsoleInput(Text^);
    Inc(Text);
  end;
end;

{ Sends a code point to the console in UTF-8. }
procedure DeliverCodePoint(CodePoint: LongWord);
begin
  if CodePoint < $80 then
    DeliverConsoleInput(Char(CodePoint))
  else if CodePoint < $800 then
  begin
    DeliverConsoleInput(Char($C0 or (CodePoint shr 6)));
    DeliverConsoleInput(Char($80 or (CodePoint and $3F)));
  end
  else
  begin
    DeliverConsoleInput(Char($E0 or (CodePoint shr 12)));
    DeliverConsoleInput(Char($80 or ((CodePoint shr 6) and $3F)));
    DeliverConsoleInput(Char($80 or (CodePoint and $3F)));
  end;
end;

{ The cursor and editing keys, from the separate block (after E0) or
  from the keypad with Num Lock off. }
procedure DeliverEditingKey(Code: Byte);
begin
  case Code of
    $48: DeliverText(KeyEscape + '[A');   { up }
    $50: DeliverText(KeyEscape + '[B');   { down }
    $4D: DeliverText(KeyEscape + '[C');   { right }
    $4B: DeliverText(KeyEscape + '[D');   { left }
    $47: DeliverText(KeyEscape + '[H');   { home }
    $4F: DeliverText(KeyEscape + '[F');   { end }
    $52: DeliverText(KeyEscape + '[2~');  { insert }
    $53: DeliverText(KeyEscape + '[3~');  { delete }
    $49: DeliverText(KeyEscape + '[5~');  { page up }
    $51: DeliverText(KeyEscape + '[6~');  { page down }
  end;
end;

procedure HandleExtendedKey(Code: Byte);
begin
  case Code of
    $1C: DeliverConsoleInput(#13);        { keypad enter }
    $35: DeliverConsoleInput('/');        { keypad slash }
  else
    DeliverEditingKey(Code);
  end;
end;

procedure HandleKeypadKey(Code: Byte);
begin
  { Minus and plus are the same either way. }
  if NumLockOn or (KeypadDigits[Code] = '-') or (KeypadDigits[Code] = '+') then
    DeliverConsoleInput(KeypadDigits[Code])
  else
    DeliverEditingKey(Code);
end;

procedure HandleCharacterKey(Code: Byte);
var
  CodePoint: LongWord;
  UseShifted: Boolean;
begin
  CodePoint := 0;
  if AltGrPressed then
    CodePoint := LayoutCharacter(Code, LevelAltGr);
  if CodePoint = 0 then
  begin
    { Caps Lock works like Shift, for letters only. }
    UseShifted := ShiftPressed;
    if CapsLockOn and KeyIsCapsLockable(Code) then
      UseShifted := not UseShifted;
    if UseShifted then
      CodePoint := LayoutCharacter(Code, LevelShifted)
    else
      CodePoint := LayoutCharacter(Code, LevelPlain);
  end;
  if CodePoint = 0 then
    Exit;
  if ControlPressed then
  begin
    { Ctrl with a letter (or @[\]^_) gives the control character. }
    if (CodePoint >= Ord('a')) and (CodePoint <= Ord('z')) then
      CodePoint := CodePoint - Ord('a') + 1
    else if (CodePoint >= Ord('@')) and (CodePoint <= Ord('_')) then
      CodePoint := CodePoint - Ord('@')
    else
      Exit;
  end;
  DeliverCodePoint(CodePoint);
end;

procedure HandleScanCode(ScanCode: Byte);
var
  Released: Boolean;
  Code: Byte;
begin
  if HandleKeyboardAnswer(ScanCode) then
    Exit;
  if ScanCode = ScanCodeExtended then
  begin
    ExtendedPrefix := True;
    Exit;
  end;
  Released := (ScanCode and ScanCodeReleased) <> 0;
  Code := ScanCode and not ScanCodeReleased;

  if ExtendedPrefix then
  begin
    ExtendedPrefix := False;
    { Right Ctrl is E0 1D, AltGr E0 38; E0 2A/B6 are fake shifts some
      keys send. }
    if Code = ScanControl then
      ControlPressed := not Released
    else if Code = ScanAlt then
      AltGrPressed := not Released
    else if not Released and (Code <> ScanLeftShift) and (Code <> ScanRightShift) then
      HandleExtendedKey(Code);
    Exit;
  end;

  case Code of
    ScanLeftShift, ScanRightShift:
      begin
        ShiftPressed := not Released;
        Exit;
      end;
    ScanControl:
      begin
        ControlPressed := not Released;
        Exit;
      end;
    ScanAlt:
      Exit;
    ScanCapsLock, ScanNumLock, ScanScrollLock:
      begin
        if Released then
          Exit;
        case Code of
          ScanCapsLock: CapsLockOn := not CapsLockOn;
          ScanNumLock: NumLockOn := not NumLockOn;
        else
          ScrollLockOn := not ScrollLockOn;
        end;
        UpdateLights;
        Exit;
      end;
  end;
  if Released then
    Exit;

  if (Code >= ScanFirstKeypad) and (Code <= ScanLastKeypad) then
    HandleKeypadKey(Code)
  else
    HandleCharacterKey(Code);
end;

procedure HandleKeyboardInterrupt(Frame: PTrapFrame; Context: Pointer);
var
  Status: Byte;
  Count: Integer;
begin
  Count := 0;
  repeat
    Status := ReadPortByte(StatusPort);
    if (Status and StatusOutputFull) = 0 then
      Break;
    if (Status and StatusFromAuxiliary) <> 0 then
      ReadPortByte(DataPort) { mouse data: not ours }
    else
      HandleScanCode(ReadPortByte(DataPort));
    Inc(Count);
  until Count >= MaximumFlushBytes;
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

function InitializePs2Keyboard: Boolean;
var
  Configuration: Byte;
begin
  Result := False;
  { No controller: the status port floats high. }
  if ReadPortByte(StatusPort) = $FF then
    Exit;
  ChooseLayout;

  SendCommand(CommandDisableFirstPort);
  SendCommand(CommandDisableSecondPort);
  FlushOutputBuffer;

  SendCommand(CommandReadConfiguration);
  if not WaitUntilReadable then
    Exit;
  Configuration := ReadPortByte(DataPort);
  Configuration := (Configuration or ConfigurationFirstPortInterrupt or ConfigurationTranslation) and
    not ConfigurationSecondPortInterrupt;
  SendCommand(CommandWriteConfiguration);
  WaitUntilWritable;
  WritePortByte(DataPort, Configuration);

  if not ConnectIsaInterrupt(KeyboardIrq, @HandleKeyboardInterrupt, nil) then
    Exit;
  SendCommand(CommandEnableFirstPort);
  FlushOutputBuffer;

  { Num Lock starts on, as most firmware leaves it. }
  NumLockOn := True;
  LightsState := LightsIdle;
  UpdateLights;

  DebugBeginMessage;
  DebugWriteTag('input');
  DebugWrite('PS/2 keyboard on IRQ 1, layout ');
  DebugWriteLine(CurrentKeyboardLayoutName);
  DebugEndMessage;
  Result := True;
end;

end.
