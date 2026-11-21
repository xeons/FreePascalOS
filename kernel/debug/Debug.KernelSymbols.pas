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
  The kernel's own symbol table: which routine an address of kernel code
  belongs to, so back traces name routines ("Kernel.Panic.KernelAssert
  +0x2C") rather than print bare addresses.

  The build writes the table (scripts/make-kernel-symbols.py, which has
  its layout) and links it into the kernel's read-only data as
  KernelSymbolTable: the routines' start addresses, sorted, each with its
  unit's and its own name as written in the sources. A lookup is a
  binary search; nothing here allocates or takes a lock, so it works in
  a panic.
}
unit Debug.KernelSymbols;

{$mode objfpc}
{$pointermath on}

interface

{ Whether the kernel carries a symbol table with any routine. }
function KernelSymbolsArePresent: Boolean;

{ Whether Address lies in the kernel's code. }
function IsKernelCodeAddress(Address: QWord): Boolean;

{ The routine Address lies in: its unit (nil for routines outside a
  unit, written in assembly), its name and how far into it Address is.
  False if Address is not in the kernel's code or there is no table. }
function FindKernelSymbol(Address: QWord; out UnitName, RoutineName: PChar;
  out Offset: QWord): Boolean;

{ Writes "Unit.Routine+0x1C" for Address to the debug output, or "?". }
procedure DebugWriteKernelSymbol(Address: QWord);

implementation

uses
  Debug.Output;

const
  TableMagic = $4D59534B; { 'KSYM' }
  TableVersion = 1;
  NoUnit = $FFFFFFFF;

type
  TSymbolTableHeader = packed record
    Magic: LongWord;
    Version: LongWord;
    Count: LongWord;
    EntriesOffset: LongWord;
    NamesOffset: LongWord;
    NamesSize: LongWord;
    TextEndOffset: LongWord;
    Reserved: LongWord;
    TextBase: QWord;
  end;
  PSymbolTableHeader = ^TSymbolTableHeader;

  TSymbolEntry = packed record
    AddressOffset: LongWord;
    UnitNameOffset: LongWord;
    RoutineNameOffset: LongWord;
  end;
  PSymbolEntry = ^TSymbolEntry;

var
  KernelSymbolTable: TSymbolTableHeader; external name 'KernelSymbolTable';
  KernelImageStart: Byte; external name 'KernelImageStart';
  KernelTextEnd: Byte; external name 'KernelTextEnd';

function Table: PSymbolTableHeader;
begin
  Result := @KernelSymbolTable;
end;

function KernelSymbolsArePresent: Boolean;
begin
  Result := (Table^.Magic = TableMagic) and (Table^.Version = TableVersion) and (Table^.Count > 0);
end;

function IsKernelCodeAddress(Address: QWord): Boolean;
begin
  Result := (Address >= QWord(@KernelImageStart)) and (Address < QWord(@KernelTextEnd));
end;

function EntryAt(Index: LongWord): PSymbolEntry;
begin
  Result := PSymbolEntry(PByte(Table) + Table^.EntriesOffset) + Index;
end;

function NameAt(Offset: LongWord): PChar;
begin
  if (Offset = NoUnit) or (Offset >= Table^.NamesSize) then
    Exit(nil);
  Result := PChar(PByte(Table) + Table^.NamesOffset + Offset);
end;

{ The index of the last entry starting at or before Relative. }
function FindEntryIndex(Relative: QWord; out Index: LongWord): Boolean;
var
  Low: LongWord;
  High: LongWord;
  Middle: LongWord;
begin
  Result := False;
  Index := 0;
  if (Table^.Count = 0) or (Relative < EntryAt(0)^.AddressOffset) then
    Exit;
  { Invariant: entry Low starts at or before Relative, every entry from
    High on after it. }
  Low := 0;
  High := Table^.Count;
  while High - Low > 1 do
  begin
    Middle := Low + (High - Low) div 2;
    if EntryAt(Middle)^.AddressOffset <= Relative then
      Low := Middle
    else
      High := Middle;
  end;
  Index := Low;
  Result := True;
end;

function FindKernelSymbol(Address: QWord; out UnitName, RoutineName: PChar;
  out Offset: QWord): Boolean;
var
  Relative: QWord;
  Index: LongWord;
  Entry: PSymbolEntry;
begin
  UnitName := nil;
  RoutineName := nil;
  Offset := 0;
  Result := False;
  if not KernelSymbolsArePresent or not IsKernelCodeAddress(Address) or
     (Address < Table^.TextBase) then
    Exit;
  Relative := Address - Table^.TextBase;
  if Relative >= Table^.TextEndOffset then
    Exit;
  if not FindEntryIndex(Relative, Index) then
    Exit;
  Entry := EntryAt(Index);
  UnitName := NameAt(Entry^.UnitNameOffset);
  RoutineName := NameAt(Entry^.RoutineNameOffset);
  Offset := Relative - Entry^.AddressOffset;
  Result := RoutineName <> nil;
end;

procedure DebugWriteKernelSymbol(Address: QWord);
var
  UnitName: PChar;
  RoutineName: PChar;
  Offset: QWord;
begin
  DebugBeginMessage;
  if FindKernelSymbol(Address, UnitName, RoutineName, Offset) then
  begin
    if UnitName <> nil then
    begin
      DebugWrite(UnitName);
      DebugWrite('.');
    end;
    DebugWrite(RoutineName);
    DebugWrite('+0x');
    DebugWriteHex(Offset, 1);
  end
  else
    DebugWrite('?');
  DebugEndMessage;
end;

end.
