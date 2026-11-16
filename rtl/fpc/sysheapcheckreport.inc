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
  Heap checking (sysheapcheck.inc): the report when a check fails.

  The heap is damaged by then, so the report uses no heap and no text
  files: it is put together in a fixed buffer and written straight to
  standard error, and to the console (whose output is the kernel log,
  on the serial line) when standard error goes somewhere else - a
  service's log, a pipe - so that a failure in any program shows up in
  one place. Then the process ends at once with exit status 204 (Free
  Pascal's "invalid pointer operation"): running exit procedures and
  finalizers on a damaged heap could only make things worse.

  The report names the program, the problem, the block (address and
  size), where it was damaged, and code addresses: where the block was
  freed (kept in the quarantine) and the stack of the code that found
  the problem. The addresses can be looked up with
  addr2line -f -e build/amd64/user/bin/PROGRAM (or the library).
}

const
  HeapCheckExitStatus = 204;
  HeapCheckReportCapacity = 4096;
  { Code addresses kept for each freed block, and shown for the code
    that found a problem. }
  HeapCheckFreedByDepth = 8;
  HeapCheckStackDepth = 12;

type
  THeapCheckFreedBy = array[0..HeapCheckFreedByDepth - 1] of CodePointer;

var
  HeapCheckReport: array[0..HeapCheckReportCapacity - 1] of Char;
  HeapCheckReportLength: SizeInt;
  HeapCheckReportLock: LongInt = LockFree;

procedure AppendToHeapCheckReport(const Text: ShortString);
var
  Index: SizeInt;
begin
  for Index := 1 to Length(Text) do
    if HeapCheckReportLength < HeapCheckReportCapacity then
    begin
      HeapCheckReport[HeapCheckReportLength] := Text[Index];
      Inc(HeapCheckReportLength);
    end;
end;

procedure AppendTextToHeapCheckReport(Text: PChar);
begin
  if Text = nil then
    Exit;
  while (Text^ <> #0) and (HeapCheckReportLength < HeapCheckReportCapacity) do
  begin
    HeapCheckReport[HeapCheckReportLength] := Text^;
    Inc(HeapCheckReportLength);
    Inc(Text);
  end;
end;

procedure AppendNumberToHeapCheckReport(Value: QWord);
var
  Text: ShortString;
begin
  Str(Value, Text);
  AppendToHeapCheckReport(Text);
end;

procedure AppendAddressToHeapCheckReport(Address: Pointer);
begin
  AppendToHeapCheckReport('$' + HexStr(PtrUInt(Address), 16));
end;

procedure AppendCodeAddresses(Addresses: PCodePointer; Count: SizeInt);
var
  Index: SizeInt;
begin
  if Count = 0 then
    AppendToHeapCheckReport(' unknown');
  for Index := 0 to Count - 1 do
  begin
    AppendToHeapCheckReport(' ');
    AppendAddressToHeapCheckReport(Addresses[Index]);
  end;
  AppendToHeapCheckReport(LineEnding);
end;

{ Starts the report; only one thread reports, the others wait (the
  process ends with the first report). }
procedure BeginHeapCheckReport(Problem: PChar);
begin
  AcquireWordLock(HeapCheckReportLock);
  HeapCheckReportLength := 0;
  AppendToHeapCheckReport(LineEnding + 'heap check in ');
  if argc > 0 then
    AppendTextToHeapCheckReport(argv[0]);
  AppendToHeapCheckReport(' (process ');
  AppendNumberToHeapCheckReport(GetProcessID);
  AppendToHeapCheckReport('): ');
  AppendTextToHeapCheckReport(Problem);
  AppendToHeapCheckReport(LineEnding);
end;

procedure AppendBlockToHeapCheckReport(Block: Pointer; ByteCount: PtrUInt);
begin
  AppendToHeapCheckReport('  block:     ');
  AppendAddressToHeapCheckReport(Block);
  AppendToHeapCheckReport(', ');
  AppendNumberToHeapCheckReport(ByteCount);
  AppendToHeapCheckReport(' bytes' + LineEnding);
end;

procedure AppendFreedByToHeapCheckReport(Caption: ShortString; const FreedBy: THeapCheckFreedBy);
var
  Count: SizeInt;
begin
  Count := 0;
  while (Count < HeapCheckFreedByDepth) and (FreedBy[Count] <> nil) do
    Inc(Count);
  AppendToHeapCheckReport(Caption);
  AppendCodeAddresses(@FreedBy[0], Count);
end;

procedure WriteHeapCheckReportTo(Handle: Int64);
begin
  SystemCall(CallWrite, QWord(Handle), QWord(@HeapCheckReport[0]), QWord(HeapCheckReportLength), 0, 0, 0);
end;

{ Adds the stack of the code that found the problem, writes the report
  and ends the process. }
procedure FinishHeapCheckReport; noreturn;
var
  Stack: array[0..HeapCheckStackDepth - 1] of CodePointer;
  StackCount: SizeInt;
  Console: Int64;
begin
  StackCount := CaptureBacktrace(2, HeapCheckStackDepth, @Stack[0]);
  AppendToHeapCheckReport('  found at:');
  AppendCodeAddresses(@Stack[0], StackCount);
  AppendToHeapCheckReport('The program was ended (exit status 204); HEAP_CHECKS is described in' + LineEnding +
    'docs/Architecture.md, "Heap checking".' + LineEnding);

  WriteHeapCheckReportTo(StdErrorHandle);
  if SystemCall(CallGetHandleKind, StdErrorHandle, 0, 0, 0, 0, 0) <> HandleKindConsole then
  begin
    Console := SystemCall(CallOpen, QWord(PChar('/dev/console')), OpenWrite, 0, 0, 0, 0);
    if Console >= 0 then
    begin
      WriteHeapCheckReportTo(Console);
      SystemCall(CallClose, QWord(Console), 0, 0, 0, 0, 0);
    end;
  end;

  while True do
    SystemCall(CallExit, HeapCheckExitStatus, 0, 0, 0, 0, 0);
end;

{ A block whose fill or guard changed: Offset is the first changed byte
  from the start of the block, Found what it holds, Expected the
  pattern. }
procedure ReportDamagedHeapBlock(Problem: PChar; Block: Pointer; ByteCount, Offset: PtrUInt;
  Found, Expected: Byte; const FreedBy: THeapCheckFreedBy); noreturn;
begin
  BeginHeapCheckReport(Problem);
  AppendBlockToHeapCheckReport(Block, ByteCount);
  AppendToHeapCheckReport('  offset:    ');
  AppendNumberToHeapCheckReport(Offset);
  AppendToHeapCheckReport(' holds $' + HexStr(Found, 2) + ' instead of $' + HexStr(Expected, 2) + LineEnding);
  AppendFreedByToHeapCheckReport('  freed at:', FreedBy);
  FinishHeapCheckReport;
end;

{ A block that cannot be freed (or resized, or measured): freed twice,
  or not a heap block at all. }
procedure ReportBadHeapPointer(Problem: PChar; Block: Pointer; Magic: LongWord;
  const FreedBy: THeapCheckFreedBy); noreturn;
begin
  BeginHeapCheckReport(Problem);
  AppendToHeapCheckReport('  block:     ');
  AppendAddressToHeapCheckReport(Block);
  AppendToHeapCheckReport(' (header $' + HexStr(Magic, 8) + ')' + LineEnding);
  if FreedBy[0] <> nil then
    AppendFreedByToHeapCheckReport('  freed before at:', FreedBy);
  FinishHeapCheckReport;
end;
