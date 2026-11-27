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
  The file work of a recursive wget: a fetched page read whole (its
  links are looked for), a converted page written back, the folders a
  file goes in made, and a rejected file removed.
}
unit Wget.FileText;

{$mode objfpc}
{$H+}

interface

{ The file's bytes; False if it cannot be read. }
function ReadFileText(const Path: string; out Text: string): Boolean;
function WriteFileText(const Path, Text: string): Boolean;
{ Makes each folder of Path that is missing ("a/b/c" makes a, a/b and
  a/b/c). }
procedure MakeFolders(const Path: string);
procedure RemoveFile(const Path: string);

implementation

uses
  Classes,
  SysUtils,
  Sys.Files;

function ReadFileText(const Path: string; out Text: string): Boolean;
var
  Stream: TFileStream;
begin
  Text := '';
  try
    Stream := TFileStream.Create(Path, fmOpenRead);
    try
      SetLength(Text, Stream.Size);
      if Length(Text) > 0 then
        Stream.ReadBuffer(Text[1], Length(Text));
    finally
      Stream.Free;
    end;
    Result := True;
  except
    on EStreamError do
      Result := False;
  end;
end;

function WriteFileText(const Path, Text: string): Boolean;
var
  Stream: TFileStream;
begin
  try
    Stream := TFileStream.Create(Path, fmCreate);
    try
      if Length(Text) > 0 then
        Stream.WriteBuffer(Text[1], Length(Text));
    finally
      Stream.Free;
    end;
    Result := True;
  except
    on EStreamError do
      Result := False;
  end;
end;

procedure MakeFolders(const Path: string);
var
  Index: Integer;
  Partial: string;
begin
  if Path = '' then
    Exit;
  for Index := 1 to Length(Path) do
    if (Path[Index] = '/') and (Index > 1) then
    begin
      Partial := Copy(Path, 1, Index - 1);
      if not IsDirectory(PChar(Partial)) then
        CreateDirectory(PChar(Partial));
    end;
  if not IsDirectory(PChar(Path)) then
    CreateDirectory(PChar(Path));
end;

procedure RemoveFile(const Path: string);
begin
  RemovePath(PChar(Path));
end;

end.
