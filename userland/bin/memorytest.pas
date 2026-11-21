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
  memorytest - the block cache under memory pressure, the out-of-memory
  policy and discarding freed space

  memorytest cache
      Reads /bin until the block cache has grown, then starts a memory
      hog that takes memory until it finds memory short, reading files
      all the while: the cache must give lines back, every read must
      work and the hog must end normally. (A coretest line.)
  memorytest oom
      Starts a small bystander and a hog that takes memory without end:
      the hog must be ended with 137, the bystander and this program
      must live on. Then a small process with the OOM score adjustment
      1000 beside a hog: the small one must be ended too.
  memorytest trim
      On the volumes labelled TRIMNVME and TRIMVIRT: writes a 24 MiB
      file, syncs, removes it; on TRIMNVME syncs again (the batched
      discards go out), on TRIMVIRT runs fstrim; the disks must have
      been told to discard at least that much. The host then checks the
      disk images shrank (scripts/test-memory-pressure.sh).
  memorytest suite
      oom, then trim (what the test script boots as the first program,
      with no arguments).
  memorytest hog [--step MIB] [--limit MIB] [--hold SECONDS]
                 [--until-pressure] [--adjust N]
      Takes memory STEP MiB at a time, touching every page, up to LIMIT
      MiB (without end if 0), or until memory is short; then holds it.

  Each check prints a line; "memorytest: N of M checks passed" ends a
  run, and the exit status is 0 only if every check passed.
}
program memorytest;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Classes,
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Files,
  Sys.Information,
  Sys.Memory,
  Sys.MemoryStatus,
  Sys.Processes,
  Sys.Streams;

const
  Mebibyte = QWord(1024) * 1024;
  PageBytes = 4096;
  TrimFileMebibytes = 24;
  ExitStatusEndedForMemory = 137;

var
  Checks: Integer = 0;
  Failures: Integer = 0;

procedure Check(Condition: Boolean; const What: string);
begin
  Inc(Checks);
  if Condition then
    PrintStringLine('memorytest: ok   ' + What)
  else
  begin
    Inc(Failures);
    PrintStringLine('memorytest: FAIL ' + What);
  end;
end;

{ --- The hog ------------------------------------------------------------- }

procedure TouchPages(Block: PByte; Length: QWord);
var
  Offset: QWord;
begin
  Offset := 0;
  while Offset < Length do
  begin
    Block[Offset] := $5A;
    Offset := Offset + PageBytes;
  end;
end;

function MemoryIsShort: Boolean;
var
  Pressure: TMemoryPressure;
begin
  Result := (GetMemoryPressure(Pressure) = 0) and (Pressure.Level <> AbiMemoryPressureNone);
end;

procedure RunHog(StepMebibytes, LimitMebibytes, HoldSeconds: QWord; UntilPressure: Boolean);
var
  Taken: QWord;
  Block: PByte;
begin
  Taken := 0;
  while (LimitMebibytes = 0) or (Taken < LimitMebibytes) do
  begin
    Block := PByte(AllocateMemory(StepMebibytes * Mebibyte));
    if Block = nil then
    begin
      PrintStringLine(Format('memorytest: hog could not take more than %d MiB', [Taken]));
      Break;
    end;
    TouchPages(Block, StepMebibytes * Mebibyte);
    Taken := Taken + StepMebibytes;
    if UntilPressure and MemoryIsShort then
    begin
      PrintStringLine(Format('memorytest: hog found memory short after %d MiB', [Taken]));
      Break;
    end;
  end;
  PrintStringLine(Format('memorytest: hog holds %d MiB', [Taken]));
  SleepMilliseconds(HoldSeconds * 1000);
  Halt(0);
end;

procedure RunHogFromArguments;
var
  Index: Integer;
  Step: QWord;
  Limit: QWord;
  Hold: QWord;
  UntilPressure: Boolean;
  Previous: LongInt;
