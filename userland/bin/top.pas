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
  top - the busiest processes, looked at again and again

  top [-b] [-d SECONDS] [-n COUNT]

  Every SECONDS (2 by default) prints how long the system has run, how
  many processes and threads there are, how busy the processors were
  since the last look and the memory in use, then the processes, the
  busiest first: id, user, nice, resident memory (KiB), state, CPU
  since the last look (100 is one processor kept busy), processor time
  and name. On a terminal the screen is cleared before each look; -b
  (batch) just prints one after another. Ends after COUNT looks (for
  ever without -n), or when interrupted.
}
program top;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Sys.Console,
  Sys.Format,
  Sys.Processes,
  Sys.ProcessList,
  Sys.Streams,
  Sys.SystemUsage,
  Sys.Text,
  Util.Accounts,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: top [-b] [-d SECONDS] [-n COUNT]'#10 +
    'Show the busiest processes every SECONDS (2), COUNT times (for ever).'#10#10 +
    '  -b  batch: no clearing of the screen'#10;

  OptionBatch = 1;
  OptionDelay = 2;
  OptionCount = 3;

  { Clears the terminal and puts the cursor at its top left. }
  ClearScreen: PChar = #27'[H'#27'[2J';

type
  TRow = record
    Details: PProcessDetails;
    { Tenths of a percent of one processor since the last look. }
    Share: LongWord;
  end;

var
  Snapshots: array[0..1] of TProcessSnapshot;
  Usages: array[0..1] of TSystemUsage;
  Newest: LongInt;
  Rows: array of TRow;

{ "1.5" into 1500 milliseconds. }
function ParseSeconds(Text: PChar; out Milliseconds: QWord): Boolean;
var
  Position: LongInt;
  Scale: QWord;
begin
  Milliseconds := 0;
  Position := 0;
  while IsDigit(Text[Position]) do
  begin
    Milliseconds := Milliseconds * 10 + QWord(Ord(Text[Position]) - Ord('0'));
    Inc(Position);
  end;
  Milliseconds := Milliseconds * 1000;
  if Text[Position] = '.' then
  begin
    Inc(Position);
    Scale := 100;
    while IsDigit(Text[Position]) do
    begin
      Milliseconds := Milliseconds + QWord(Ord(Text[Position]) - Ord('0')) * Scale;
      Scale := Scale div 10;
      Inc(Position);
    end;
  end;
  Result := (Text[Position] = #0) and (Position > 0) and (Milliseconds > 0);
end;

function StateLetter(State: LongWord): Char;
begin
  case State of
    ProcessStateRunning: Result := 'R';
    ProcessStateStopped: Result := 'T';
    ProcessStateExiting: Result := 'Z';
  else
    Result := 'S';
  end;
end;

procedure FillRows;
var
  Index: LongInt;
  Earlier: PProcessDetails;
  Elapsed: QWord;
begin
  SetLength(Rows, Snapshots[Newest].Count);
  Elapsed := Snapshots[Newest].TakenAtMilliseconds - Snapshots[1 - Newest].TakenAtMilliseconds;
  for Index := 0 to Snapshots[Newest].Count - 1 do
  begin
    Rows[Index].Details := @Snapshots[Newest].Entries[Index];
    Rows[Index].Share := 0;
    Earlier := FindProcessInSnapshot(Snapshots[1 - Newest], Rows[Index].Details^.ProcessId);
    if Earlier <> nil then
      Rows[Index].Share := ProcessorShareTenths(Earlier^.ProcessorNanoseconds,
        Rows[Index].Details^.ProcessorNanoseconds, Elapsed, 1);
  end;
end;

{ The busiest first; equal ones by id. }
procedure SortRows;
var
  Outer: LongInt;
  Inner: LongInt;
  Moving: TRow;
begin
  for Outer := 1 to High(Rows) do
  begin
    Moving := Rows[Outer];
    Inner := Outer - 1;
    while (Inner >= 0) and ((Rows[Inner].Share < Moving.Share) or ((Rows[Inner].Share = Moving.Share) and
      (Rows[Inner].Details^.ProcessId > Moving.Details^.ProcessId))) do
    begin
      Rows[Inner + 1] := Rows[Inner];
      Dec(Inner);
    end;
    Rows[Inner + 1] := Moving;
  end;
end;

procedure WriteSummary;
var
  Seconds: QWord;
  Busy: LongWord;
begin
  Seconds := Usages[Newest].UptimeNanoseconds div 1000000000;
  Busy := AllProcessorsBusyTenths(Usages[1 - Newest], Usages[Newest]);
  WriteFormatted(StandardOutput, 'top - up %u:%02u:%02u, %u processes, %u threads'#10,
    [ArgumentUnsigned(Seconds div 3600), ArgumentUnsigned((Seconds div 60) mod 60), ArgumentUnsigned(Seconds mod 60),
    ArgumentUnsigned(Usages[Newest].ProcessCount), ArgumentUnsigned(Usages[Newest].ThreadCount)]);
  WriteFormatted(StandardOutput, 'CPU: %u.%u%% busy on %u processors'#10, [ArgumentUnsigned(Busy div 10),
    ArgumentUnsigned(Busy mod 10), ArgumentUnsigned(OnlineProcessors(Usages[Newest]))]);
  WriteFormatted(StandardOutput, 'Memory: %u KiB total, %u KiB used, %u KiB free'#10#10,
    [ArgumentUnsigned(Usages[Newest].TotalMemory div 1024), ArgumentUnsigned(UsedMemory(Usages[Newest]) div 1024),
    ArgumentUnsigned(Usages[Newest].FreeMemory div 1024)]);
