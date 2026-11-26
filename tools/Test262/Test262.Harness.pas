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
  test262's harness/ directory, read once before the tests start (the
  processes running them inherit it): assert.js and sta.js go before
  every test that is not raw, doneprintHandle.js before asynchronous
  ones, then the test's own includes.
}
unit Test262.Harness;

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  THarnessLibrary = class
  private
    FNames: array of string;
    FSources: array of string;
    procedure AddDirectory(const Directory, Prefix: string);
  public
    constructor Create(const HarnessDirectory: string);
    { The file's source; False when harness/ has no such file. }
    function Find(const Name: string; out Source: string): Boolean;
  end;

implementation

uses
  Test262.Host;

constructor THarnessLibrary.Create(const HarnessDirectory: string);
begin
  inherited Create;
  AddDirectory(IncludeTrailingPathDelimiter(HarnessDirectory), '');
end;

{ The files of Directory and its subdirectories, named by their path
  under harness/ ("sm/non262.js"). }
procedure THarnessLibrary.AddDirectory(const Directory, Prefix: string);
var
  Search: TSearchRec;
begin
  if FindFirst(Directory + '*', faAnyFile, Search) <> 0 then
    Exit;
  repeat
    if (Search.Name = '.') or (Search.Name = '..') then
      Continue;
    if (Search.Attr and faDirectory) <> 0 then
      AddDirectory(Directory + Search.Name + '/', Prefix + Search.Name + '/')
    else if ExtractFileExt(Search.Name) = '.js' then
    begin
      SetLength(FNames, Length(FNames) + 1);
      SetLength(FSources, Length(FSources) + 1);
      FNames[High(FNames)] := Prefix + Search.Name;
      FSources[High(FSources)] := ReadFileText(Directory + Search.Name);
    end;
  until FindNext(Search) <> 0;
  FindClose(Search);
end;

function THarnessLibrary.Find(const Name: string; out Source: string): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(FNames) do
    if FNames[Index] = Name then
    begin
      Source := FSources[Index];
      Exit(True);
    end;
  Source := '';
  Result := False;
end;

end.
