{
  The system console: a character device for user programs.

  Output goes wherever the kernel log goes (serial port and framebuffer).
  Input comes from the keyboard and the serial port, with simple line
  editing: characters are echoed, backspace removes the last one, Ctrl-C
  throws the line away, and a line is handed to the reader when Enter is
  pressed. Ctrl-D on an empty line reads as end of file. Escape sequences
  (arrow keys and the like) are ignored while editing a line.

  Input devices hand characters over with DeliverConsoleInput, from their
  interrupt handlers; they go into a ring buffer, and a deferred call wakes
  the reader. Until a serial interrupt handler is connected, the serial
  port is also polled every few milliseconds.
}
unit Io.Console;

{$mode objfpc}
{$pointermath on}

interface

procedure InitializeConsole;

{ The console object that handles refer to. }
function ConsoleObject: Pointer;

procedure WriteToConsole(Source: PByte; ByteCount: QWord);
{ Returns the number of bytes read, 0 at end of file (or when the thread
  is alerted because its process is being ended). }
function ReadFromConsole(Destination: PByte; ByteCount: QWord): QWord;

const
  { Typed characters are shown. }
  ConsoleModeEcho = $01;
  { Input is collected and edited a line at a time; otherwise each
    character is handed to the reader as it arrives. }
  ConsoleModeLineEditing = $02;
  ConsoleDefaultMode = ConsoleModeEcho or ConsoleModeLineEditing;
  ConsoleColumns = 80;
  ConsoleRows = 25;

function GetConsoleMode: LongWord;
procedure SetConsoleMode(Mode: LongWord);

{ Adds a typed character to the console's input. May be called at any
  priority level, typically from an interrupt handler. }
procedure DeliverConsoleInput(Character: Char);
{ Called once the serial port delivers its input by interrupt, so it no
  longer needs polling. }
procedure SetSerialInputInterruptDriven;

implementation

uses
  Hal.SerialPort,
  Kernel.Arch.Cpu,
  Kernel.Threads,
  Kernel.SpinLock,
  Kernel.Events,
  Kernel.DeferredCalls,
  Kernel.Mutex,
  Kernel.Scheduler,
  Kernel.Panic,
  Objects.Manager,
  Debug.Output;

const
  LineCapacity = 1024;
  PollIntervalMilliseconds = 10;
  KeyBackspace = #8;
  KeyDelete = #127;
  KeyEndOfFile = #4;
  KeyCarriageReturn = #13;
  KeyLineFeed = #10;
  KeyInterrupt = #3;
  KeyEscape = #27;
  RingCapacity = 1024;

type
  TConsole = record
    InputLock: TMutex;
    Line: array[0..LineCapacity - 1] of Char;
    LineLength: LongWord;
    { Part of a completed line not yet handed to a reader. }
    PendingStart: LongWord;
    PendingLength: LongWord;
    Mode: LongWord;

    { Typed characters not yet read, filled by interrupt handlers. }
    Ring: array[0..RingCapacity - 1] of Char;
    RingStart: LongWord;
    RingCount: LongWord;
    RingLock: TSpinLock;
    InputAvailable: TEvent;
    WakeReader: TDeferredCall;
    SerialIsInterruptDriven: Boolean;
  end;
  PConsole = ^TConsole;

var
  ConsoleObjectType: TObjectType;
  TheConsole: PConsole;

{ Runs at DispatchLevel, after an interrupt handler delivered input. }
procedure SignalInputAvailable(Context: Pointer);
begin
  SignalEvent(TheConsole^.InputAvailable);
end;

procedure DeliverConsoleInput(Character: Char);
var
  WereEnabled: Boolean;
begin
  if TheConsole = nil then
    Exit;
  WereEnabled := SaveAndDisableInterrupts;
  AcquireSpinLockAtCurrentLevel(TheConsole^.RingLock);
  { When the buffer is full, newer input is dropped. }
  if TheConsole^.RingCount < RingCapacity then
  begin
    TheConsole^.Ring[(TheConsole^.RingStart + TheConsole^.RingCount) mod RingCapacity] := Character;
    Inc(TheConsole^.RingCount);
  end;
  ReleaseSpinLockAtCurrentLevel(TheConsole^.RingLock);
  RestoreInterrupts(WereEnabled);
  QueueDeferredCall(TheConsole^.WakeReader);
end;

function TakeRingCharacter(out Character: Char): Boolean;
var
  WereEnabled: Boolean;
begin
  WereEnabled := SaveAndDisableInterrupts;
  AcquireSpinLockAtCurrentLevel(TheConsole^.RingLock);
  Result := TheConsole^.RingCount > 0;
  if Result then
  begin
    Character := TheConsole^.Ring[TheConsole^.RingStart];
    TheConsole^.RingStart := (TheConsole^.RingStart + 1) mod RingCapacity;
    Dec(TheConsole^.RingCount);
  end
  else
    Character := #0;
  ReleaseSpinLockAtCurrentLevel(TheConsole^.RingLock);
  RestoreInterrupts(WereEnabled);
end;

procedure SetSerialInputInterruptDriven;
begin
  TheConsole^.SerialIsInterruptDriven := True;
end;

procedure InitializeConsole;
begin
  RegisterObjectType(ConsoleObjectType, 'Console', SizeOf(TConsole), nil);
  TheConsole := PConsole(CreateObject(ConsoleObjectType, 'Console'));
  if TheConsole = nil then
    KernelPanic('could not create the console');
  InitializeMutex(TheConsole^.InputLock);
  TheConsole^.Mode := ConsoleDefaultMode;
  InitializeSpinLock(TheConsole^.RingLock);
  InitializeEvent(TheConsole^.InputAvailable, EventKindSynchronization, False);
  InitializeDeferredCall(TheConsole^.WakeReader, @SignalInputAvailable, nil);
