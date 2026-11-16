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
  Where wget writes what it fetches: a file named after the URL (made
  unique with ".1", ".2"... when one of that name exists, as GNU wget
  does, unless continuing), the file given with -O, or standard output
  for "-O -".
}
unit Wget.Files;

{$mode objfpc}
{$pointermath on}

interface

const
  FileNameCapacity = 1024;

type
  TOutputTarget = record
    Name: array[0..FileNameCapacity - 1] of Char;
    IsStandardOutput: Boolean;
    Handle: Int64;
    IsOpen: Boolean;
  end;

procedure SetOutputName(var Target: TOutputTarget; Name: PChar);
{ Name, or the first of Name.1, Name.2 ... that does not exist. }
procedure ChooseUniqueName(Name: PChar; Buffer: PChar; Capacity: PtrUInt);
{ The size of an existing regular file, else 0. }
function ExistingFileSize(Name: PChar): Int64;
{ Opens the target: appending when Append, else emptied. Standard
  output needs no opening. Returns a system error code. }
function OpenOutput(var Target: TOutputTarget; Append: Boolean): LongInt;
function WriteOutput(var Target: TOutputTarget; Data: Pointer; Length: PtrUInt): LongInt;
procedure CloseOutput(var Target: TOutputTarget);

implementation

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Files;

procedure SetOutputName(var Target: TOutputTarget; Name: PChar);
begin
  CopyText(@Target.Name[0], Name, SizeOf(Target.Name));
end;

procedure ChooseUniqueName(Name: PChar; Buffer: PChar; Capacity: PtrUInt);
var
  Suffix: LongWord;
  Number: TNumberText;
  Position, Index: PtrUInt;
  Digits: PChar;
begin
  CopyText(Buffer, Name, Capacity);
  if not PathExists(Buffer) then
    Exit;
  Suffix := 1;
  repeat
    CopyText(Buffer, Name, Capacity);
    Position := TextLength(Buffer);
    Digits := FormatDecimal(Suffix, Number);
    if Position + 1 + TextLength(Digits) + 1 > Capacity then
      Exit;
    Buffer[Position] := '.';
    Inc(Position);
    Index := 0;
    while Digits[Index] <> #0 do
    begin
      Buffer[Position] := Digits[Index];
      Inc(Position);
      Inc(Index);
    end;
    Buffer[Position] := #0;
    Inc(Suffix);
  until not PathExists(Buffer);
end;

function ExistingFileSize(Name: PChar): Int64;
var
  Information: TFileInformation;
begin
  Result := 0;
  if GetFileInformation(Name, Information) <> ErrorNone then
    Exit;
  if Information.Kind <> KindFile then
    Exit;
  Result := Int64(Information.SizeInBytes);
end;

function OpenOutput(var Target: TOutputTarget; Append: Boolean): LongInt;
var
  Flags: LongWord;
begin
  if Target.IsOpen then
    Exit(ErrorNone);
  if Target.IsStandardOutput then
  begin
    Target.Handle := StandardOutputHandle;
    Target.IsOpen := True;
    Exit(ErrorNone);
  end;
  Flags := OpenWrite or OpenCreate;
  if Append then
    Flags := Flags or OpenAppend
  else
    Flags := Flags or OpenTruncate;
  Target.Handle := OpenFile(@Target.Name[0], Flags);
  if Target.Handle < 0 then
    Exit(LongInt(-Target.Handle));
  Target.IsOpen := True;
  Result := ErrorNone;
end;

function WriteOutput(var Target: TOutputTarget; Data: Pointer; Length: PtrUInt): LongInt;
begin
  Result := WriteAll(Target.Handle, Data, Length);
end;

procedure CloseOutput(var Target: TOutputTarget);
begin
  if Target.IsOpen and not Target.IsStandardOutput then
    CloseFile(Target.Handle);
  Target.IsOpen := False;
end;

end.
