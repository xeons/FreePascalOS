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
  The line discipline: what makes a character device a terminal. The
  system console (Io.Console) and every pseudo-terminal
  (Io.PseudoTerminals) have one, so programs see the same behaviour on
  both.

  Typed characters arrive in a ring (DeliverTerminalInput from any
  level, dropping what does not fit; WriteTerminalInput from a thread,
  waiting while there is no room). A reader takes them in one of two modes:

    * line editing (cooked): characters are echoed, Backspace removes
      the last character, Ctrl-C (when it reaches the reader) throws the
      line away, and the line is handed out when Enter is pressed;
      Ctrl-D on an empty line reads as end of file. Escape sequences
      (arrow keys and the like) are ignored while editing a line;
    * character at a time (raw): each character is handed out as it
      arrives, Enter as a line feed, echoed if echo is on.

  With the interrupt key mode on, Ctrl-C and Ctrl-Z never reach the
  ring: the terminal notes them and wakes the signal thread
  (Io.TerminalSignals), which ends or stops the terminal's foreground
  group and then calls FinishTerminalInterrupt or FinishTerminalSuspend
  here - or, when it ended nobody, PassInterruptToTerminalReader, which
  hands Ctrl-C to the reader and remembers it as pending for a program
  that asks between commands (TakePendingTerminalInterrupt).

  Hanging up (a pseudo-terminal's master closed) ends the input: readers
  get end of file, and the signal thread ends the processes the
  terminal controls.

  The terminal also keeps its window size, which whoever draws it sets
  (the console's is fixed; a terminal window tells its pseudo-terminal)
  and programs ask for; there is no notification when it changes, so
  programs ask whenever they lay something out (the shell's line editor
  does before every line).

  Echo and the "^C" after an interrupt go to the terminal's ShowOutput
  routine: the kernel's debug output for the console, the master's
  output buffer for a pseudo-terminal. For waiting on handles, Readable
  is kept signaled while a read would not wait, and InputRoom while a
  character written to the input would not wait.
}
unit Io.LineDiscipline;

{$mode objfpc}
{$pointermath on}

interface

uses
  Kernel.SpinLock,
  Kernel.Events,
  Kernel.DeferredCalls,
  Kernel.Mutex;

const
  TerminalLineCapacity = 1024;
  TerminalRingCapacity = 1024;
  DefaultTerminalColumns = 80;
  DefaultTerminalRows = 25;
  { ReadFromTerminal and WriteTerminalInput: the wait was cut short by an
    alert (the process is being ended or stopped) before anything moved. }
  TerminalTransferInterrupted = -1;

type
  TTerminalSignal = (TerminalSignalInterrupt, TerminalSignalSuspend, TerminalSignalHangUp, TerminalSignalResize);

  PLineDiscipline = ^TLineDiscipline;
  { Shows Count bytes of Text to whoever looks at the terminal. Called
    from threads; must not wait long. }
  TTerminalOutputRoutine = procedure(Terminal: PLineDiscipline; Text: PChar; Count: LongWord);
  { Takes a character from an input source that has to be polled;
    False if none is there. }
  TTerminalPollRoutine = function(Terminal: PLineDiscipline; out Character: Char): Boolean;

  TLineDiscipline = record
    ShowOutput: TTerminalOutputRoutine;
    { nil when no input source needs polling. }
    PollInput: TTerminalPollRoutine;
    PollIntervalMilliseconds: QWord;
    { The console or the pseudo-terminal this belongs to. }
    Owner: Pointer;
    { The pseudo-terminal's number (/dev/ptsN); -1 for the console. }
    Number: LongInt;

    { Held by the reader, while it edits a line or takes characters. }
    InputLock: TMutex;
    Line: array[0..TerminalLineCapacity - 1] of Char;
    LineLength: LongWord;
    { Part of a completed line not yet handed to a reader. }
    PendingStart: LongWord;
    PendingLength: LongWord;
    Mode: LongWord;
    Rows: LongWord;
    Columns: LongWord;
    { The process group that Ctrl-C ends and Ctrl-Z stops (0 = none). }
    ForegroundGroup: QWord;

    { Typed characters not yet read. }
    Ring: array[0..TerminalRingCapacity - 1] of Char;
    RingStart: LongWord;
    RingCount: LongWord;
    RingLock: TSpinLock;
    InputAvailable: TEvent;
    WakeReader: TDeferredCall;
    { Ctrl-C was passed to the reader and not yet taken. }
    PendingInterrupt: Boolean;
    { Not yet seen by the signal thread (under RingLock). }
    InterruptKeyPressed: Boolean;
    SuspendKeyPressed: Boolean;
    HangUpPending: Boolean;
    HungUp: Boolean;
    { The size changed: the foreground group is told (programs that
      selected NotifyTerminalResized). }
    ResizePending: Boolean;

    { Kept in step under ReadinessLock, so that two updates at once
      cannot leave them set the wrong way. }
    Readable: TEvent;
    InputRoom: TEvent;
    ReadinessLock: TSpinLock;
  end;

{ Sets up a terminal in the default mode and size, and registers it
  for signals. }
procedure InitializeLineDiscipline(out Terminal: TLineDiscipline; Number: LongInt; Owner: Pointer;
  ShowOutput: TTerminalOutputRoutine);
{ Makes a terminal nobody uses any more as good as new (a reused
  pseudo-terminal). }
procedure ResetLineDiscipline(var Terminal: TLineDiscipline);

{ Adds a typed character; dropped if the ring is full. Any level. }
procedure DeliverTerminalInput(var Terminal: TLineDiscipline; Character: Char);
{ Adds up to Count characters, waiting (alertably) for room while none
  fits; once some went in, stops where the ring is full. PassiveLevel.
  Returns how many were added, TerminalTransferInterrupted, or 0 once the
  terminal is hung up. }
function WriteTerminalInput(var Terminal: TLineDiscipline; Source: PByte; Count: QWord): Int64;

{ Returns the number of bytes read, 0 at end of file (or once hung up),
  or TerminalTransferInterrupted. }
function ReadFromTerminal(var Terminal: TLineDiscipline; Destination: PByte; Count: QWord): Int64;

function GetTerminalMode(var Terminal: TLineDiscipline): LongWord;
procedure SetTerminalMode(var Terminal: TLineDiscipline; Mode: LongWord);
procedure SetTerminalSize(var Terminal: TLineDiscipline; Rows, Columns: LongWord);
procedure SetTerminalForegroundGroup(var Terminal: TLineDiscipline; GroupId: QWord);

{ For the signal thread: takes one thing that happened (Ctrl-C first,
  then Ctrl-Z, then a hang-up, then a new size); False if nothing did. }
function TakeTerminalSignal(var Terminal: TLineDiscipline; out Signal: TTerminalSignal): Boolean;
{ After Ctrl-C ended programs: shows "^C" and forgets typed input. }
procedure FinishTerminalInterrupt(var Terminal: TLineDiscipline);
{ After Ctrl-Z stopped programs: shows "^Z". }
procedure FinishTerminalSuspend(var Terminal: TLineDiscipline);
{ When nobody was ended, the reader gets Ctrl-C as a character. }
procedure PassInterruptToTerminalReader(var Terminal: TLineDiscipline);
{ A program busy with something else than reading (the shell running a
  loop of builtins) asks whether Ctrl-C was passed to it: True once per
  key press, and the Ctrl-C character leaves the input. }
function TakePendingTerminalInterrupt(var Terminal: TLineDiscipline): Boolean;

{ Ends the input for good: readers get end of file, writers of input
  are let go, and the signal thread hears of it. }
procedure HangUpTerminal(var Terminal: TLineDiscipline);

implementation

uses
  Abi.SystemCalls,
  Kernel.Arch.Cpu,
  Kernel.PriorityLevel,
  Kernel.Threads,
  Kernel.Scheduler,
  Io.TerminalSignals;

const
  KeyBackspace = #8;
  KeyDelete = #127;
  KeyEndOfFile = #4;
  KeyCarriageReturn = #13;
  KeyLineFeed = #10;
  KeyInterrupt = #3;
  KeySuspend = #26;
  KeyEscape = #27;
  TerminalDefaultMode = ConsoleModeEcho or ConsoleModeLineEditing or ConsoleModeInterruptKey;

type
  TCharacterWait = (CharacterArrived, CharacterWaitAlerted, CharacterWaitHungUp);
  TLineResult = (LineReady, LineEndOfFile, LineInterrupted);

{ --- The ring and readiness -------------------------------------------- }

{ Whether the typed input holds something a read hands out without
  waiting: any character, or in line editing mode a whole line (or
  Ctrl-D). RingLock held. }
function RingHoldsReadableInputLocked(var Terminal: TLineDiscipline): Boolean;
var
  Index: LongWord;
  Character: Char;
begin
  if (Terminal.Mode and ConsoleModeLineEditing) = 0 then
    Exit(Terminal.RingCount > 0);
  Index := 0;
  while Index < Terminal.RingCount do
  begin
    Character := Terminal.Ring[(Terminal.RingStart + Index) mod TerminalRingCapacity];
    if (Character = KeyCarriageReturn) or (Character = KeyLineFeed) or (Character = KeyEndOfFile) then
      Exit(True);
    Inc(Index);
  end;
  Result := False;
end;

{ Brings Readable and InputRoom in step with the input. At PassiveLevel
  or DispatchLevel, after the input changed. }
procedure UpdateTerminalReadiness(var Terminal: TLineDiscipline);
var
  PreviousLevel: TPriorityLevel;
  WereEnabled: Boolean;
  IsReadable: Boolean;
  HasRoom: Boolean;
begin
  PreviousLevel := AcquireSpinLock(Terminal.ReadinessLock);
  WereEnabled := SaveAndDisableInterrupts;
  AcquireSpinLockAtCurrentLevel(Terminal.RingLock);
  IsReadable := Terminal.HungUp or (Terminal.PendingLength > 0) or RingHoldsReadableInputLocked(Terminal);
  HasRoom := Terminal.HungUp or (Terminal.RingCount < TerminalRingCapacity);
  ReleaseSpinLockAtCurrentLevel(Terminal.RingLock);
  RestoreInterrupts(WereEnabled);
  if IsReadable then
    SignalEvent(Terminal.Readable)
  else
    ResetEvent(Terminal.Readable);
  if HasRoom then
    SignalEvent(Terminal.InputRoom)
  else
    ResetEvent(Terminal.InputRoom);
  ReleaseSpinLock(Terminal.ReadinessLock, PreviousLevel);
end;

{ Runs at DispatchLevel, after input was delivered. }
procedure SignalInputAvailable(Context: Pointer);
var
  Terminal: PLineDiscipline;
begin
  Terminal := PLineDiscipline(Context);
  SignalEvent(Terminal^.InputAvailable);
  UpdateTerminalReadiness(Terminal^);
end;

{ Adds a character to the ring if there is room. Any level. }
function AddToRing(var Terminal: TLineDiscipline; Character: Char): Boolean;
var
  WereEnabled: Boolean;
begin
  WereEnabled := SaveAndDisableInterrupts;
  AcquireSpinLockAtCurrentLevel(Terminal.RingLock);
  Result := Terminal.RingCount < TerminalRingCapacity;
  if Result then
  begin
    Terminal.Ring[(Terminal.RingStart + Terminal.RingCount) mod TerminalRingCapacity] := Character;
    Inc(Terminal.RingCount);
  end;
  ReleaseSpinLockAtCurrentLevel(Terminal.RingLock);
  RestoreInterrupts(WereEnabled);
end;

function TakeRingCharacter(var Terminal: TLineDiscipline; out Character: Char): Boolean;
var
  WereEnabled: Boolean;
begin
  WereEnabled := SaveAndDisableInterrupts;
  AcquireSpinLockAtCurrentLevel(Terminal.RingLock);
  Result := Terminal.RingCount > 0;
  if Result then
  begin
    Character := Terminal.Ring[Terminal.RingStart];
    Terminal.RingStart := (Terminal.RingStart + 1) mod TerminalRingCapacity;
    Dec(Terminal.RingCount);
    { The reader got the Ctrl-C itself; it is no longer pending. }
    if Character = KeyInterrupt then
      Terminal.PendingInterrupt := False;
  end
  else
    Character := #0;
  ReleaseSpinLockAtCurrentLevel(Terminal.RingLock);
  RestoreInterrupts(WereEnabled);
end;

procedure ClearRing(var Terminal: TLineDiscipline);
var
  WereEnabled: Boolean;
begin
  WereEnabled := SaveAndDisableInterrupts;
  AcquireSpinLockAtCurrentLevel(Terminal.RingLock);
  Terminal.RingCount := 0;
  ReleaseSpinLockAtCurrentLevel(Terminal.RingLock);
  RestoreInterrupts(WereEnabled);
end;

{ --- Setting up ---------------------------------------------------------- }

procedure InitializeLineDiscipline(out Terminal: TLineDiscipline; Number: LongInt; Owner: Pointer;
  ShowOutput: TTerminalOutputRoutine);
begin
  Terminal.ShowOutput := ShowOutput;
  Terminal.PollInput := nil;
  Terminal.PollIntervalMilliseconds := 0;
  Terminal.Owner := Owner;
  Terminal.Number := Number;
  InitializeMutex(Terminal.InputLock);
  InitializeSpinLock(Terminal.RingLock);
  InitializeSpinLock(Terminal.ReadinessLock);
  InitializeEvent(Terminal.InputAvailable, EventKindSynchronization, False);
  InitializeDeferredCall(Terminal.WakeReader, @SignalInputAvailable, @Terminal);
  InitializeEvent(Terminal.Readable, EventKindNotification, False);
  InitializeEvent(Terminal.InputRoom, EventKindNotification, True);
  ResetLineDiscipline(Terminal);
  RegisterSignalTerminal(@Terminal);
end;

procedure ResetLineDiscipline(var Terminal: TLineDiscipline);
var
  WereEnabled: Boolean;
begin
  WereEnabled := SaveAndDisableInterrupts;
  AcquireSpinLockAtCurrentLevel(Terminal.RingLock);
  Terminal.RingStart := 0;
  Terminal.RingCount := 0;
  Terminal.PendingInterrupt := False;
  Terminal.InterruptKeyPressed := False;
  Terminal.SuspendKeyPressed := False;
  Terminal.HangUpPending := False;
  Terminal.HungUp := False;
  Terminal.ResizePending := False;
  ReleaseSpinLockAtCurrentLevel(Terminal.RingLock);
  RestoreInterrupts(WereEnabled);
  Terminal.LineLength := 0;
  Terminal.PendingStart := 0;
  Terminal.PendingLength := 0;
  Terminal.Mode := TerminalDefaultMode;
  Terminal.Rows := DefaultTerminalRows;
  Terminal.Columns := DefaultTerminalColumns;
  Terminal.ForegroundGroup := 0;
  ResetEvent(Terminal.InputAvailable);
  UpdateTerminalReadiness(Terminal);
end;

{ --- Input ---------------------------------------------------------------- }

{ Ctrl-C or Ctrl-Z while the interrupt key mode is on: noted for the
  signal thread instead of read. Returns False for any other character. }
function NoteSignalKey(var Terminal: TLineDiscipline; Character: Char): Boolean;
var
  WereEnabled: Boolean;
begin
  if not (Character in [KeyInterrupt, KeySuspend]) or
     ((Terminal.Mode and ConsoleModeInterruptKey) = 0) then
    Exit(False);
  WereEnabled := SaveAndDisableInterrupts;
  AcquireSpinLockAtCurrentLevel(Terminal.RingLock);
  if Character = KeyInterrupt then
    Terminal.InterruptKeyPressed := True
  else
    Terminal.SuspendKeyPressed := True;
  ReleaseSpinLockAtCurrentLevel(Terminal.RingLock);
  RestoreInterrupts(WereEnabled);
  RaiseTerminalSignal;
  Result := True;
end;

procedure DeliverTerminalInput(var Terminal: TLineDiscipline; Character: Char);
begin
  if NoteSignalKey(Terminal, Character) then
    Exit;
  { When the ring is full, newer input is dropped. }
  AddToRing(Terminal, Character);
  QueueDeferredCall(Terminal.WakeReader);
end;

function WriteTerminalInput(var Terminal: TLineDiscipline; Source: PByte; Count: QWord): Int64;
var
  Written: QWord;
  Character: Char;
begin
  Written := 0;
  while Written < Count do
  begin
    if Terminal.HungUp then
      Break;
    Character := Char(Source[Written]);
    if NoteSignalKey(Terminal, Character) or AddToRing(Terminal, Character) then
    begin
      Inc(Written);
      Continue;
    end;
    { Full: what went in is enough (the writer, waiting for room on its
      handle, need never block); otherwise let the reader in and wait
      until it took something. }
    if Written > 0 then
      Break;
    SignalEvent(Terminal.InputAvailable);
    UpdateTerminalReadiness(Terminal);
    if WaitForEventWithOptions(Terminal.InputRoom, InfiniteTimeout, True) = WaitAlerted then
    begin
      if Written = 0 then
        Exit(TerminalTransferInterrupted);
      Break;
    end;
  end;
  SignalEvent(Terminal.InputAvailable);
  UpdateTerminalReadiness(Terminal);
  Result := Int64(Written);
end;

{ --- Showing -------------------------------------------------------------- }

procedure ShowText(var Terminal: TLineDiscipline; Text: PChar; Count: LongWord);
begin
  Terminal.ShowOutput(@Terminal, Text, Count);
end;

procedure EchoCharacter(var Terminal: TLineDiscipline; Character: Char);
begin
  if (Terminal.Mode and ConsoleModeEcho) <> 0 then
    ShowText(Terminal, @Character, 1);
end;

procedure EchoText(var Terminal: TLineDiscipline; Text: PChar; Count: LongWord);
begin
  if (Terminal.Mode and ConsoleModeEcho) <> 0 then
    ShowText(Terminal, Text, Count);
end;

{ --- Reading -------------------------------------------------------------- }

function WaitForCharacter(var Terminal: TLineDiscipline; out Character: Char): TCharacterWait;
var
  Timeout: QWord;
  Poll: TTerminalPollRoutine;
begin
  repeat
    if TakeRingCharacter(Terminal, Character) then
      Exit(CharacterArrived);
    if Terminal.HungUp then
      Exit(CharacterWaitHungUp);
    { Read once: the console stops polling while this runs. }
    Poll := Terminal.PollInput;
    if Assigned(Poll) and Poll(@Terminal, Character) then
      Exit(CharacterArrived);
    if Assigned(Poll) then
      Timeout := Terminal.PollIntervalMilliseconds
    else
      Timeout := InfiniteTimeout;
    { The ring is empty now: a writer waiting for room may go on. }
    UpdateTerminalReadiness(Terminal);
    if WaitForEventWithOptions(Terminal.InputAvailable, Timeout, True) = WaitAlerted then
      Exit(CharacterWaitAlerted);
  until False;
end;

{ Like WaitForCharacter, but only if a character is already there. }
function TryTakeCharacter(var Terminal: TLineDiscipline; out Character: Char): Boolean;
var
  Poll: TTerminalPollRoutine;
begin
  Result := TakeRingCharacter(Terminal, Character);
  Poll := Terminal.PollInput;
  if not Result and Assigned(Poll) then
    Result := Poll(@Terminal, Character);
end;

{ Swallows the rest of an escape sequence (after ESC): "[" or "O", then
  parameter bytes, then one final byte in '@'..'~'. }
function SkipEscapeSequence(var Terminal: TLineDiscipline): TCharacterWait;
var
  Character: Char;
begin
  Result := WaitForCharacter(Terminal, Character);
  if Result <> CharacterArrived then
    Exit;
  if (Character <> '[') and (Character <> 'O') then
    Exit;
  repeat
    Result := WaitForCharacter(Terminal, Character);
    if Result <> CharacterArrived then
      Exit;
  until (Character >= '@') and (Character <= '~');
end;

{ Removes the last character of the line being edited: a whole UTF-8
  sequence, so that one Backspace takes back one key. }
procedure EraseLastCharacter(var Terminal: TLineDiscipline);
begin
  if Terminal.LineLength = 0 then
    Exit;
  while (Terminal.LineLength > 1) and ((Byte(Terminal.Line[Terminal.LineLength - 1]) and $C0) = $80) do
    Dec(Terminal.LineLength);
  Dec(Terminal.LineLength);
  EchoText(Terminal, #8' '#8, 3);
end;

{ Reads one edited line into the terminal's line buffer. }
function ReadLine(var Terminal: TLineDiscipline): TLineResult;
var
  Character: Char;
  Waited: TCharacterWait;
begin
  Terminal.LineLength := 0;
  repeat
    Waited := WaitForCharacter(Terminal, Character);
    if Waited = CharacterWaitAlerted then
      Exit(LineInterrupted);
    if Waited = CharacterWaitHungUp then
      Exit(LineEndOfFile);
    case Character of
      KeyCarriageReturn, KeyLineFeed:
        begin
          EchoCharacter(Terminal, KeyLineFeed);
          Terminal.Line[Terminal.LineLength] := KeyLineFeed;
          Inc(Terminal.LineLength);
          Exit(LineReady);
        end;
      KeyBackspace, KeyDelete:
        EraseLastCharacter(Terminal);
      KeyEndOfFile:
        if Terminal.LineLength = 0 then
          Exit(LineEndOfFile)
        else
          Exit(LineReady);
      KeyInterrupt:
        begin
          { Throw the line away and start again. }
          EchoText(Terminal, '^C'#10, 3);
          Terminal.LineLength := 0;
        end;
      KeyEscape:
        begin
          Waited := SkipEscapeSequence(Terminal);
          if Waited = CharacterWaitAlerted then
            Exit(LineInterrupted);
          if Waited = CharacterWaitHungUp then
            Exit(LineEndOfFile);
        end;
    else
      if (Character >= ' ') and (Terminal.LineLength < TerminalLineCapacity - 1) then
      begin
        Terminal.Line[Terminal.LineLength] := Character;
        Inc(Terminal.LineLength);
        EchoCharacter(Terminal, Character);
      end;
    end;
  until False;
end;

{ Character at a time: waits for the first, then takes what is there. }
function ReadCharacters(var Terminal: TLineDiscipline; Destination: PByte; Count: QWord): Int64;
var
  Character: Char;
  Waited: TCharacterWait;
begin
  Result := 0;
  while QWord(Result) < Count do
  begin
    if Result = 0 then
    begin
      Waited := WaitForCharacter(Terminal, Character);
      if Waited = CharacterWaitAlerted then
        Exit(TerminalTransferInterrupted);
      if Waited = CharacterWaitHungUp then
        Exit(0);
    end
    else if not TryTakeCharacter(Terminal, Character) then
      Break;
    if Character = KeyCarriageReturn then
      Character := KeyLineFeed;
    EchoCharacter(Terminal, Character);
    Destination[Result] := Byte(Character);
    Inc(Result);
  end;
end;

{ Hands out what is left of the line read last. }
function TakePendingLine(var Terminal: TLineDiscipline; Destination: PByte; Count: QWord): Int64;
var
  Index: QWord;
begin
  Index := 0;
  while (Index < Count) and (Terminal.PendingLength > 0) do
  begin
    Destination[Index] := Byte(Terminal.Line[Terminal.PendingStart]);
    Inc(Terminal.PendingStart);
    Dec(Terminal.PendingLength);
    Inc(Index);
  end;
  Result := Int64(Index);
end;

function ReadFromTerminal(var Terminal: TLineDiscipline; Destination: PByte; Count: QWord): Int64;
var
  LineResult: TLineResult;
begin
  if Count = 0 then
    Exit(0);
  AcquireMutex(Terminal.InputLock);
  if (Terminal.PendingLength = 0) and ((Terminal.Mode and ConsoleModeLineEditing) = 0) then
    Result := ReadCharacters(Terminal, Destination, Count)
  else
  begin
    LineResult := LineReady;
    if Terminal.PendingLength = 0 then
    begin
      LineResult := ReadLine(Terminal);
      if LineResult = LineReady then
      begin
        Terminal.PendingStart := 0;
        Terminal.PendingLength := Terminal.LineLength;
      end;
    end;
    case LineResult of
      LineReady: Result := TakePendingLine(Terminal, Destination, Count);
      LineInterrupted: Result := TerminalTransferInterrupted;
    else
      Result := 0;
    end;
  end;
  ReleaseMutex(Terminal.InputLock);
  UpdateTerminalReadiness(Terminal);
end;

{ --- Settings --------------------------------------------------------------- }

function GetTerminalMode(var Terminal: TLineDiscipline): LongWord;
begin
  Result := Terminal.Mode;
end;

procedure SetTerminalMode(var Terminal: TLineDiscipline; Mode: LongWord);
begin
  Terminal.Mode := Mode and TerminalDefaultMode;
  { Whether a part of a line is enough to read depends on the mode. }
  UpdateTerminalReadiness(Terminal);
end;

procedure SetTerminalSize(var Terminal: TLineDiscipline; Rows, Columns: LongWord);
var
  WereEnabled: Boolean;
begin
  if (Terminal.Rows = Rows) and (Terminal.Columns = Columns) then
    Exit;
  Terminal.Rows := Rows;
  Terminal.Columns := Columns;
  WereEnabled := SaveAndDisableInterrupts;
  AcquireSpinLockAtCurrentLevel(Terminal.RingLock);
  Terminal.ResizePending := True;
  ReleaseSpinLockAtCurrentLevel(Terminal.RingLock);
  RestoreInterrupts(WereEnabled);
  RaiseTerminalSignal;
end;

procedure SetTerminalForegroundGroup(var Terminal: TLineDiscipline; GroupId: QWord);
begin
  Terminal.ForegroundGroup := GroupId;
end;

{ --- Signals ---------------------------------------------------------------- }

function TakeTerminalSignal(var Terminal: TLineDiscipline; out Signal: TTerminalSignal): Boolean;
var
  WereEnabled: Boolean;
begin
  WereEnabled := SaveAndDisableInterrupts;
  AcquireSpinLockAtCurrentLevel(Terminal.RingLock);
  Result := True;
  Signal := TerminalSignalInterrupt;
  if Terminal.InterruptKeyPressed then
    Terminal.InterruptKeyPressed := False
  else if Terminal.SuspendKeyPressed then
  begin
    Terminal.SuspendKeyPressed := False;
    Signal := TerminalSignalSuspend;
  end
  else if Terminal.HangUpPending then
  begin
    Terminal.HangUpPending := False;
    Signal := TerminalSignalHangUp;
  end
  else if Terminal.ResizePending then
  begin
    Terminal.ResizePending := False;
    Signal := TerminalSignalResize;
  end
  else
    Result := False;
  ReleaseSpinLockAtCurrentLevel(Terminal.RingLock);
  RestoreInterrupts(WereEnabled);
end;

procedure FinishTerminalInterrupt(var Terminal: TLineDiscipline);
begin
  { Shown even if the ended program had turned echo off. }
  ShowText(Terminal, '^C'#10, 3);
  { Typed-ahead input belonged to the program that was ended. }
  ClearRing(Terminal);
  UpdateTerminalReadiness(Terminal);
end;

procedure FinishTerminalSuspend(var Terminal: TLineDiscipline);
begin
  ShowText(Terminal, '^Z'#10, 3);
end;

procedure PassInterruptToTerminalReader(var Terminal: TLineDiscipline);
begin
  Terminal.PendingInterrupt := True;
  AddToRing(Terminal, KeyInterrupt);
  SignalEvent(Terminal.InputAvailable);
  UpdateTerminalReadiness(Terminal);
end;

function TakePendingTerminalInterrupt(var Terminal: TLineDiscipline): Boolean;
var
  WereEnabled: Boolean;
  Index: LongWord;
  Kept: LongWord;
  Character: Char;
begin
  if not Terminal.PendingInterrupt then
    Exit(False);
  WereEnabled := SaveAndDisableInterrupts;
  AcquireSpinLockAtCurrentLevel(Terminal.RingLock);
  Terminal.PendingInterrupt := False;
  { Drop the Ctrl-C characters, keeping the rest in order. }
  Kept := 0;
  Index := 0;
  while Index < Terminal.RingCount do
  begin
    Character := Terminal.Ring[(Terminal.RingStart + Index) mod TerminalRingCapacity];
    if Character <> KeyInterrupt then
    begin
      Terminal.Ring[(Terminal.RingStart + Kept) mod TerminalRingCapacity] := Character;
      Inc(Kept);
    end;
    Inc(Index);
  end;
  Terminal.RingCount := Kept;
  ReleaseSpinLockAtCurrentLevel(Terminal.RingLock);
  RestoreInterrupts(WereEnabled);
  UpdateTerminalReadiness(Terminal);
  Result := True;
end;

procedure HangUpTerminal(var Terminal: TLineDiscipline);
var
  WereEnabled: Boolean;
begin
  WereEnabled := SaveAndDisableInterrupts;
  AcquireSpinLockAtCurrentLevel(Terminal.RingLock);
  Terminal.HungUp := True;
  Terminal.HangUpPending := True;
  ReleaseSpinLockAtCurrentLevel(Terminal.RingLock);
  RestoreInterrupts(WereEnabled);
  { Wake a reader waiting for input; it finds the terminal hung up. }
  SignalEvent(Terminal.InputAvailable);
  UpdateTerminalReadiness(Terminal);
  RaiseTerminalSignal;
end;

end.