end;

function GetConsoleMode: LongWord;
begin
  Result := TheConsole^.Mode;
end;

procedure SetConsoleMode(Mode: LongWord);
begin
  TheConsole^.Mode := Mode and ConsoleDefaultMode;
end;

procedure EchoCharacter(Character: Char);
begin
  if (TheConsole^.Mode and ConsoleModeEcho) <> 0 then
    DebugWriteCharacter(Character);
end;

procedure EchoText(Text: PChar);
begin
  if (TheConsole^.Mode and ConsoleModeEcho) <> 0 then
    DebugWrite(Text);
end;

function ConsoleObject: Pointer;
begin
  Result := TheConsole;
end;

procedure WriteToConsole(Source: PByte; ByteCount: QWord);
var
  Index: QWord;
begin
  DebugBeginMessage;
  Index := 0;
  while Index < ByteCount do
  begin
    DebugWriteCharacter(Char(Source[Index]));
    Inc(Index);
  end;
  DebugEndMessage;
end;

{ Returns False if the thread was alerted while waiting. }
function WaitForCharacter(out Character: Char): Boolean;
var
  Timeout: QWord;
begin
  repeat
    if TakeRingCharacter(Character) then
      Exit(True);
    if not TheConsole^.SerialIsInterruptDriven and TryReadSerialCharacter(Character) then
      Exit(True);
    if TheConsole^.SerialIsInterruptDriven then
      Timeout := InfiniteTimeout
    else
      Timeout := PollIntervalMilliseconds;
    if WaitForEventWithOptions(TheConsole^.InputAvailable, Timeout, True) = WaitAlerted then
      Exit(False);
  until False;
end;

{ Like WaitForCharacter, but only if a character is already there. }
function TryTakeCharacter(out Character: Char): Boolean;
begin
  Result := TakeRingCharacter(Character);
  if not Result and not TheConsole^.SerialIsInterruptDriven then
    Result := TryReadSerialCharacter(Character);
end;

{ Swallows the rest of an escape sequence (after ESC): "[" or "O", then
  parameter bytes, then one final byte in '@'..'~'. Returns False if
  the thread was alerted. }
function SkipEscapeSequence: Boolean;
var
  Character: Char;
begin
  if not WaitForCharacter(Character) then
    Exit(False);
  if (Character <> '[') and (Character <> 'O') then
    Exit(True);
  repeat
    if not WaitForCharacter(Character) then
      Exit(False);
  until (Character >= '@') and (Character <= '~');
  Result := True;
end;

{ Reads one edited line into the console's line buffer. Returns False
  for end of file. }
function ReadLine: Boolean;
var
  Character: Char;
begin
  TheConsole^.LineLength := 0;
  repeat
    if not WaitForCharacter(Character) then
      Exit(False);
    case Character of
      KeyCarriageReturn, KeyLineFeed:
        begin
          EchoCharacter(KeyLineFeed);
          TheConsole^.Line[TheConsole^.LineLength] := KeyLineFeed;
          Inc(TheConsole^.LineLength);
          Exit(True);
        end;
      KeyBackspace, KeyDelete:
        if TheConsole^.LineLength > 0 then
        begin
          Dec(TheConsole^.LineLength);
          EchoText(#8' '#8);
        end;
      KeyEndOfFile:
        if TheConsole^.LineLength = 0 then
          Exit(False)
        else
          Exit(True);
      KeyInterrupt:
        begin
          { Throw the line away and start again. }
          EchoText('^C'#10);
          TheConsole^.LineLength := 0;
        end;
      KeyEscape:
        if not SkipEscapeSequence then
          Exit(False);
    else
      if (Character >= ' ') and (TheConsole^.LineLength < LineCapacity - 1) then
      begin
        TheConsole^.Line[TheConsole^.LineLength] := Character;
        Inc(TheConsole^.LineLength);
        EchoCharacter(Character);
      end;
    end;
  until False;
end;

function ReadFromConsole(Destination: PByte; ByteCount: QWord): QWord;
var
  Index: QWord;
  Character: Char;
begin
  Result := 0;
  if ByteCount = 0 then
    Exit;

  AcquireMutex(TheConsole^.InputLock);
  if (TheConsole^.PendingLength = 0) and ((TheConsole^.Mode and ConsoleModeLineEditing) = 0) then
  begin
    { Character at a time: wait for the first, then take what is there. }
    Result := 0;
    while Result < ByteCount do
    begin
      if Result = 0 then
      begin
        if not WaitForCharacter(Character) then
          Break;
      end
      else if not TryTakeCharacter(Character) then
        Break;
      if Character = KeyCarriageReturn then
        Character := KeyLineFeed;
      EchoCharacter(Character);
      Destination[Result] := Byte(Character);
      Inc(Result);
    end;
    ReleaseMutex(TheConsole^.InputLock);
    Exit;
  end;
  if TheConsole^.PendingLength = 0 then
  begin
    if not ReadLine then
    begin
      ReleaseMutex(TheConsole^.InputLock);
      Exit(0);
    end;
    TheConsole^.PendingStart := 0;
    TheConsole^.PendingLength := TheConsole^.LineLength;
  end;

  Index := 0;
  while (Index < ByteCount) and (TheConsole^.PendingLength > 0) do
  begin
    Destination[Index] := Byte(TheConsole^.Line[TheConsole^.PendingStart]);
    Inc(TheConsole^.PendingStart);
    Dec(TheConsole^.PendingLength);
    Inc(Index);
  end;
  ReleaseMutex(TheConsole^.InputLock);
  Result := Index;
end;

end.
