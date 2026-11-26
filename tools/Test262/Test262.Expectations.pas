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
  The tests known to fail (tools/Test262/expectations.txt): one path
  per line, relative to test262's test/ directory, "#" starting a
  comment (the sections name the reason or the directory; a comment
  after a path is the error it failed with when the list was written).
  The runner reports only the failures not listed and the listed tests
  that pass now.
}
unit Test262.Expectations;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  Classes;

type
  TExpectations = class
  private
    FFailing: TStringList;
    function GetCount: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    { Reads the list; a missing file is an empty list. }
    procedure Load(const Path: string);
    function ExpectsFailure(const RelativePath: string): Boolean;
    property Count: Integer read GetCount;
  end;

{ Writes a new list: Paths (sorted) with their Messages, a section per
  top-level directory pair. }
procedure WriteExpectations(const Path: string; Paths, Messages: TStrings);

{ The first two components of a test path ("built-ins/Array"), or the
  first when there is only one directory. }
function GroupOf(const RelativePath: string): string;

implementation

constructor TExpectations.Create;
begin
  inherited Create;
  FFailing := TStringList.Create;
  FFailing.Sorted := True;
  FFailing.Duplicates := dupIgnore;
end;

destructor TExpectations.Destroy;
begin
  FFailing.Free;
  inherited Destroy;
end;

procedure TExpectations.Load(const Path: string);
var
  Lines: TStringList;
  Index, CommentAt: Integer;
  Line: string;
begin
  if not FileExists(Path) then
    Exit;
  Lines := TStringList.Create;
  try
    Lines.LoadFromFile(Path);
    for Index := 0 to Lines.Count - 1 do
    begin
      Line := Lines[Index];
      CommentAt := Pos('#', Line);
      if CommentAt > 0 then
        Line := Copy(Line, 1, CommentAt - 1);
      Line := Trim(Line);
      if Line <> '' then
        FFailing.Add(Line);
    end;
  finally
    Lines.Free;
  end;
end;

function TExpectations.ExpectsFailure(const RelativePath: string): Boolean;
var
  Index: Integer;
begin
  Result := FFailing.Find(RelativePath, Index);
end;

function TExpectations.GetCount: Integer;
begin
  Result := FFailing.Count;
end;

function GroupOf(const RelativePath: string): string;
var
  First, Second: Integer;
begin
  First := Pos('/', RelativePath);
  if First = 0 then
    Exit(RelativePath);
  Second := Pos('/', RelativePath, First + 1);
  if Second = 0 then
    Exit(Copy(RelativePath, 1, First - 1));
  Result := Copy(RelativePath, 1, Second - 1);
end;

procedure WriteExpectations(const Path: string; Paths, Messages: TStrings);
const
  MessageWidth = 120;
var
  Output: TStringList;
  Index, Cut: Integer;
  Group, LastGroup, Message: string;
begin
  Output := TStringList.Create;
  try
    Output.Add('# test262 tests libjavascript is known to fail (see docs/Architecture.md,');
    Output.Add('# "test262"). Written by make test262-expectations; a path per line, the');
    Output.Add('# comment after it the error it failed with.');
    LastGroup := '';
    for Index := 0 to Paths.Count - 1 do
    begin
      Group := GroupOf(Paths[Index]);
      if Group <> LastGroup then
      begin
        Output.Add('');
        Output.Add('# ' + Group);
        LastGroup := Group;
      end;
      Message := StringReplace(Messages[Index], '#', '', [rfReplaceAll]);
      if Length(Message) > MessageWidth then
      begin
        { Cut before a UTF-8 sequence, not inside one. }
        Cut := MessageWidth + 1;
        while (Cut > 1) and ((Ord(Message[Cut]) and $C0) = $80) do
          Dec(Cut);
        Message := Copy(Message, 1, Cut - 1) + '...';
      end;
      Output.Add(Paths[Index] + '  # ' + Message);
    end;
    Output.SaveToFile(Path);
  finally
    Output.Free;
  end;
end;

end.
