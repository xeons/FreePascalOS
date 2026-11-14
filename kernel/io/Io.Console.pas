{
  The system console: a character device for user programs.

  Output goes wherever the kernel log goes (serial port and framebuffer).
  Input comes from the serial port for now, with simple line editing:
  characters are echoed, backspace removes the last one, and a line is
  handed to the reader when Enter is pressed. Ctrl-D on an empty line
  reads as end of file.

  The serial port is polled every few milliseconds; an interrupt driven
  keyboard and serial driver will replace that later.
}
unit Io.Console;

{$mode objfpc}
{$pointermath on}

interface

procedure InitializeConsole;

{ The console object that handles refer to. }
function ConsoleObject: Pointer;

procedure WriteToConsole(Source: PByte; ByteCount: QWord);
{ Returns the number of bytes read, 0 at end of file. }
function ReadFromConsole(Destination: PByte; ByteCount: QWord): QWord;

implementation

uses
  Hal.SerialPort,
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

type
  TConsole = record
    InputLock: TMutex;
    Line: array[0..LineCapacity - 1] of Char;
    LineLength: LongWord;
    { Part of a completed line not yet handed to a reader. }
    PendingStart: LongWord;
    PendingLength: LongWord;
  end;
  PConsole = ^TConsole;

var
  ConsoleObjectType: TObjectType;
  TheConsole: PConsole;

procedure InitializeConsole;
begin
  RegisterObjectType(ConsoleObjectType, 'Console', SizeOf(TConsole), nil);
  TheConsole := PConsole(CreateObject(ConsoleObjectType, 'Console'));
  if TheConsole = nil then
    KernelPanic('could not create the console');
  InitializeMutex(TheConsole^.InputLock);
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

function WaitForCharacter: Char;
begin
  while not TryReadSerialCharacter(Result) do
    SleepMilliseconds(PollIntervalMilliseconds);
end;

{ Reads one edited line into the console's line buffer. Returns False
  for end of file. }
function ReadLine: Boolean;
var
  Character: Char;
begin
  TheConsole^.LineLength := 0;
  repeat
    Character := WaitForCharacter;
    case Character of
      KeyCarriageReturn, KeyLineFeed:
        begin
          DebugWriteCharacter(KeyLineFeed);
          TheConsole^.Line[TheConsole^.LineLength] := KeyLineFeed;
          Inc(TheConsole^.LineLength);
          Exit(True);
        end;
      KeyBackspace, KeyDelete:
        if TheConsole^.LineLength > 0 then
        begin
          Dec(TheConsole^.LineLength);
          DebugWrite(#8' '#8);
        end;
      KeyEndOfFile:
        if TheConsole^.LineLength = 0 then
          Exit(False)
        else
          Exit(True);
    else
      if (Character >= ' ') and (TheConsole^.LineLength < LineCapacity - 1) then
      begin
        TheConsole^.Line[TheConsole^.LineLength] := Character;
        Inc(TheConsole^.LineLength);
        DebugWriteCharacter(Character);
      end;
    end;
  until False;
end;

function ReadFromConsole(Destination: PByte; ByteCount: QWord): QWord;
var
  Index: QWord;
begin
  Result := 0;
  if ByteCount = 0 then
    Exit;

  AcquireMutex(TheConsole^.InputLock);
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
