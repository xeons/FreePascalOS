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
  The tests not run, and why:
  - those of a feature in tools/Test262/skipped-features.txt (proposals
    the engine does not implement yet; the file says why for each);
  - those needing what this host cannot give: $262.agent (concurrent
    agents sharing memory: the engine has none) and CanBlockIsTrue (the
    main thread here cannot block in Atomics.wait, so the CanBlockIsFalse
    tests are the ones that apply), and IsHTMLDDA (the engine has no
    object with [[IsHTMLDDA]], so $262.IsHTMLDDA is absent and, as
    INTERPRETING.md says, the tests of that feature do not apply).
}
unit Test262.Skips;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  Classes,
  Test262.Frontmatter;

type
  TSkipList = class
  private
    FFeatures: TStringList;
  public
    constructor Create;
    destructor Destroy; override;
    { Reads the features file: a feature per line, "#" comments. }
    procedure Load(const Path: string);
    { Why the test is not run ('' when it is). }
    function ReasonToSkip(const Metadata: TTestMetadata; const Source: string): string;
  end;

implementation

constructor TSkipList.Create;
begin
  inherited Create;
  FFeatures := TStringList.Create;
  FFeatures.Sorted := True;
  FFeatures.Duplicates := dupIgnore;
end;

destructor TSkipList.Destroy;
begin
  FFeatures.Free;
  inherited Destroy;
end;

procedure TSkipList.Load(const Path: string);
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
        FFeatures.Add(Line);
    end;
  finally
    Lines.Free;
  end;
end;

function TSkipList.ReasonToSkip(const Metadata: TTestMetadata; const Source: string): string;
var
  Index, Found: Integer;
begin
  for Index := 0 to High(Metadata.Features) do
    if FFeatures.Find(Metadata.Features[Index], Found) then
      Exit('feature ' + Metadata.Features[Index]);
  if HasFeature(Metadata, 'IsHTMLDDA') then
    Exit('IsHTMLDDA');
  if tfCanBlockIsTrue in Metadata.Flags then
    Exit('CanBlockIsTrue');
  if Pos('$262.agent', Source) > 0 then
    Exit('$262.agent');
  Result := '';
end;

end.
