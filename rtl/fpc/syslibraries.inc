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
  Free Pascal libraries loaded at run time: their units' initialization
  and finalization and their threadvars.

  A program's unit tables (INITFINAL, FPC_THREADVARTABLES) are made by
  the compiler for the program and list the units of every library it
  was linked with, so those units are initialized with the program's.
  A library compiled from a "library" source has tables of its own,
  listing every unit it uses - System, SysUtils and the like among them,
  which libsystem shares with the program and which must not start a
  second time. Its startup code (si_dll, run as the library's DT_INIT
  when LoadLibrary takes in its initializers) hands the tables to
  SysRegisterLibrary, which

    * gives the threadvars of the library's own units (the tables the
      program and the libraries registered before do not have) blocks of
      their own (sysdyntls.inc): offsets with ThreadvarDynamicFlag, the
      library's number and the offset in its block; the calling thread
      keeps their values (the initial ones, or what was set before the
      program had threads),
    * initializes the units no table seen before has, in table order.

  SysUnregisterLibrary (the library's DT_FINI, run before the program's
  units finalize) finalizes them in the opposite order. The library's own
  begin ... end block is not run: put startup code in a unit's
  initialization section.

  Resource strings: the compiler gives every resource string its default
  value as it lays the tables out, but the routines that change them
  (ObjPas: SetResourceStrings, SetUnitResourceStrings, and at the end
  FinalizeResourceTables) walk the table System's _FPC_ResourceStringTables
  points at - the program's. SysRegisterLibrary therefore puts a merged
  table there: the program's tables followed by those of every library's
  own units (a unit's table is the same records whoever lists it, so the
  units the program has already are not listed twice), and the same
  for the tables of constants initialized with resource strings
  (_FPC_ResStrInitTables). A translation made after the library was
  loaded reaches its strings; one made before does not.
}

