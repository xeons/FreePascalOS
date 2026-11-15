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
  Kernel command line options.

  The loader passes a line of space separated words (from the file
  \FreePascalOS\options.txt on the boot volume). Options are either flags
  ("test-exit") or name=value pairs ("root=disk0p2").

  Known options:
    test-exit   Exit the emulator when startup finishes or the kernel
                panics, reporting success or failure (used by make test).
    kshell      Run the kernel debug shell (Kernel.DebugShell) on the
                console before the first program starts.
}
unit Kernel.Options;

{$mode objfpc}

interface

uses
  Boot.Information;

const
  OptionTestExit = 'test-exit';
  OptionKernelShell = 'kshell';
  { Run the file system write tests on the test volumes (they change
    them, and leave journaled ones read-only after a simulated crash). }
  OptionFileSystemWriteTests = 'fstest';

procedure InitializeKernelOptions(const BootInformation: TBootInformation);

function KernelOptionIsSet(Name: PChar): Boolean;

{ Copies the value of a name=value option into Value. Returns False if
  the option is absent. }
function GetKernelOptionValue(Name: PChar; Value: PChar; ValueCapacity: PtrUInt): Boolean;
{ The value of option Name as a decimal number; False if the option is
  missing or its value is not a number. }
function GetKernelOptionNumber(Name: PChar; out Number: QWord): Boolean;

function KernelCommandLine: PChar;

implementation

uses
  Runtime.Text;

var
  CommandLine: array[0..CommandLineCapacity - 1] of Char;

procedure InitializeKernelOptions(const BootInformation: TBootInformation);
begin
  CopyText(@CommandLine[0], @BootInformation.CommandLine[0], CommandLineCapacity);
end;

function KernelCommandLine: PChar;
begin
  Result := @CommandLine[0];
end;

{ Finds the word that starts with Name, followed by Terminator or by the
  end of the word. Returns a pointer just past the name, or nil. }
function FindOption(Name: PChar; AllowValue: Boolean): PChar;
var
  WordStart: PChar;
  NameLength: PtrUInt;
  Index: PtrUInt;
  Matches: Boolean;
  AfterName: Char;
begin
  NameLength := TextLength(Name);
  WordStart := @CommandLine[0];

  while WordStart^ <> #0 do
  begin
    while WordStart^ = ' ' do
      Inc(WordStart);
    if WordStart^ = #0 then
      Break;

    Matches := True;
    Index := 0;
    while (Index < NameLength) and Matches do
    begin
      if WordStart[Index] <> Name[Index] then
        Matches := False;
      Inc(Index);
    end;

    if Matches then
    begin
      AfterName := WordStart[NameLength];
      if (AfterName = #0) or (AfterName = ' ') then
        Exit(@WordStart[NameLength]);
      if AllowValue and (AfterName = '=') then
        Exit(@WordStart[NameLength]);
    end;

    while (WordStart^ <> ' ') and (WordStart^ <> #0) do
      Inc(WordStart);
  end;

  Result := nil;
end;

function GetKernelOptionNumber(Name: PChar; out Number: QWord): Boolean;
const
  NumberCapacity = 21;
var
  Value: array[0..NumberCapacity - 1] of Char;
  Index: Integer;
begin
  Number := 0;
  Result := False;
  if not GetKernelOptionValue(Name, @Value[0], NumberCapacity) then
    Exit;
  Index := 0;
  while Value[Index] in ['0'..'9'] do
  begin
    Number := Number * 10 + QWord(Ord(Value[Index]) - Ord('0'));
    Inc(Index);
  end;
  Result := (Index > 0) and (Value[Index] = #0);
  if not Result then
    Number := 0;
end;

function KernelOptionIsSet(Name: PChar): Boolean;
begin
  Result := FindOption(Name, False) <> nil;
end;

function GetKernelOptionValue(Name: PChar; Value: PChar; ValueCapacity: PtrUInt): Boolean;
var
  AfterName: PChar;
  Length: PtrUInt;
begin
  Result := False;
  if ValueCapacity = 0 then
    Exit;

  AfterName := FindOption(Name, True);
  if (AfterName = nil) or (AfterName^ <> '=') then
    Exit;
  Inc(AfterName);

  Length := 0;
  while (AfterName[Length] <> ' ') and (AfterName[Length] <> #0) and (Length + 1 < ValueCapacity) do
  begin
    Value[Length] := AfterName[Length];
    Inc(Length);
  end;
  Value[Length] := #0;
  Result := True;
end;

end.