end;

procedure WriteRows;
var
  Index: LongInt;
  Details: PProcessDetails;
  Seconds: QWord;
  User: PChar;
begin
  WriteLine(StandardOutput, '    PID USER      NI    RES S  %CPU     TIME COMMAND');
  for Index := 0 to High(Rows) do
  begin
    Details := Rows[Index].Details;
    Seconds := Details^.ProcessorNanoseconds div 1000000000;
    User := UserNameOf(Details^.EffectiveUserId);
    if User = nil then
      User := '?';
    WriteFormatted(StandardOutput, '%7u %-8s %3d %6u %c %3u.%u %3u:%02u.%02u %s'#10,
      [ArgumentUnsigned(Details^.ProcessId), ArgumentText(User), ArgumentNumber(Details^.Nice),
      ArgumentUnsigned(Details^.ResidentBytes div 1024), ArgumentCharacter(StateLetter(Details^.State)),
      ArgumentUnsigned(Rows[Index].Share div 10), ArgumentUnsigned(Rows[Index].Share mod 10),
      ArgumentUnsigned(Seconds div 60), ArgumentUnsigned(Seconds mod 60),
      ArgumentUnsigned((Details^.ProcessorNanoseconds div 10000000) mod 100), ArgumentText(@Details^.Name[0])]);
  end;
end;

{ Takes the next look into the older pair of buffers. }
procedure Look;
begin
  Newest := 1 - Newest;
  if TakeProcessSnapshot(Snapshots[Newest]) <> ErrorNone then
    Fail(1, 'cannot list the processes', []);
  GetSystemUsage(Usages[Newest]);
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Batch: Boolean;
  DelayMilliseconds: QWord;
  Count: QWord;
  Looks: QWord;
begin
  Batch := False;
  DelayMilliseconds := 2000;
  Count := 0;
  BeginOptions(Parser, [
    OptionDefinition('b', 'batch', False, OptionBatch),
    OptionDefinition('d', 'delay', True, OptionDelay),
    OptionDefinition('n', 'iterations', True, OptionCount)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionBatch: Batch := True;
      OptionDelay:
        if not ParseSeconds(Value, DelayMilliseconds) then
          FailWithUsageHint('invalid delay ''%s''', [ArgumentText(Value)]);
      OptionCount:
        if not ParseUnsigned(Value, Count) or (Count = 0) then
          FailWithUsageHint('invalid count ''%s''', [ArgumentText(Value)]);
    end;
  if not Batch and not IsConsole(StandardOutputHandle) then
    Batch := True;
  InitializeProcessSnapshot(Snapshots[0]);
  InitializeProcessSnapshot(Snapshots[1]);
  Newest := 0;
  { The first look only gives something to compare with. }
  Look;
  Looks := 0;
  repeat
    SleepMilliseconds(DelayMilliseconds);
    Look;
    FillRows;
    SortRows;
    if not Batch then
      WriteText(StandardOutput, ClearScreen);
    WriteSummary;
    WriteRows;
    if Batch then
      WriteLine(StandardOutput, '');
    FlushStream(StandardOutput);
    Inc(Looks);
  until (Count > 0) and (Looks >= Count);
  FreeProcessSnapshot(Snapshots[0]);
  FreeProcessSnapshot(Snapshots[1]);
end.