begin
  Step := 4;
  Limit := 0;
  Hold := 0;
  UntilPressure := False;
  Index := 2;
  while Index <= ParamCount do
  begin
    if ParamStr(Index) = '--until-pressure' then
      UntilPressure := True
    else if (ParamStr(Index) = '--step') and (Index < ParamCount) then
    begin
      Inc(Index);
      Step := StrToQWord(ParamStr(Index));
    end
    else if (ParamStr(Index) = '--limit') and (Index < ParamCount) then
    begin
      Inc(Index);
      Limit := StrToQWord(ParamStr(Index));
    end
    else if (ParamStr(Index) = '--hold') and (Index < ParamCount) then
    begin
      Inc(Index);
      Hold := StrToQWord(ParamStr(Index));
    end
    else if (ParamStr(Index) = '--adjust') and (Index < ParamCount) then
    begin
      Inc(Index);
      SetOomScoreAdjust(StrToInt(ParamStr(Index)), Previous);
    end;
    Inc(Index);
  end;
  if Step = 0 then
    Step := 1;
  RunHog(Step, Limit, Hold, UntilPressure);
end;

{ Starts this program with Arguments (after the program name); returns
  the process handle (negative: an error). }
function StartSelf(const Arguments: array of string): Int64;
var
  Texts: array of string;
  Pointers: array of PChar;
  Index: Integer;
  Options: TProcessOptions;
begin
  SetLength(Texts, Length(Arguments) + 1);
  SetLength(Pointers, Length(Arguments) + 2);
  Texts[0] := 'memorytest';
  for Index := 0 to High(Arguments) do
    Texts[Index + 1] := Arguments[Index];
  for Index := 0 to High(Texts) do
    Pointers[Index] := PChar(Texts[Index]);
  Pointers[High(Pointers)] := nil;
  DefaultProcessOptions(Options);
  Result := StartProgram('/bin/memorytest', @Pointers[0], Options);
end;

{ The exit status, or -1 if the program did not end within Seconds. }
function WaitForStatus(Handle: Int64; Seconds: QWord): LongInt;
var
  ExitCode: LongInt;
begin
  if WaitForProgramWithTimeout(Handle, Seconds * 1000, ExitCode) <> ErrorNone then
    Exit(-1);
  Result := ExitCode;
end;

function StillRunning(Handle: Int64): Boolean;
var
  ExitCode: LongInt;
begin
  Result := WaitForProgramWithTimeout(Handle, 0, ExitCode) = ErrorTimedOut;
end;

procedure EndAndClose(Handle: Int64);
var
  ExitCode: LongInt;
begin
  if Handle < 0 then
    Exit;
  TerminateProgram(QWord(ProcessIdOf(Handle)), 143);
  WaitForProgramWithTimeout(Handle, 10000, ExitCode);
  CloseFile(Handle);
end;

{ --- The cache under pressure --------------------------------------------- }

{ Reads every file of Folder once; False if a read failed. }
function ReadFolder(const Folder: string; out Bytes: QWord): Boolean;
var
  Search: TSearchRec;
  Stream: TFileStream;
  Buffer: array[0..65535] of Byte;
  Count: LongInt;
begin
  Result := True;
  Bytes := 0;
  if FindFirst(Folder + '/*', faAnyFile, Search) <> 0 then
    Exit(False);
  repeat
    if (Search.Attr and faDirectory) <> 0 then
      Continue;
    try
      Stream := TFileStream.Create(Folder + '/' + Search.Name, fmOpenRead or fmShareDenyNone);
      try
        repeat
          Count := Stream.Read(Buffer, SizeOf(Buffer));
          Bytes := Bytes + QWord(Count);
        until Count <= 0;
      finally
        Stream.Free;
      end;
    except
      Result := False;
    end;
  until FindNext(Search) <> 0;
  FindClose(Search);
end;

procedure TestCacheUnderPressure;
var
  Before: TBlockCacheStatistics;
  Grown: TBlockCacheStatistics;
  After: TBlockCacheStatistics;
  PressureBefore: TMemoryPressure;
  PressureAfter: TMemoryPressure;
  Bytes: QWord;
  ReadsWorked: Boolean;
  Hog: Int64;
  Status: LongInt;
  Rounds: Integer;
