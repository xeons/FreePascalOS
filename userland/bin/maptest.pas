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
  maptest - the virtual memory calls and file mappings

    * a reservation: nothing in it may be touched (EAccessViolation),
      QueryMemory calls it reserved; pages committed in its middle are
      zero, writable and counted in the commit charge, decommitted they
      fault again and the charge goes back, committed again they are
      zero again;
    * protection: read-only pages refuse writes, no-access pages
      reads, and the contents survive back to read-write; writable and
      executable at once is refused, executable without the dynamic code
      policy too; with it, a return instruction written into a page and
      protected read-execute runs, and a read-write page does not;
    * a guard page faults once (ExceptionGuardPage, as an access
      violation) and is an ordinary page after;
    * a file mapped shared shows the file, zeros after its end, refuses
      writes, and read() of the same file agrees; a write() to the file
      shows in it; two private mappings each keep their own writes, and
      the file and the other mapping keep theirs; a private mapping keeps
      what it saw when the file is written; a shared writable mapping is
      refused; a mapping outlives its handle and faults once unmapped;
    * the pages of libsystem this program maps are mapped by other
      processes too (PagesMappedElsewhere);
    * last, a lowered commit limit turns a commit away.

  Each check prints a line; the exit status is 1 if any failed.
}
program maptest;

{$mode objfpc}{$H+}
{$pointermath on}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Kernel,
  Sys.Memory,
  Sys.Exceptions;

const
  PageBytes = 4096;
  ReservedPages = 16;
  FileName = 'maptest.dat';
  { Three pages and a bit. }
  FileBytes = 3 * PageBytes + 100;

var
  Failures: Integer = 0;
  Checks: Integer = 0;
  Sink: Byte;
  LastExceptionCode: LongWord = 0;
  LastFaultAddress: QWord = 0;

procedure Check(const Name: string; Passed: Boolean);
begin
  Inc(Checks);
  if Passed then
    WriteLn('maptest: pass: ', Name)
  else
  begin
    Inc(Failures);
    WriteLn('maptest: FAIL: ', Name);
  end;
end;

{ Notes what the kernel said before the exception becomes EAccessViolation. }
function NoteException(var ExceptionRecord: TAbiExceptionRecord): Boolean;
begin
  LastExceptionCode := ExceptionRecord.Code;
  LastFaultAddress := ExceptionRecord.FaultAddress;
  Result := False;
end;

function ReadFaults(Address: PByte): Boolean;
begin
  Result := False;
  LastExceptionCode := 0;
  try
    Sink := Address^;
  except
    on EAccessViolation do
      Result := True;
  end;
end;

function WriteFaults(Address: PByte; Value: Byte): Boolean;
begin
  Result := False;
  LastExceptionCode := 0;
  try
    Address^ := Value;
  except
    on EAccessViolation do
      Result := True;
  end;
end;

function AllBytesAre(Address: PByte; Count: QWord; Value: Byte): Boolean;
var
  Index: QWord;
begin
  for Index := 0 to Count - 1 do
    if Address[Index] <> Value then
      Exit(False);
  Result := True;
end;

function CommitCharge: QWord;
var
  Resources: TAbiProcessResources;
begin
  KernelGetProcessResources(0, Resources);
  Result := Resources.CommitChargePages;
end;

function StateOf(Address: Pointer): LongWord;
var
  Information: TMemoryInformation;
begin
  QueryMemory(Address, Information);
  Result := Information.State;
end;

{ --- Reserve, commit, decommit ------------------------------------------ }

procedure TestReservation;
var
  Base: PByte;
  Middle: PByte;
  ChargeBefore: QWord;
  Information: TMemoryInformation;
