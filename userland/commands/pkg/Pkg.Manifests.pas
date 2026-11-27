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
  A package's manifest (+MANIFEST), as the ports tool writes it
  (scripts/portstool/manifest.py describes the format): what the
  package is, what it needs, and every folder, file and link it
  installs, with each file's mode, size and SHA-256.
}
unit Pkg.Manifests;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

const
  ManifestFormatVersion = '1';

type
  EManifestError = class(Exception);

  TManifestEntryKind = (EntryDirectory, EntryFile, EntryLink);

  TManifestEntry = record
    Kind: TManifestEntryKind;
    { Relative to the root: usr/local/bin/ptop. }
    Path: string;
    Mode: LongWord;
    Size: Int64;
    { Lower case hex. }
    Sha256: string;
    { Links only. }
    Target: string;
  end;

  TManifestEntries = array of TManifestEntry;

  { A package's install or removal script: its kind (pre-install,
    post-install, pre-remove, post-remove) and its text. }
  TPackageScript = record
    Kind: string;
    Text: string;
  end;

  TPackageScripts = array of TPackageScript;

  TPackageManifest = class
  private
    FText: string;
    procedure ParseLine(const Line: string; Number: Integer);
    procedure AddEntry(const Entry: TManifestEntry);
  public
    Name: string;
    Version: string;
    Revision: Integer;
    Origin: string;
    Flavor: string;
    Architecture: string;
    Prefix: string;
    Summary: string;
    License: string;
    Maintainer: string;
    Homepage: string;
    Depends: TStringArray;
    Provides: TStringArray;
    Conflicts: TStringArray;
    Scripts: TStringArray;
    Tests: TStringArray;
    LicenseFiles: TStringArray;
    Entries: TManifestEntries;
    { Raises EManifestError. }
    constructor Create(const Text: string);
    function FullVersion: string;
    function HasScript(const Kind: string): Boolean;
    function ProvidesName(const AName: string): Boolean;
    { The index of the file or link entry for Path, or -1. }
    function FindPath(const Path: string): Integer;
    { The text it was read from, kept as the database's copy. }
    property Text: string read FText;
  end;

{ Whether a manifest path is relative, without '..' parts and without
  spaces or control characters. }
function IsSafePackagePath(const Path: string): Boolean;

implementation

uses
  Pkg.Versions;

procedure AppendText(var Items: TStringArray; const Value: string);
begin
  SetLength(Items, Length(Items) + 1);
  Items[High(Items)] := Value;
end;

function IsSafePackagePath(const Path: string): Boolean;
var
  Index: Integer;
  Parts: TStringArray;
begin
  if (Path = '') or (Path[1] = '/') then
    Exit(False);
  for Index := 1 to Length(Path) do
    if Path[Index] <= ' ' then
      Exit(False);
  Parts := Path.Split(['/']);
  for Index := 0 to High(Parts) do
    if (Parts[Index] = '..') or (Parts[Index] = '') then
      Exit(False);
  Result := True;
end;

function IsLowerHex(const Text: string): Boolean;
var
  Index: Integer;
begin
  for Index := 1 to Length(Text) do
    if not (Text[Index] in ['0'..'9', 'a'..'f']) then
      Exit(False);
  Result := True;
end;

{ The first word of Line and the rest after one space. }
procedure SplitKey(const Line: string; out Key, Rest: string);
var
  Space: Integer;
begin
  Space := Pos(' ', Line);
  if Space = 0 then
  begin
    Key := Line;
    Rest := '';
  end
  else
  begin
    Key := Copy(Line, 1, Space - 1);
    Rest := Copy(Line, Space + 1, MaxInt);
  end;
end;

constructor TPackageManifest.Create(const Text: string);
var
  Lines: TStringArray;
  Index: Integer;
  SeenFormat: Boolean;
begin
  inherited Create;
  FText := Text;
  Prefix := '/usr/local';
  SeenFormat := False;
  Lines := Text.Split([#10]);
  for Index := 0 to High(Lines) do
  begin
    if (Lines[Index] = '') or (Lines[Index][1] = '#') then
      Continue;
    if Copy(Lines[Index], 1, 7) = 'format ' then
    begin
      if Copy(Lines[Index], 8, MaxInt) <> ManifestFormatVersion then
        raise EManifestError.CreateFmt('line %d: manifest format %s is not %s',
          [Index + 1, Copy(Lines[Index], 8, MaxInt), ManifestFormatVersion]);
      SeenFormat := True;
      Continue;
    end;
    ParseLine(Lines[Index], Index + 1);
  end;
  if not SeenFormat then
    raise EManifestError.Create('the manifest has no format line');
  if (Name = '') or (Version = '') or (Architecture = '') then
    raise EManifestError.Create('the manifest lacks a name, version or architecture');
end;

procedure TPackageManifest.AddEntry(const Entry: TManifestEntry);
begin
  if not IsSafePackagePath(Entry.Path) then
    raise EManifestError.CreateFmt('unsafe path in the manifest: %s', [Entry.Path]);
  SetLength(Entries, Length(Entries) + 1);
  Entries[High(Entries)] := Entry;
end;

procedure TPackageManifest.ParseLine(const Line: string; Number: Integer);
var
  Key, Rest: string;
  Words: TStringArray;
  Entry: TManifestEntry;
  Dependency: TDependency;
  ModeValue: LongInt;

  procedure Need(Count: Integer);
  var
    WordIndex: Integer;
  begin
    if Length(Words) <> Count then
      raise EManifestError.CreateFmt('line %d: %s takes %d word(s)', [Number, Key, Count]);
    for WordIndex := 0 to High(Words) do
      if Words[WordIndex] = '' then
        raise EManifestError.CreateFmt('line %d: an empty word', [Number]);
  end;

  function OctalMode(const Text: string): LongWord;
  begin
    if not TryStrToInt('&' + Text, ModeValue) or (ModeValue < 0) or (ModeValue > &7777) then
      raise EManifestError.CreateFmt('line %d: %s is not a mode', [Number, Text]);
    Result := LongWord(ModeValue);
  end;

begin
  SplitKey(Line, Key, Rest);
  Words := Rest.Split([' ']);
  Entry.Mode := 0;
  Entry.Size := 0;
  Entry.Sha256 := '';
  Entry.Target := '';
  if Key = 'name' then
  begin
    Need(1);
    Name := Words[0];
  end
  else if Key = 'version' then
  begin
    Need(1);
    Version := Words[0];
  end
  else if Key = 'revision' then
  begin
    Need(1);
    if not TryStrToInt(Words[0], Revision) or (Revision < 0) then
      raise EManifestError.CreateFmt('line %d: revision is a number', [Number]);
  end
  else if Key = 'origin' then
  begin
    Need(1);
    Origin := Words[0];
  end
  else if Key = 'flavor' then
  begin
    Need(1);
    Flavor := Words[0];
  end
  else if Key = 'architecture' then
  begin
    Need(1);
    Architecture := Words[0];
  end
  else if Key = 'prefix' then
  begin
    Need(1);
    Prefix := Words[0];
  end
  else if Key = 'summary' then
    Summary := Rest
  else if Key = 'license' then
    License := Rest
  else if Key = 'maintainer' then
    Maintainer := Rest
  else if Key = 'homepage' then
    Homepage := Rest
  else if Key = 'depend' then
  begin
    if not ParseDependency(Rest, Dependency) then
      raise EManifestError.CreateFmt('line %d: not a dependency: %s', [Number, Rest]);
    AppendText(Depends, Rest);
  end
  else if Key = 'provide' then
  begin
    Need(1);
    AppendText(Provides, Words[0]);
  end
  else if Key = 'conflict' then
  begin
    Need(1);
    AppendText(Conflicts, Words[0]);
  end
  else if Key = 'script' then
  begin
    Need(1);
    if (Words[0] <> 'pre-install') and (Words[0] <> 'post-install') and (Words[0] <> 'pre-remove') and
      (Words[0] <> 'post-remove') then
      raise EManifestError.CreateFmt('line %d: unknown script %s', [Number, Words[0]]);
    AppendText(Scripts, Words[0]);
  end
  else if Key = 'test' then
    AppendText(Tests, Rest)
  else if Key = 'license-file' then
  begin
    Need(1);
    AppendText(LicenseFiles, Words[0]);
  end
  else if Key = 'dir' then
  begin
    Need(2);
    Entry.Kind := EntryDirectory;
    Entry.Mode := OctalMode(Words[0]);
    Entry.Path := Words[1];
    AddEntry(Entry);
  end
  else if Key = 'file' then
  begin
    Need(4);
    Entry.Kind := EntryFile;
    Entry.Mode := OctalMode(Words[0]);
    if not TryStrToInt64(Words[1], Entry.Size) or (Entry.Size < 0) then
      raise EManifestError.CreateFmt('line %d: %s is not a size', [Number, Words[1]]);
    if (Length(Words[2]) <> 64) or not IsLowerHex(Words[2]) then
      raise EManifestError.CreateFmt('line %d: a SHA-256 is 64 hex digits', [Number]);
    Entry.Sha256 := Words[2];
    Entry.Path := Words[3];
    AddEntry(Entry);
  end
  else if Key = 'link' then
  begin
    Need(2);
    Entry.Kind := EntryLink;
    Entry.Path := Words[0];
    Entry.Target := Words[1];
    AddEntry(Entry);
  end
  else
    raise EManifestError.CreateFmt('line %d: unknown key %s', [Number, Key]);
end;

function TPackageManifest.FullVersion: string;
begin
  Result := Pkg.Versions.FullVersion(Version, Revision);
end;

function TPackageManifest.HasScript(const Kind: string): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Scripts) do
    if Scripts[Index] = Kind then
      Exit(True);
  Result := False;
end;

function TPackageManifest.ProvidesName(const AName: string): Boolean;
var
  Index: Integer;
begin
  if AName = Name then
    Exit(True);
  for Index := 0 to High(Provides) do
    if Provides[Index] = AName then
      Exit(True);
  Result := False;
end;

function TPackageManifest.FindPath(const Path: string): Integer;
var
  Index: Integer;
begin
  for Index := 0 to High(Entries) do
    if (Entries[Index].Kind <> EntryDirectory) and (Entries[Index].Path = Path) then
      Exit(Index);
  Result := -1;
end;

end.