begin
  Check(GetBlockCacheStatistics(Before) = 0, 'the kernel reports the block cache');
  Check(GetMemoryPressure(PressureBefore) = 0, 'the kernel reports memory pressure');
  Check((Before.MinimumLines > 0) and (Before.MaximumLines >= Before.MinimumLines) and
    (Before.LineCount >= Before.MinimumLines), Format('the cache is %d lines, within %d to %d',
    [Before.LineCount, Before.MinimumLines, Before.MaximumLines]));
  ReadsWorked := ReadFolder('/bin', Bytes) and ReadFolder('/bin', Bytes);
  GetBlockCacheStatistics(Grown);
  Check(ReadsWorked and (Bytes > 0), Format('read %d bytes of /bin', [Bytes]));
  Check((Grown.LinesGrown > Before.LinesGrown) or (Grown.LineCount = Grown.MaximumLines),
    Format('the cache grew to %d lines', [Grown.LineCount]));
  Check(Grown.Hits > Before.Hits, 'reading again hits the cache');

  Hog := StartSelf(['hog', '--step', '1', '--until-pressure', '--hold', '2']);
  Check(Hog >= 0, 'started the hog');
  if Hog < 0 then
    Exit;
  { Reading on while the hog takes memory. }
  Rounds := 0;
  while StillRunning(Hog) and (Rounds < 2000) do
  begin
    if not ReadFolder('/bin', Bytes) then
      ReadsWorked := False;
    Inc(Rounds);
  end;
  Status := WaitForStatus(Hog, 120);
  CloseFile(Hog);
  GetBlockCacheStatistics(After);
  GetMemoryPressure(PressureAfter);
  Check(Status = 0, Format('the hog ended normally (status %d)', [Status]));
  Check(ReadsWorked, Format('every read worked while memory was short (%d rounds)', [Rounds]));
  Check(PressureAfter.PressureEvents > PressureBefore.PressureEvents, 'memory was found short');
  Check(After.LinesShrunk > Grown.LinesShrunk,
    Format('the cache gave %d lines back', [After.LinesShrunk - Grown.LinesShrunk]));
  Check(After.LineCount >= After.MinimumLines, 'the cache kept its minimum');
  Check(PressureAfter.ProcessesEnded = PressureBefore.ProcessesEnded, 'nobody was ended for memory');
end;

{ --- Out of memory ---------------------------------------------------------- }

procedure TestOutOfMemory;
var
  Bystander: Int64;
  Hog: Int64;
  Marked: Int64;
  Status: LongInt;
  Before: TMemoryPressure;
  After: TMemoryPressure;
  HogId: Int64;
begin
  GetMemoryPressure(Before);
  Bystander := StartSelf(['hog', '--step', '1', '--limit', '4', '--hold', '600']);
  Check(Bystander >= 0, 'started a small bystander');
  SleepMilliseconds(1000);
  Hog := StartSelf(['hog', '--step', '4']);
  Check(Hog >= 0, 'started a hog without end');
  if Hog < 0 then
  begin
    EndAndClose(Bystander);
    Exit;
  end;
  HogId := ProcessIdOf(Hog);
  Status := WaitForStatus(Hog, 300);
  CloseFile(Hog);
  GetMemoryPressure(After);
  Check(Status = ExitStatusEndedForMemory, Format('the hog was ended with 137 (status %d)', [Status]));
  Check(After.ProcessesEnded > Before.ProcessesEnded, 'the kernel counted a process ended for memory');
  Check(QWord(HogId) = After.LastEndedProcessId,
    Format('the hog (%d) was the one ended (%d, %s)', [HogId, After.LastEndedProcessId, PChar(@After.LastEndedName[0])]));
  Check(StillRunning(Bystander), 'the bystander lives on');

  { A small process marked to go first goes before the hog is done. }
  Marked := StartSelf(['hog', '--step', '1', '--limit', '16', '--hold', '600', '--adjust', '1000']);
  Check(Marked >= 0, 'started a small process with the adjustment 1000');
  SleepMilliseconds(1500);
  Hog := StartSelf(['hog', '--step', '4']);
  Status := WaitForStatus(Marked, 300);
  Check(Status = ExitStatusEndedForMemory, Format('the marked process was ended with 137 (status %d)', [Status]));
  if Marked >= 0 then
    CloseFile(Marked);
  if Hog >= 0 then
  begin
    Status := WaitForStatus(Hog, 300);
    Check(Status = ExitStatusEndedForMemory, Format('then the hog (status %d)', [Status]));
    CloseFile(Hog);
  end;
  Check(StillRunning(Bystander), 'the bystander still lives on');
  EndAndClose(Bystander);