type
  PFreePascalLibrary = ^TFreePascalLibrary;
  TFreePascalLibrary = record
    InitFinalTable: PInitFinalTable;
    ThreadvarTables: PltvInitTablesTable;
    { Per table entry: True for those this library brought (allocated
      with the table's count). }
    OwnUnits: PBoolean;
    OwnThreadvarTables: PBoolean;
    { Its number among the threadvar libraries, -1 if it has none. }
    ThreadvarLibrary: LongInt;
    { The calling thread's block has the values (or they are still
      globals: no threads yet). }
    ValuesCopied: Boolean;
  end;

const
  FreePascalLibraryLimit = 256;

var
  FreePascalLibraries: array[0..FreePascalLibraryLimit - 1] of PFreePascalLibrary;
  FreePascalLibraryCount: LongInt = 0;

type
  { ObjPas's TResourceStringTableList: per unit, indirect pointers to
    the first and past the last record of its table. }
  TResourceTableEntry = record
    TableStart: PPointer;
    TableEnd: PPointer;
  end;
  PResourceTableList = ^TResourceTableList;
  TResourceTableList = packed record
    Count: SizeInt;
    Tables: array[0..65535] of TResourceTableEntry;
  end;
  { ObjPas's TResStrInitTable: per unit, a list of constants to update. }
  PResourceInitTableList = ^TResourceInitTableList;
  TResourceInitTableList = packed record
    Count: SizeInt;
    Tables: array[1..32767] of Pointer;
  end;

var
  { The merged tables made so far (nil while only the program's are). }
  MergedResourceTables: PResourceTableList = nil;
  MergedResourceInitTables: PResourceInitTableList = nil;

function ProgramInitFinalTable: PInitFinalTable;
begin
  ProgramInitFinalTable := PInitFinalTable(EntryInformation.InitFinalTable);
end;

function ProgramThreadvarTables: PltvInitTablesTable;
begin
  ProgramThreadvarTables := PltvInitTablesTable(EntryInformation.ThreadvarTablesTable);
end;

{ The procedure that identifies a unit's entry: its initialization, or
  its finalization if it has none. }
function UnitIdentity(constref Entry: TInitFinalRec): Pointer;
begin
  if Assigned(Entry.InitProc) then
    UnitIdentity := Pointer(Entry.InitProc)
  else
    UnitIdentity := Pointer(Entry.FinalProc);
end;

function TableHasUnit(Table: PInitFinalTable; Identity: Pointer): Boolean;
var
  Index: ALUUInt;
begin
  TableHasUnit := False;
  if Table = nil then
    Exit;
  for Index := 1 to ALUUInt(Table^.TableCount) do
    if UnitIdentity(Table^.Procs[Index]) = Identity then
    begin
      TableHasUnit := True;
      Exit;
    end;
end;

function UnitIsKnown(Identity: Pointer): Boolean;
var
  Index: LongInt;
begin
  UnitIsKnown := True;
  if TableHasUnit(ProgramInitFinalTable, Identity) then
    Exit;
  for Index := 0 to FreePascalLibraryCount - 1 do
    if TableHasUnit(FreePascalLibraries[Index]^.InitFinalTable, Identity) then
      Exit;
  UnitIsKnown := False;
end;

function TablesHaveList(Tables: PltvInitTablesTable; List: pltvInitEntry): Boolean;
var
  Index: DWord;
begin
  TablesHaveList := False;
  if Tables = nil then
    Exit;
  for Index := 1 to Tables^.count do
    if Tables^.tables[Index]^ = List then
    begin
      TablesHaveList := True;
      Exit;
    end;
end;

function ThreadvarListIsKnown(List: pltvInitEntry): Boolean;
var
  Index: LongInt;
begin
  ThreadvarListIsKnown := True;
  if TablesHaveList(ProgramThreadvarTables, List) then
    Exit;
  for Index := 0 to FreePascalLibraryCount - 1 do
    if TablesHaveList(FreePascalLibraries[Index]^.ThreadvarTables, List) then
      Exit;
  ThreadvarListIsKnown := False;
end;

function AllocateFlags(Count: PtrUInt): PBoolean;
var
  Flags: PBoolean;
begin
  Flags := PBoolean(GetMem(Count + 1));
  FillChar(Flags^, Count + 1, 0);
  AllocateFlags := Flags;
end;

{ Lays the library's own threadvars out in a block (16 byte aligned, as
  SysInitThreadVar does) and stores their offsets. }
procedure LayOutLibraryThreadvars(Registered: PFreePascalLibrary);
var
  TableIndex: DWord;
  Entry: pltvInitEntry;
  BlockSize: PtrUInt;
  Number: LongInt;
begin
  Registered^.ThreadvarLibrary := -1;
  if Registered^.ThreadvarTables = nil then
    Exit;
  BlockSize := 0;
  for TableIndex := 1 to Registered^.ThreadvarTables^.count do
    if Registered^.OwnThreadvarTables[TableIndex] then
    begin
      Entry := Registered^.ThreadvarTables^.tables[TableIndex]^;
      while Entry^.varaddr <> nil do
      begin
        BlockSize := (BlockSize + 15) and not PtrUInt(15);
        Inc(BlockSize, PtrUInt(Entry^.size));
        Inc(Entry);
      end;
    end;
  if BlockSize = 0 then
    Exit;
  if BlockSize >= ThreadvarLibraryBlockLimit then
    RunError(226);
  Number := AddThreadvarLibrary(BlockSize);
  if Number < 0 then
    RunError(226);
  Registered^.ThreadvarLibrary := Number;

  BlockSize := 0;
  for TableIndex := 1 to Registered^.ThreadvarTables^.count do
    if Registered^.OwnThreadvarTables[TableIndex] then
    begin
      Entry := Registered^.ThreadvarTables^.tables[TableIndex]^;
      while Entry^.varaddr <> nil do
      begin
        BlockSize := (BlockSize + 15) and not PtrUInt(15);
        Entry^.varaddr^ := ThreadvarDynamicFlag or (DWord(Number) shl ThreadvarLibraryShift) or DWord(BlockSize);
        Inc(BlockSize, PtrUInt(Entry^.size));
        Inc(Entry);
      end;
    end;
end;

{ Copies the library's threadvar globals (their values so far) into the
  calling thread's block, once threads are in use. }
procedure CopyLibraryThreadvarValues(Registered: PFreePascalLibrary);
var
  TableIndex: DWord;
  Entry: pltvInitEntry;
begin
  if (Registered^.ThreadvarLibrary < 0) or Registered^.ValuesCopied or (fpc_threadvar_relocate_proc = nil) then
    Exit;
  Registered^.ValuesCopied := True;
  for TableIndex := 1 to Registered^.ThreadvarTables^.count do
    if Registered^.OwnThreadvarTables[TableIndex] then
    begin
      Entry := Registered^.ThreadvarTables^.tables[TableIndex]^;
      while Entry^.varaddr <> nil do
      begin
        Move(Pointer(PtrUInt(Entry^.varaddr) + SizeOf(Pointer))^, ThreadvarLibraryAddress(Entry^.varaddr^)^,
          Entry^.size);
        Inc(Entry);
      end;
    end;
end;

procedure CopyThreadvarLibraryValues;
var
  Index: LongInt;
begin
  for Index := 0 to FreePascalLibraryCount - 1 do
    CopyLibraryThreadvarValues(FreePascalLibraries[Index]);
end;

{ True if List has a table whose records start where Entry's do. }
function ResourceTableIsListed(List: PResourceTableList; constref Entry: TResourceTableEntry): Boolean;
var
  Index: SizeInt;
begin
  ResourceTableIsListed := False;
  if List = nil then
    Exit;
  for Index := 0 to List^.Count - 1 do
    if (List^.Tables[Index].TableStart <> nil) and (Entry.TableStart <> nil) and
       (List^.Tables[Index].TableStart^ = Entry.TableStart^) then
    begin
      ResourceTableIsListed := True;
      Exit;
    end;
end;

{ The program's resource string tables (and those added before) with the
  library's own ones after them. }
procedure MergeResourceTables(Library_: PResourceTableList);
var
  Current: PResourceTableList;
  Merged: PResourceTableList;
  Index: SizeInt;
  Count: SizeInt;
begin
  if (Library_ = nil) or (Library_^.Count <= 0) then
    Exit;
  Current := PResourceTableList(FPCResourceStringTables);
  Count := 0;
  if Current <> nil then
    Count := Current^.Count;
  Merged := PResourceTableList(GetMem(SizeOf(SizeInt) + (Count + Library_^.Count) * SizeOf(TResourceTableEntry)));
  Merged^.Count := Count;
  if Count > 0 then
    Move(Current^.Tables[0], Merged^.Tables[0], Count * SizeOf(TResourceTableEntry));
  for Index := 0 to Library_^.Count - 1 do
    if not ResourceTableIsListed(Merged, Library_^.Tables[Index]) then
    begin
      Merged^.Tables[Merged^.Count] := Library_^.Tables[Index];
      Inc(Merged^.Count);
    end;
  if Merged^.Count = Count then
  begin
    FreeMem(Merged);
    Exit;
  end;
  FPCResourceStringTables := Merged;
  if MergedResourceTables <> nil then
    FreeMem(MergedResourceTables);
  MergedResourceTables := Merged;
end;

function ResourceInitTableIsListed(List: PResourceInitTableList; Table: Pointer): Boolean;
var
  Index: SizeInt;
begin
  ResourceInitTableIsListed := False;
  if List = nil then
    Exit;
  for Index := 1 to List^.Count do
    if List^.Tables[Index] = Table then
    begin
      ResourceInitTableIsListed := True;
      Exit;
    end;
end;

{ The same for the constants initialized with resource strings. }
procedure MergeResourceInitTables(Library_: PResourceInitTableList);
var
  Current: PResourceInitTableList;
  Merged: PResourceInitTableList;
  Index: SizeInt;
  Count: SizeInt;
begin
  if (Library_ = nil) or (Library_^.Count <= 0) then
    Exit;
  Current := PResourceInitTableList(FPCResStrInitTables);
  Count := 0;
  if Current <> nil then
    Count := Current^.Count;
  Merged := PResourceInitTableList(GetMem(SizeOf(SizeInt) + (Count + Library_^.Count) * SizeOf(Pointer)));
  Merged^.Count := Count;
  if Count > 0 then
    Move(Current^.Tables[1], Merged^.Tables[1], Count * SizeOf(Pointer));
  for Index := 1 to Library_^.Count do
    if not ResourceInitTableIsListed(Merged, Library_^.Tables[Index]) then
    begin
      Merged^.Tables[Merged^.Count + 1] := Library_^.Tables[Index];
      Inc(Merged^.Count);
    end;
  if Merged^.Count = Count then
  begin
    FreeMem(Merged);
    Exit;
  end;
  FPCResStrInitTables := Merged;
  if MergedResourceInitTables <> nil then
    FreeMem(MergedResourceInitTables);
  MergedResourceInitTables := Merged;
end;

function SysRegisterLibrary(InitFinalTable, ThreadvarTables, ResourceStringTables,
  ResourceStringInitTables: Pointer): Pointer;
var
  Registered: PFreePascalLibrary;
  Index: ALUUInt;
  TableIndex: DWord;
begin
  SysRegisterLibrary := nil;
  if FreePascalLibraryCount >= FreePascalLibraryLimit then
    RunError(226);
  New(Registered);
  FillChar(Registered^, SizeOf(Registered^), 0);
  Registered^.InitFinalTable := PInitFinalTable(InitFinalTable);
  Registered^.ThreadvarTables := PltvInitTablesTable(ThreadvarTables);

  { Which units and threadvar lists are the library's own; decided
    before it joins the list it is compared with. }
  if Registered^.InitFinalTable <> nil then
  begin
    Registered^.OwnUnits := AllocateFlags(ALUUInt(Registered^.InitFinalTable^.TableCount));
    for Index := 1 to ALUUInt(Registered^.InitFinalTable^.TableCount) do
      Registered^.OwnUnits[Index] := (UnitIdentity(Registered^.InitFinalTable^.Procs[Index]) <> nil) and
        not UnitIsKnown(UnitIdentity(Registered^.InitFinalTable^.Procs[Index]));
  end;
  if Registered^.ThreadvarTables <> nil then
  begin
    Registered^.OwnThreadvarTables := AllocateFlags(Registered^.ThreadvarTables^.count);
    for TableIndex := 1 to Registered^.ThreadvarTables^.count do
      Registered^.OwnThreadvarTables[TableIndex] :=
        not ThreadvarListIsKnown(Registered^.ThreadvarTables^.tables[TableIndex]^);
  end;
  FreePascalLibraries[FreePascalLibraryCount] := Registered;
  Inc(FreePascalLibraryCount);

  LayOutLibraryThreadvars(Registered);
  CopyLibraryThreadvarValues(Registered);
  MergeResourceTables(PResourceTableList(ResourceStringTables));
  MergeResourceInitTables(PResourceInitTableList(ResourceStringInitTables));

  if Registered^.InitFinalTable <> nil then
    for Index := 1 to ALUUInt(Registered^.InitFinalTable^.TableCount) do
      if Registered^.OwnUnits[Index] and Assigned(Registered^.InitFinalTable^.Procs[Index].InitProc) then
        Registered^.InitFinalTable^.Procs[Index].InitProc();
  SysRegisterLibrary := Registered;
end;

procedure SysUnregisterLibrary(Registration: Pointer);
var
  Registered: PFreePascalLibrary;
  Index: ALUUInt;
begin
  Registered := PFreePascalLibrary(Registration);
  if (Registered = nil) or (Registered^.InitFinalTable = nil) then
    Exit;
  Index := ALUUInt(Registered^.InitFinalTable^.TableCount);
  while Index >= 1 do
  begin
    if Registered^.OwnUnits[Index] and Assigned(Registered^.InitFinalTable^.Procs[Index].FinalProc) then
      Registered^.InitFinalTable^.Procs[Index].FinalProc();
    Dec(Index);
  end;
end;