begin
  Check('a reservation is made', ReserveMemory(ReservedPages * PageBytes, Pointer(Base)) = 0);
  if Base = nil then
    Exit;
  Check('a reserved page may not be read', ReadFaults(Base));
  Check('a reserved page may not be written', WriteFaults(Base + 5 * PageBytes, 1));
  QueryMemory(Base, Information);
  Check('the reservation is described as reserved',
    (Information.State = MemoryStateReserved) and (Information.AllocationBase = QWord(Base)) and
    (Information.Length = ReservedPages * PageBytes) and (Information.Kind = MemoryKindPrivate));

  Middle := Base + 4 * PageBytes;
  ChargeBefore := CommitCharge;
  Check('four pages in the middle are committed', CommitMemory(Middle, 4 * PageBytes, ProtectReadWrite) = 0);
  Check('the commit charge grew by four pages', CommitCharge = ChargeBefore + 4);
  Check('committed pages are zero', AllBytesAre(Middle, 4 * PageBytes, 0));
  FillChar(Middle^, 4 * PageBytes, $5A);
  Check('committed pages keep what is written', AllBytesAre(Middle, 4 * PageBytes, $5A));
  Check('the page below them is still reserved', ReadFaults(Middle - 1));
  Check('the page above them is still reserved', ReadFaults(Middle + 4 * PageBytes));
  QueryMemory(Middle, Information);
  Check('the committed run is described', (Information.State = MemoryStateCommitted) and
    (Information.BaseAddress = QWord(Middle)) and (Information.Length = 4 * PageBytes) and
    (Information.Protection = MemoryReadWrite) and (Information.AllocationBase = QWord(Base)));

  Check('two of them are decommitted', DecommitMemory(Middle + PageBytes, 2 * PageBytes) = 0);
  Check('the commit charge went down by two pages', CommitCharge = ChargeBefore + 2);
  Check('a decommitted page faults', ReadFaults(Middle + PageBytes));
  Check('the pages beside it keep their contents', (Middle[0] = $5A) and (Middle[3 * PageBytes] = $5A));
  Check('committed again', CommitMemory(Middle + PageBytes, 2 * PageBytes, ProtectReadWrite) = 0);
  Check('recommitted pages are zero again', AllBytesAre(Middle + PageBytes, 2 * PageBytes, 0));
  Check('committing past the reservation''s end is refused', CommitMemory(Base + (ReservedPages - 1) * PageBytes,
    2 * PageBytes, ProtectReadWrite) <> 0);
  ChargeBefore := CommitCharge;
  Check('the reservation is released', ReleaseMemory(Base) = 0);
  Check('its commit charge went with it', CommitCharge = ChargeBefore - 4);
  Check('the released range is free', StateOf(Base) = MemoryStateFree);
end;

{ --- Protection ---------------------------------------------------------- }

type
  TCodeRoutine = procedure;

procedure WriteReturnInstruction(Address: PByte);
begin
{$ifdef CPUAARCH64}
  PLongWord(Address)^ := $D65F03C0; { ret }
{$else}
  Address^ := $C3; { ret }
{$endif}
end;

function CallFaults(Address: Pointer): Boolean;
begin
  Result := False;
  try
    TCodeRoutine(Address)();
  except
    on EAccessViolation do
      Result := True;
  end;
end;

procedure TestProtection;
var
  Base: PByte;
  Previous: LongWord;
begin
  if ReserveMemory(4 * PageBytes, Pointer(Base)) <> 0 then
  begin
    Check('memory to protect is reserved', False);
    Exit;
  end;
  CommitMemory(Base, 4 * PageBytes, ProtectReadWrite);
  FillChar(Base^, 4 * PageBytes, $33);

  Check('a page is made read-only', ProtectMemory(Base + PageBytes, PageBytes, ProtectRead, Previous) = 0);
  Check('its previous protection was read-write', Previous = MemoryReadWrite);
  Check('a read-only page may be read', not ReadFaults(Base + PageBytes) and (Sink = $33));
  Check('a read-only page may not be written', WriteFaults(Base + PageBytes + 10, 1));
  Check('the pages beside it may still be written', not WriteFaults(Base, $33) and
    not WriteFaults(Base + 2 * PageBytes, $33));
  Check('a page is made inaccessible', ProtectMemory(Base + 2 * PageBytes, PageBytes, ProtectNoAccess,
    Previous) = 0);
  Check('an inaccessible page may not be read', ReadFaults(Base + 2 * PageBytes + 7));
  Check('the fault is at the address touched', LastFaultAddress = QWord(Base + 2 * PageBytes + 7));
  Check('both made read-write again', ProtectMemory(Base + PageBytes, 2 * PageBytes, ProtectReadWrite,
    Previous) = 0);
  Check('their contents survived', AllBytesAre(Base, 4 * PageBytes, $33));

  Check('writable and executable at once is refused',
    ProtectMemory(Base, PageBytes, MemoryRead or MemoryWrite or MemoryExecute, Previous) = ErrorAccessDenied);
  Check('executable without the dynamic code policy is refused',
    ProtectMemory(Base, PageBytes, ProtectReadExecute, Previous) = ErrorAccessDenied);
  Check('code in a read-write page does not run', CallFaults(Base + 3 * PageBytes));
  Check('the dynamic code policy is set', AllowDynamicCode(True) = 0);
  WriteReturnInstruction(Base);
  Check('the written page is made read-execute', ProtectMemory(Base, PageBytes, ProtectReadExecute,
    Previous) = 0);
  Check('the code written there runs', not CallFaults(Base));
  Check('a read-execute page may not be written', WriteFaults(Base + 100, 0));
  AllowDynamicCode(False);
  Check('without the policy again, executable is refused again',
    ProtectMemory(Base + PageBytes, PageBytes, ProtectReadExecute, Previous) = ErrorAccessDenied);
  ReleaseMemory(Base);