end;

{ --- Discarding -------------------------------------------------------------- }

{ The folder of the volume labelled Labelled, or ''. }
function VolumeFolder(const Labelled: string): string;
var
  Information: TVolumeInformation;
  Index: Integer;
begin
  Result := '';
  Index := 0;
  while GetVolume(Index, Information) do
  begin
    if string(PChar(@Information.VolumeLabel[0])) = Labelled then
      Exit('/volumes/' + string(PChar(@Information.Name[0])));
    Inc(Index);
  end;
end;

function WriteBigFile(const Path: string): Boolean;
var
  Stream: TFileStream;
  Buffer: array of Byte;
  Index: Integer;
begin
  Result := False;
  SetLength(Buffer, Mebibyte);
  for Index := 0 to High(Buffer) do
    Buffer[Index] := Byte($A5 xor Index);
  try
    Stream := TFileStream.Create(Path, fmCreate);
    try
      for Index := 1 to TrimFileMebibytes do
        Stream.WriteBuffer(Buffer[0], Length(Buffer));
      Result := True;
    finally
      Stream.Free;
    end;
  except
    Result := False;
  end;
end;

procedure TestDiscards(const Labelled: string; UseFstrim: Boolean);
var
  Folder: string;
  Path: string;
  Before: TBlockCacheStatistics;
  After: TBlockCacheStatistics;
  Discarded: QWord;
  Error: LongInt;
begin
  Folder := VolumeFolder(Labelled);
  Check(Folder <> '', 'found the volume ' + Labelled);
  if Folder = '' then
    Exit;
  Path := Folder + '/big.bin';
  Check(WriteBigFile(Path), Format('wrote %d MiB to %s', [TrimFileMebibytes, Path]));
  Check(SyncFileSystems = 0, 'synced');
  GetBlockCacheStatistics(Before);
  Check(RemovePath(PChar(Path)) = 0, 'removed it');
  if UseFstrim then
  begin
    Error := TrimVolume(Folder, Discarded);
    Check(Error = 0, Format('fstrim %s (%s)', [Folder, ErrorMessage(Error)]));
    Check(Discarded >= TrimFileMebibytes * Mebibyte,
      Format('fstrim discarded %d bytes, the file''s at least', [Discarded]));
  end
  else
  begin
    { The batched discards go out with the sync. }
    Check(SyncFileSystems = 0, 'synced again');
    GetBlockCacheStatistics(After);
    Check(After.BytesDiscarded - Before.BytesDiscarded >= TrimFileMebibytes * Mebibyte,
      Format('freeing it discarded %d bytes', [After.BytesDiscarded - Before.BytesDiscarded]));
  end;
end;

procedure TestTrim;
begin
  TestDiscards('TRIMNVME', False);
  TestDiscards('TRIMVIRT', True);
end;

procedure Finish;
begin
  PrintStringLine(Format('memorytest: %d of %d checks passed', [Checks - Failures, Checks]));
  if Failures > 0 then
    Halt(1);
  Halt(0);
end;

var
  Mode: string;
begin
  if ParamCount >= 1 then
    Mode := ParamStr(1)
  else
    Mode := 'suite';
  if Mode = 'hog' then
    RunHogFromArguments
  else if Mode = 'cache' then
    TestCacheUnderPressure
  else if Mode = 'oom' then
    TestOutOfMemory
  else if Mode = 'trim' then
    TestTrim
  else if Mode = 'suite' then
  begin
    TestOutOfMemory;
    TestTrim;
  end
  else
  begin
    PrintErrorStringLine('Usage: memorytest cache|oom|trim|suite|hog [...]');
    Halt(2);
  end;
  Finish;
end.
