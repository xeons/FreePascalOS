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
  Naming the routines of a user back trace (Processes.UserBackTrace).

  The routine holding an address is the function symbol with the
  highest value at or below it that, if it has a size, still covers it
  (of two at the same value, one with a size wins: Free Pascal's main
  and PASCALMAIN). The module file's .symtab is read once for all the
  addresses of the trace in that module, a chunk at a time, and only
  the winners' names are read from .strtab. A file without .symtab
  (stripped) leaves the dynamic symbols the loader kept in kernel
  memory (TLoadedModule.Symbols), which name a library's exported
  routines.
}
unit Processes.UserSymbols;

{$mode objfpc}
{$pointermath on}

interface

uses
  Elf64,
  Processes.ModuleFiles;

const
  SymbolNameCapacity = 96;

type
  TSymbolMatch = record
    Found: Boolean;
    { Link address and size of the routine. }
    Value: QWord;
    Size: QWord;
    NameOffset: LongWord;
    Name: array[0..SymbolNameCapacity - 1] of Char;
  end;
  PSymbolMatch = ^TSymbolMatch;

{ Matches each of the Count link addresses with the module file's
  .symtab; False if it has none. }
function MatchFileSymbols(constref ModuleFile: TModuleFile; Addresses: PQWord; Count: Integer;
  Matches: PSymbolMatch): Boolean;
{ The same with a dynamic symbol table in kernel memory, for addresses
  no file symbol was found for. }
procedure MatchDynamicSymbols(Symbols: PElf64Symbol; SymbolCount: LongWord; Strings: PChar; StringsSize: QWord;
  Addresses: PQWord; Count: Integer; Matches: PSymbolMatch);

implementation

uses
  Runtime.Memory,
  Memory.KernelHeap;

const
  SymbolTypeFunction = 2;
  { Symbols read from the file at a time. }
  SymbolChunkCount = 256;

{ Whether Symbol is a better routine for Address than Match. }
function IsBetterSymbol(constref Symbol: TElf64Symbol; Address: QWord; constref Match: TSymbolMatch): Boolean;
begin
  Result := False;
  if (SymbolType(Symbol) <> SymbolTypeFunction) or (Symbol.SectionIndex = SymbolUndefinedSection) or
     (Symbol.Value = 0) or (Symbol.Value > Address) then
    Exit;
  if (Symbol.Size <> 0) and (Address - Symbol.Value >= Symbol.Size) then
    Exit;
  if not Match.Found or (Symbol.Value > Match.Value) then
    Exit(True);
  Result := (Symbol.Value = Match.Value) and (Match.Size = 0) and (Symbol.Size <> 0);
end;

procedure ConsiderSymbol(constref Symbol: TElf64Symbol; Addresses: PQWord; Count: Integer; Matches: PSymbolMatch);
var
  Index: Integer;
begin
  for Index := 0 to Count - 1 do
    if IsBetterSymbol(Symbol, Addresses[Index], Matches[Index]) then
    begin
      Matches[Index].Found := True;
      Matches[Index].Value := Symbol.Value;
      Matches[Index].Size := Symbol.Size;
      Matches[Index].NameOffset := Symbol.NameOffset;
    end;
end;

procedure ReadMatchNames(constref ModuleFile: TModuleFile; constref Strings: TElf64SectionHeader;
  Count: Integer; Matches: PSymbolMatch);
var
  Index: Integer;
  Length: QWord;
begin
  for Index := 0 to Count - 1 do
  begin
    FillMemory(@Matches[Index].Name[0], SymbolNameCapacity, 0);
    if not Matches[Index].Found or (Matches[Index].NameOffset >= Strings.Size) then
      Continue;
    Length := Strings.Size - Matches[Index].NameOffset;
    if Length > SymbolNameCapacity - 1 then
      Length := SymbolNameCapacity - 1;
    if not ReadModuleFile(ModuleFile, Strings.FileOffset + Matches[Index].NameOffset, @Matches[Index].Name[0],
       Length) then
      Matches[Index].Found := False;
  end;
end;

function MatchFileSymbols(constref ModuleFile: TModuleFile; Addresses: PQWord; Count: Integer;
  Matches: PSymbolMatch): Boolean;
var
  Table: TElf64SectionHeader;
  Strings: TElf64SectionHeader;
  Chunk: PElf64Symbol;
  Total: QWord;
  Done: QWord;
  Piece: QWord;
  Index: QWord;
begin
  Result := False;
  if not FindModuleSection(ModuleFile, '.symtab', Table) or (Table.SectionType <> ElfSectionTypeSymbolTable) or
     not ReadSectionHeader(ModuleFile, Table.Link, Strings) then
    Exit;
  Chunk := PElf64Symbol(AllocateKernelMemory(SymbolChunkCount * SizeOf(TElf64Symbol)));
  if Chunk = nil then
    Exit;
  Total := Table.Size div SizeOf(TElf64Symbol);
  Done := 0;
  Result := True;
  while Done < Total do
  begin
    Piece := Total - Done;
    if Piece > SymbolChunkCount then
      Piece := SymbolChunkCount;
    if not ReadModuleFile(ModuleFile, Table.FileOffset + Done * SizeOf(TElf64Symbol), Chunk,
       Piece * SizeOf(TElf64Symbol)) then
    begin
      Result := False;
      Break;
    end;
    Index := 0;
    while Index < Piece do
    begin
      ConsiderSymbol(Chunk[Index], Addresses, Count, Matches);
      Inc(Index);
    end;
    Done := Done + Piece;
  end;
  FreeKernelMemory(Chunk);
  if Result then
    ReadMatchNames(ModuleFile, Strings, Count, Matches);
end;

procedure MatchDynamicSymbols(Symbols: PElf64Symbol; SymbolCount: LongWord; Strings: PChar; StringsSize: QWord;
  Addresses: PQWord; Count: Integer; Matches: PSymbolMatch);
var
  Pending: PSymbolMatch;
  Index: Integer;
  SymbolIndex: LongWord;
  Name: PChar;
  NameLength: LongWord;
begin
  if (Symbols = nil) or (Strings = nil) or (Count <= 0) then
    Exit;
  Pending := PSymbolMatch(AllocateZeroedKernelMemory(QWord(Count) * SizeOf(TSymbolMatch)));
  if Pending = nil then
    Exit;
  SymbolIndex := 0;
  while SymbolIndex < SymbolCount do
  begin
    ConsiderSymbol(Symbols[SymbolIndex], Addresses, Count, Pending);
    Inc(SymbolIndex);
  end;
  for Index := 0 to Count - 1 do
  begin
    if Matches[Index].Found or not Pending[Index].Found or (Pending[Index].NameOffset >= StringsSize) then
      Continue;
    Matches[Index] := Pending[Index];
    FillMemory(@Matches[Index].Name[0], SymbolNameCapacity, 0);
    Name := Strings + Pending[Index].NameOffset;
    NameLength := 0;
    while (NameLength < SymbolNameCapacity - 1) and (Pending[Index].NameOffset + NameLength < StringsSize) and
          (Name[NameLength] <> #0) do
    begin
      Matches[Index].Name[NameLength] := Name[NameLength];
      Inc(NameLength);
    end;
  end;
  FreeKernelMemory(Pending);
end;

end.