end;

procedure TestGuardPage;
var
  Base: PByte;
begin
  if ReserveMemory(2 * PageBytes, Pointer(Base)) <> 0 then
  begin
    Check('memory for a guard page is reserved', False);
    Exit;
  end;
  Check('a guard page is committed', CommitMemory(Base, PageBytes, ProtectReadWrite or ProtectGuard) = 0);
  Check('the first touch of a guard page faults', WriteFaults(Base + 8, 7));
  Check('as a guard page exception', LastExceptionCode = ExceptionGuardPage);
  Check('the second touch does not', not WriteFaults(Base + 8, 7) and (Base[8] = 7));
  ReleaseMemory(Base);
end;

{ --- File mappings ------------------------------------------------------- }

function PatternByte(Offset: QWord): Byte;
begin
  Result := Byte((Offset * 7 + Offset div PageBytes) and $FF);
end;

function MatchesPattern(Address: PByte; Count: QWord): Boolean;
var
  Index: QWord;
begin
  for Index := 0 to Count - 1 do
    if Address[Index] <> PatternByte(Index) then
      Exit(False);
  Result := True;
end;

function CreatePatternFile: Boolean;
var
  Handle: Int64;
  Data: array of Byte;
  Index: QWord;
begin
  SetLength(Data, FileBytes);
  for Index := 0 to FileBytes - 1 do
    Data[Index] := PatternByte(Index);
  Handle := KernelOpen(FileName, OpenRead or OpenWrite or OpenCreate or OpenTruncate);
  if Handle < 0 then
    Exit(False);
  Result := KernelWrite(Handle, @Data[0], FileBytes) = FileBytes;
  KernelClose(Handle);
end;

function OpenForReading: Int64;
begin
  Result := KernelOpen(FileName, OpenRead);
end;

{ Writes Value at Offset of the file through write(). }
procedure WriteFileByte(Offset: QWord; Value: Byte);
var
  Handle: Int64;
begin
  Handle := KernelOpen(FileName, OpenRead or OpenWrite);
  KernelSeek(Handle, Int64(Offset), SeekFromStart);
  KernelWrite(Handle, @Value, 1);
  KernelClose(Handle);
end;

function ReadFileByte(Offset: QWord): Byte;
var
  Handle: Int64;
begin
  Result := 0;
  Handle := OpenForReading;
  KernelSeek(Handle, Int64(Offset), SeekFromStart);
  KernelRead(Handle, @Result, 1);
  KernelClose(Handle);
end;

procedure TestSharedMapping;
var
  Handle: Int64;
  Mapping: PByte;
  Data: array of Byte;
  Information: TMemoryInformation;
begin
  Handle := OpenForReading;
  Check('the file is mapped shared', MapFile(Handle, 0, 0, 0, Pointer(Mapping)) = 0);
  if Mapping = nil then
  begin
    KernelClose(Handle);
    Exit;
  end;
  Check('the mapping shows the file', MatchesPattern(Mapping, FileBytes));
  Check('after the file''s end its last page is zero', AllBytesAre(Mapping + FileBytes, 4 * PageBytes - FileBytes, 0));
  Check('a shared mapping may not be written', WriteFaults(Mapping + 10, 0));
  QueryMemory(Mapping, Information);
  Check('the mapping is described', (Information.Kind = MemoryKindFileMapping) and
    (Information.Length = 4 * PageBytes) and (Information.Protection = MemoryRead));

  { read() of the mapped file sees what the mapping sees. }
  SetLength(Data, FileBytes);
  KernelSeek(Handle, 0, SeekFromStart);
  Check('read() of the mapped file agrees with the mapping',
    (KernelRead(Handle, @Data[0], FileBytes) = FileBytes) and CompareMem(@Data[0], Mapping, FileBytes));
  KernelClose(Handle);
  Check('the mapping outlives its handle', MatchesPattern(Mapping, FileBytes));

  WriteFileByte(PageBytes + 5, $EE);
  Check('a write() to the file shows in the shared mapping', Mapping[PageBytes + 5] = $EE);
  WriteFileByte(PageBytes + 5, PatternByte(PageBytes + 5));
  Check('and so does writing it back', Mapping[PageBytes + 5] = PatternByte(PageBytes + 5));

  Check('the mapping is unmapped', ReleaseMemory(Mapping) = 0);
  Check('an unmapped mapping faults', ReadFaults(Mapping));
