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
{$H+}

interface

type
  TOutputTarget = record
    Name: string;
    IsStandardOutput: Boolean;
    Handle: Int64;
    IsOpen: Boolean;
  end;

{ Name, or the first of Name.1, Name.2 ... that does not exist. }
function ChooseUniqueName(const Name: string): string;
{ The size of an existing regular file, else 0. }
function ExistingFileSize(const Name: string): Int64;
{ Opens the target: appending when Append, else emptied. Standard
  output needs no opening. Returns a system error code. }
function OpenOutput(var Target: TOutputTarget; Append: Boolean): LongInt;
function WriteOutput(var Target: TOutputTarget; Data: Pointer; Length: PtrUInt): LongInt;
procedure CloseOutput(var Target: TOutputTarget);

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files;

function ChooseUniqueName(const Name: string): string;
var
  Suffix: LongWord;
begin
  Result := Name;
  Suffix := 1;
  while PathExists(PChar(Result)) do
  begin
    Result := Name + '.' + IntToStr(Suffix);
    Inc(Suffix);
  end;
end;

function ExistingFileSize(const Name: string): Int64;
var
  Information: TFileInformation;
begin
  Result := 0;
  if GetFileInformation(PChar(Name), Information) <> ErrorNone then
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
  Target.Handle := OpenFile(PChar(Target.Name), Flags);
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
