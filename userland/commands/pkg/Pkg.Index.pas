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
  A repository's index (INDEX), as `scripts/ports.py repo` writes it
  (scripts/portstool/repository.py describes the format): a block per
  package with its version, architecture, dependencies, file name, size
  and SHA-256.
}
unit Pkg.Index;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  EIndexError = class(Exception);

  TIndexEntry = record
    Name: string;
    Version: string;
    Revision: Integer;
    Architecture: string;
    Origin: string;
    Summary: string;
    License: string;
    Depends: TStringArray;
    Provides: TStringArray;
    Conflicts: TStringArray;
    FileName: string;
    Size: Int64;
    Sha256: string;
    { Filled in by whoever reads it: which repository it came from. }
    Repository: string;
  end;

  TIndexEntries = array of TIndexEntry;

  TRepositoryIndex = class
  private
    FName: string;
    FEntries: TIndexEntries;
  public
    { Raises EIndexError. }
    constructor Create(const Text, RepositoryName: string);
    { The newest entry for Name (or a package providing it) built for
      Architecture; -1 if there is none. }
    function FindNewest(const Name, Architecture: string): Integer;
    property Name: string read FName;
    property Entries: TIndexEntries read FEntries;
  end;

function IndexEntryFullVersion(const Entry: TIndexEntry): string;
function IndexEntryProvides(const Entry: TIndexEntry; const Name: string): Boolean;

implementation

uses
  Pkg.Versions;

procedure AppendText(var Items: TStringArray; const Value: string);
begin
  SetLength(Items, Length(Items) + 1);
  Items[High(Items)] := Value;
end;

function IndexEntryFullVersion(const Entry: TIndexEntry): string;
begin
  Result := FullVersion(Entry.Version, Entry.Revision);
end;

function IndexEntryProvides(const Entry: TIndexEntry; const Name: string): Boolean;
var
  Index: Integer;
begin
  if Entry.Name = Name then
    Exit(True);
  for Index := 0 to High(Entry.Provides) do
    if Entry.Provides[Index] = Name then
      Exit(True);
  Result := False;
end;

procedure ClearEntry(out Entry: TIndexEntry);
begin
  Entry.Name := '';
  Entry.Version := '';
  Entry.Revision := 0;
  Entry.Architecture := '';
  Entry.Origin := '';
  Entry.Summary := '';
  Entry.License := '';
  Entry.Depends := nil;
  Entry.Provides := nil;
  Entry.Conflicts := nil;
  Entry.FileName := '';
  Entry.Size := -1;
  Entry.Sha256 := '';
  Entry.Repository := '';
end;

constructor TRepositoryIndex.Create(const Text, RepositoryName: string);
var
  Lines: TStringArray;
  LineIndex, Space: Integer;
  Key, Value: string;
  Current: TIndexEntry;
  InEntry, SeenFormat: Boolean;
begin
  inherited Create;
  FName := RepositoryName;
  FEntries := nil;
  InEntry := False;
  SeenFormat := False;
  ClearEntry(Current);
  Lines := Text.Split([#10]);
  for LineIndex := 0 to High(Lines) do
  begin
    if Lines[LineIndex] = '' then
      Continue;
    Space := Pos(' ', Lines[LineIndex]);
    if Space = 0 then
    begin
      Key := Lines[LineIndex];
      Value := '';
    end
    else
    begin
      Key := Copy(Lines[LineIndex], 1, Space - 1);
      Value := Copy(Lines[LineIndex], Space + 1, MaxInt);
    end;
    if Key = 'format' then
    begin
      if Value <> '1' then
        raise EIndexError.CreateFmt('index format %s is not 1', [Value]);
      SeenFormat := True;
    end
    else if Key = 'repository' then
      Continue
    else if Key = 'package' then
    begin
      if InEntry then
        raise EIndexError.CreateFmt('line %d: a package before the last one''s end', [LineIndex + 1]);
      ClearEntry(Current);
      Current.Name := Value;
      Current.Repository := RepositoryName;
      InEntry := True;
    end
    else if not InEntry then
      raise EIndexError.CreateFmt('line %d: %s outside a package', [LineIndex + 1, Key])
    else if Key = 'end' then
    begin
      if (Current.Name = '') or (Current.Version = '') or (Current.FileName = '') or (Current.Size < 0) or
        (Length(Current.Sha256) <> 64) then
        raise EIndexError.CreateFmt('line %d: package %s is incomplete', [LineIndex + 1, Current.Name]);
      if (Pos('/', Current.FileName) > 0) or (Pos('..', Current.FileName) > 0) then
        raise EIndexError.CreateFmt('line %d: unsafe file name %s', [LineIndex + 1, Current.FileName]);
      SetLength(FEntries, Length(FEntries) + 1);
      FEntries[High(FEntries)] := Current;
      InEntry := False;
    end
    else if Key = 'version' then
      Current.Version := Value
    else if Key = 'revision' then
    begin
      if not TryStrToInt(Value, Current.Revision) then
        raise EIndexError.CreateFmt('line %d: revision is a number', [LineIndex + 1]);
    end
    else if Key = 'architecture' then
      Current.Architecture := Value
    else if Key = 'origin' then
      Current.Origin := Value
    else if Key = 'summary' then
      Current.Summary := Value
    else if Key = 'license' then
      Current.License := Value
    else if Key = 'depend' then
      AppendText(Current.Depends, Value)
    else if Key = 'provide' then
      AppendText(Current.Provides, Value)
    else if Key = 'conflict' then
      AppendText(Current.Conflicts, Value)
    else if Key = 'file' then
      Current.FileName := Value
    else if Key = 'size' then
    begin
      if not TryStrToInt64(Value, Current.Size) then
        raise EIndexError.CreateFmt('line %d: size is a number', [LineIndex + 1]);
    end
    else if Key = 'sha256' then
      Current.Sha256 := LowerCase(Value);
    { Other keys are for later formats' additions and are passed over. }
  end;
  if not SeenFormat then
    raise EIndexError.Create('the index has no format line');
  if InEntry then
    raise EIndexError.Create('the index ends inside a package');
end;

function TRepositoryIndex.FindNewest(const Name, Architecture: string): Integer;
var
  Index: Integer;
begin
  Result := -1;
  { The package itself first; a provider only when there is none. }
  for Index := 0 to High(FEntries) do
    if (FEntries[Index].Name = Name) and (FEntries[Index].Architecture = Architecture) then
      if (Result < 0) or (CompareVersions(IndexEntryFullVersion(FEntries[Index]),
        IndexEntryFullVersion(FEntries[Result])) > 0) then
        Result := Index;
  if Result >= 0 then
    Exit;
  for Index := 0 to High(FEntries) do
    if IndexEntryProvides(FEntries[Index], Name) and (FEntries[Index].Architecture = Architecture) then
      if (Result < 0) or (CompareVersions(IndexEntryFullVersion(FEntries[Index]),
        IndexEntryFullVersion(FEntries[Result])) > 0) then
        Result := Index;
end;

end.