end;

procedure TestPrivateMappings;
var
  Handle: Int64;
  First: PByte;
  Second: PByte;
  Shared: PByte;
  ChargeBefore: QWord;
begin
  Handle := OpenForReading;
  ChargeBefore := CommitCharge;
  Check('the file is mapped private twice',
    (MapFile(Handle, 0, 0, MapFilePrivate or MapFileWritable, Pointer(First)) = 0) and
    (MapFile(Handle, 0, 0, MapFilePrivate or MapFileWritable, Pointer(Second)) = 0));
  Check('a shared writable mapping is refused', MapFile(Handle, 0, 0, MapFileWritable, Pointer(Shared)) =
    ErrorUnsupported);
  KernelClose(Handle);
  if (First = nil) or (Second = nil) then
    Exit;
  Check('writable private mappings count against the commit charge', CommitCharge = ChargeBefore + 8);
  Check('both show the file', MatchesPattern(First, FileBytes) and MatchesPattern(Second, FileBytes));
  First[100] := $AB;
  Second[PageBytes * 2 + 1] := $CD;
  Check('a write to one private mapping stays in it', (First[100] = $AB) and
    (Second[100] = PatternByte(100)));
  Check('and so does a write to the other', (Second[PageBytes * 2 + 1] = $CD) and
    (First[PageBytes * 2 + 1] = PatternByte(PageBytes * 2 + 1)));
  Check('the file does not change', (ReadFileByte(100) = PatternByte(100)) and
    (ReadFileByte(PageBytes * 2 + 1) = PatternByte(PageBytes * 2 + 1)));

  { A page of the private mapping not written to keeps the old contents
    when the file changes. }
  Sink := First[PageBytes + 9];
  WriteFileByte(PageBytes + 9, $77);
  Check('a private mapping keeps what it saw when the file is written',
    (First[PageBytes + 9] = PatternByte(PageBytes + 9)) and (Second[PageBytes + 9] = PatternByte(PageBytes + 9)));
  Check('even a page it had not touched yet', First[3 * PageBytes + 1] = PatternByte(3 * PageBytes + 1));
  WriteFileByte(PageBytes + 9, PatternByte(PageBytes + 9));
  ReleaseMemory(First);
  ReleaseMemory(Second);
  Check('their commit charge went with them', CommitCharge = ChargeBefore);
end;

procedure TestSharedLibraryPages;
var
  Resources: TAbiProcessResources;
begin
  KernelGetProcessResources(0, Resources);
  WriteLn('maptest: ', Resources.PagesMappedElsewhere, ' resident pages mapped elsewhere too, ',
    Resources.SharedPages, ' shared, ', Resources.CommittedPages, ' resident; commit charge ',
    Resources.CommitChargePages, ' pages, the system''s ', Resources.SystemCommitChargePages);
  { libsystem's code this program ran (its startup, its runtime) is
    dozens of pages, which the shell that started it ran too. }
  Check('library pages are mapped by other processes too', Resources.PagesMappedElsewhere >= 16);
end;

procedure TestCommitLimit;
var
  Base: PByte;
  Charge: QWord;
begin
  if ReserveMemory(64 * PageBytes, Pointer(Base)) <> 0 then
  begin
    Check('memory for the commit limit is reserved', False);
    Exit;
  end;
  Charge := CommitCharge;
  Check('the commit limit is lowered', KernelSetProcessLimit(ProcessLimitCommit, Charge + 16) >= 0);
  Check('a commit beyond it is refused', CommitMemory(Base, 32 * PageBytes, ProtectReadWrite) = ErrorOutOfMemory);
  Check('nothing was counted for it', CommitCharge = Charge);
  Check('a commit within it is not', CommitMemory(Base, 8 * PageBytes, ProtectReadWrite) = 0);
  ReleaseMemory(Base);
end;

begin
  SetExceptionFilter(@NoteException);
  TestReservation;
  TestProtection;
  TestGuardPage;
  if CreatePatternFile then
  begin
    TestSharedMapping;
    TestPrivateMappings;
    DeleteFile(FileName);
  end
  else
    Check('the file to map is written', False);
  TestSharedLibraryPages;
  TestCommitLimit;
  WriteLn('maptest: ', Checks - Failures, ' of ', Checks, ' checks passed');
  if Failures > 0 then
    Halt(1);
end.
