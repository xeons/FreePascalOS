{
  PS/2 keyboard driver.

  The keyboard sits behind the i8042 controller (data port 0x60,
  status/command port 0x64) and interrupts on IRQ 1. The controller's
  translation turns whatever the keyboard sends into scan code set 1:
  one byte per key press, the same byte plus 0x80 on release, and a 0xE0
  prefix for the keys added after the original PC keyboard.

  Key presses become characters for the console, with a US layout:
  Shift and Caps Lock for capitals, Ctrl with a letter for control
  characters (Ctrl-C is 3, Ctrl-D is 4), and the arrow, Home, End and
  Delete keys as the escape sequences a terminal sends (ESC [ A, ...).
  The numeric keypad gives digits.
}
unit Drivers.Ps2Keyboard;

{$mode objfpc}

interface

{ Returns False if there is no controller or no interrupt routing. }
function InitializePs2Keyboard: Boolean;

implementation

uses
  Kernel.Arch.TrapFrame,
  Hal.PortIo,
  Io.InterruptRouting,
  Io.Console,
  Debug.Output;

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

  MaximumWaitIterations = 100000;
  MaximumFlushBytes = 32;

  ScanCodeExtended = $E0;
  ScanCodeReleased = $80;

  ScanLeftShift = $2A;
  ScanRightShift = $36;
  ScanControl = $1D;
  ScanAlt = $38;
  ScanCapsLock = $3A;

  KeyEscape = #27;

  { Set 1 scan codes 0x00-0x39 without and with Shift; #0 for keys that
    give no character. }
  PlainKeys: array[$00..$39] of Char = (
    #0, #27, '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', #8, #9,
    'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o', 'p', '[', ']', #13, #0, 'a', 's',
    'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', '''', '`', #0, '\', 'z', 'x', 'c', 'v',
    'b', 'n', 'm', ',', '.', '/', #0, '*', #0, ' ');
  ShiftedKeys: array[$00..$39] of Char = (
    #0, #27, '!', '@', '#', '$', '%', '^', '&', '*', '(', ')', '_', '+', #8, #9,
    'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}', #13, #0, 'A', 'S',
    'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', '"', '~', #0, '|', 'Z', 'X', 'C', 'V',
    'B', 'N', 'M', '<', '>', '?', #0, '*', #0, ' ');
  { The numeric keypad, 0x47-0x53, with Num Lock on. }
  KeypadKeys: array[$47..$53] of Char = (
    '7', '8', '9', '-', '4', '5', '6', '+', '1', '2', '3', '0', '.');

var
  ShiftPressed: Boolean;
  ControlPressed: Boolean;
  CapsLockOn: Boolean;
  ExtendedPrefix: Boolean;

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

procedure DeliverText(Text: PChar);
begin
  while Text^ <> #0 do
  begin
    DeliverConsoleInput(Text^);
    Inc(Text);
  end;
end;

procedure HandleExtendedKey(Code: Byte);
begin
  case Code of
    $48: DeliverText(KeyEscape + '[A');   { up }
    $50: DeliverText(KeyEscape + '[B');   { down }
    $4D: DeliverText(KeyEscape + '[C');   { right }
    $4B: DeliverText(KeyEscape + '[D');   { left }
    $47: DeliverText(KeyEscape + '[H');   { home }
    $4F: DeliverText(KeyEscape + '[F');   { end }
    $53: DeliverText(KeyEscape + '[3~');  { delete }
    $49: DeliverText(KeyEscape + '[5~');  { page up }
    $51: DeliverText(KeyEscape + '[6~');  { page down }
    $1C: DeliverConsoleInput(#13);        { keypad enter }
    $35: DeliverConsoleInput('/');        { keypad slash }
  end;
end;

procedure HandleScanCode(ScanCode: Byte);
var
  Released: Boolean;
  Code: Byte;
  Character: Char;
  UseShifted: Boolean;
begin
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
    { Right Ctrl is E0 1D; E0 2A/B6 are fake shifts some keys send. }
    if Code = ScanControl then
      ControlPressed := not Released
    else if not Released and (Code <> ScanLeftShift) then
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
    ScanCapsLock:
      begin
        if not Released then
          CapsLockOn := not CapsLockOn;
        Exit;
      end;
  end;
  if Released then
    Exit;

  if (Code >= Low(KeypadKeys)) and (Code <= High(KeypadKeys)) then
  begin
    DeliverConsoleInput(KeypadKeys[Code]);
    Exit;
  end;
  if Code > High(PlainKeys) then
    Exit;

  { Caps Lock works like Shift, for letters only. }
  UseShifted := ShiftPressed;
  if CapsLockOn and (PlainKeys[Code] >= 'a') and (PlainKeys[Code] <= 'z') then
    UseShifted := not UseShifted;
  if UseShifted then
    Character := ShiftedKeys[Code]
  else
    Character := PlainKeys[Code];
  if Character = #0 then
    Exit;
  if ControlPressed then
  begin
    { Ctrl with a letter (or @[\]^_) gives the control character. }
    if (Character >= 'a') and (Character <= 'z') then
      Character := Char(Ord(Character) - Ord('a') + 1)
    else if (Character >= '@') and (Character <= '_') then
      Character := Char(Ord(Character) - Ord('@'))
    else
      Exit;
  end;
  DeliverConsoleInput(Character);
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

function InitializePs2Keyboard: Boolean;
var
  Configuration: Byte;
begin
  Result := False;
  { No controller: the status port floats high. }
  if ReadPortByte(StatusPort) = $FF then
    Exit;

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

  DebugBeginMessage;
  DebugWriteTag('input');
  DebugWriteLine('PS/2 keyboard on IRQ 1');
  DebugEndMessage;
  Result := True;
end;

end.
