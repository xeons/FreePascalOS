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
  The system's font configuration (/etc/fonts.conf): which installed
  families stand for a generic family or a font name a document asks
  for, and which families are tried, in order, for a character the
  chosen font lacks.

  The file is lines of "name = family, family, ..." in sections:

    [families]   a generic family (sans-serif, serif, monospace,
                 system-ui, emoji, ...) or a font name (Arial,
                 Helvetica, Times New Roman, ...) and the families
                 that stand for it, the first installed one taken;
    [fallback]   "default", the families tried for any character;
    [scripts]    a script's ranges of code points and the families
                 tried first for its characters:
                   cjk = 3000-30FF 4E00-9FFF ... : Noto Sans CJK, ...

  Names are compared without case; "#" starts a comment. A family is a
  directory in /lib/fonts named after it in lower case with dashes for
  spaces (FamilyDirectoryName). Without the file, built-in settings
  give DejaVu Sans for everything proportional (Arial, Helvetica, ...)
  and DejaVu Sans Mono for monospace (Courier New, ...).
}
unit Font.Configuration;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes;

type
  TFamilyList = array of string;

  TCodePointRange = record
    First: LongWord;
    Last: LongWord;
  end;

  TScriptChain = record
    Name: string;
    Ranges: array of TCodePointRange;
    Families: TFamilyList;
  end;

  TFamilyAlias = record
    Name: string;
    Families: TFamilyList;
  end;

  TFontConfiguration = class
  private
    FAliases: array of TFamilyAlias;
    FScripts: array of TScriptChain;
    FDefaultFallback: TFamilyList;
    procedure AddAlias(const Name: string; const Families: TFamilyList);
    procedure AddScript(const Name, Definition: string);
    procedure AddBuiltInSettings;
  public
    constructor Create;
    { Replaces the settings with those of Text (the file's contents). }
    procedure LoadFromText(const Text: string);
    { Reads the file; False (built-in settings kept) if it cannot. }
    function LoadFromFile(const Path: string): Boolean;
    { The families Name (a generic family or a font name, any case)
      stands for, in order; empty if the configuration does not name it. }
    function FamiliesFor(const Name: string): TFamilyList;
    { The families to try for CodePoint when the chosen font lacks it:
      its script's, then the default ones, each once. }
    function FallbackFamilies(CodePoint: LongWord): TFamilyList;
    { The script chain CodePoint belongs to ('' for none). }
    function ScriptOf(CodePoint: LongWord): string;
    property DefaultFallback: TFamilyList read FDefaultFallback;
  end;

var
  { Where the system's configuration is (the host tools point it at
    userland/etc/fonts.conf). }
  FontConfigurationPath: string = '/etc/fonts.conf';

{ The process's configuration, read from FontConfigurationPath when
  first asked for. }
function SystemFontConfiguration: TFontConfiguration;
{ Forgets it (the next use reads the file again). }
procedure ResetSystemFontConfiguration;
{ "Noto Sans CJK" -> "noto-sans-cjk": the directory of a family. }
function FamilyDirectoryName(const Family: string): string;
{ A list of names split at commas, trimmed, empty ones dropped. }
function SplitFamilyList(const Text: string): TFamilyList;

implementation

var
  SharedConfiguration: TFontConfiguration = nil;

function SystemFontConfiguration: TFontConfiguration;
begin
  if SharedConfiguration = nil then
  begin
    SharedConfiguration := TFontConfiguration.Create;
    SharedConfiguration.LoadFromFile(FontConfigurationPath);
  end;
  Result := SharedConfiguration;
end;

procedure ResetSystemFontConfiguration;
begin
  FreeAndNil(SharedConfiguration);
end;

function FamilyDirectoryName(const Family: string): string;
begin
  Result := LowerCase(StringReplace(Trim(Family), ' ', '-', [rfReplaceAll]));
end;

function SplitFamilyList(const Text: string): TFamilyList;
var
  Parts: TStringList;
  Index: Integer;
  Name: string;
begin
  Result := nil;
  Parts := TStringList.Create;
  try
    Parts.StrictDelimiter := True;
    Parts.Delimiter := ',';
    Parts.DelimitedText := Text;
    for Index := 0 to Parts.Count - 1 do
    begin
      Name := Trim(Parts[Index]);
      if (Length(Name) >= 2) and (Name[1] in ['"', '''']) and (Name[Length(Name)] = Name[1]) then
        Name := Copy(Name, 2, Length(Name) - 2);
      if Name = '' then
        Continue;
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Name;
    end;
  finally
    Parts.Free;
  end;
end;

function Families(const Names: array of string): TFamilyList;
var
  Index: Integer;
begin
  Result := nil;
  SetLength(Result, Length(Names));
  for Index := 0 to High(Names) do
    Result[Index] := Names[Index];
end;

constructor TFontConfiguration.Create;
begin
  inherited Create;
  AddBuiltInSettings;
end;

procedure TFontConfiguration.AddBuiltInSettings;
begin
  FAliases := nil;
  FScripts := nil;
  AddAlias('sans-serif', Families(['DejaVu Sans']));
  AddAlias('serif', Families(['DejaVu Serif', 'DejaVu Sans']));
  AddAlias('monospace', Families(['DejaVu Sans Mono']));
  AddAlias('system-ui', Families(['DejaVu Sans']));
  AddAlias('-apple-system', Families(['DejaVu Sans']));
  AddAlias('blinkmacsystemfont', Families(['DejaVu Sans']));
  AddAlias('arial', Families(['DejaVu Sans']));
  AddAlias('helvetica', Families(['DejaVu Sans']));
  AddAlias('verdana', Families(['DejaVu Sans']));
  AddAlias('bitstream vera sans', Families(['DejaVu Sans']));
  AddAlias('courier', Families(['DejaVu Sans Mono']));
  AddAlias('courier new', Families(['DejaVu Sans Mono']));
  AddAlias('consolas', Families(['DejaVu Sans Mono']));
  AddAlias('menlo', Families(['DejaVu Sans Mono']));
  FDefaultFallback := Families(['DejaVu Sans', 'DejaVu Sans Mono']);
end;

procedure TFontConfiguration.AddAlias(const Name: string; const Families: TFamilyList);
var
  Index: Integer;
  Key: string;
begin
  Key := LowerCase(Trim(Name));
  for Index := 0 to High(FAliases) do
    if FAliases[Index].Name = Key then
    begin
      FAliases[Index].Families := Families;
      Exit;
    end;
  SetLength(FAliases, Length(FAliases) + 1);
  FAliases[High(FAliases)].Name := Key;
  FAliases[High(FAliases)].Families := Families;
end;

{ "3000-30FF 4E00-9FFF 1F600 : Family, Family". }
procedure TFontConfiguration.AddScript(const Name, Definition: string);
var
  Colon: Integer;
  RangeText: string;
  Words: TStringList;
  Index: Integer;
  Dash: Integer;
  Chain: TScriptChain;
  First: LongInt;
  Last: LongInt;
  Word_: string;
begin
  Colon := Pos(':', Definition);
  if Colon = 0 then
    Exit;
  RangeText := Copy(Definition, 1, Colon - 1);
  Chain.Name := LowerCase(Trim(Name));
  Chain.Ranges := nil;
  Chain.Families := SplitFamilyList(Copy(Definition, Colon + 1, MaxInt));
  Words := TStringList.Create;
  try
    Words.Delimiter := ' ';
    Words.StrictDelimiter := False;
    Words.DelimitedText := StringReplace(RangeText, ',', ' ', [rfReplaceAll]);
    for Index := 0 to Words.Count - 1 do
    begin
      Word_ := Trim(Words[Index]);
      if Word_ = '' then
        Continue;
      Dash := Pos('-', Word_);
      if Dash > 0 then
      begin
        if not TryStrToInt('$' + Copy(Word_, 1, Dash - 1), First) or
           not TryStrToInt('$' + Copy(Word_, Dash + 1, MaxInt), Last) then
          Continue;
      end
      else
      begin
        if not TryStrToInt('$' + Word_, First) then
          Continue;
        Last := First;
      end;
      if (First < 0) or (Last < First) or (Last > $10FFFF) then
        Continue;
      SetLength(Chain.Ranges, Length(Chain.Ranges) + 1);
      Chain.Ranges[High(Chain.Ranges)].First := First;
      Chain.Ranges[High(Chain.Ranges)].Last := Last;
    end;
  finally
    Words.Free;
  end;
  if (Length(Chain.Ranges) = 0) or (Length(Chain.Families) = 0) then
    Exit;
  SetLength(FScripts, Length(FScripts) + 1);
  FScripts[High(FScripts)] := Chain;
end;

procedure TFontConfiguration.LoadFromText(const Text: string);
var
  Lines: TStringList;
  Index: Integer;
  Line: string;
  Section: string;
  EqualsAt: Integer;
  Hash: Integer;
  Name: string;
  Value: string;
begin
  AddBuiltInSettings;
  Section := '';
  Lines := TStringList.Create;
  try
    Lines.Text := Text;
    for Index := 0 to Lines.Count - 1 do
    begin
      Line := Lines[Index];
      Hash := Pos('#', Line);
      if Hash > 0 then
        Line := Copy(Line, 1, Hash - 1);
      Line := Trim(Line);
      if Line = '' then
        Continue;
      if (Line[1] = '[') and (Line[Length(Line)] = ']') then
      begin
        Section := LowerCase(Trim(Copy(Line, 2, Length(Line) - 2)));
        Continue;
      end;
      EqualsAt := Pos('=', Line);
      if EqualsAt = 0 then
        Continue;
      Name := Trim(Copy(Line, 1, EqualsAt - 1));
      Value := Trim(Copy(Line, EqualsAt + 1, MaxInt));
      if Section = 'families' then
        AddAlias(Name, SplitFamilyList(Value))
      else if (Section = 'fallback') and (LowerCase(Name) = 'default') then
        FDefaultFallback := SplitFamilyList(Value)
      else if Section = 'scripts' then
        AddScript(Name, Value);
    end;
  finally
    Lines.Free;
  end;
end;

function TFontConfiguration.LoadFromFile(const Path: string): Boolean;
var
  Lines: TStringList;
begin
  Result := False;
  if not FileExists(Path) then
    Exit;
  Lines := TStringList.Create;
  try
    try
      Lines.LoadFromFile(Path);
    except
      Exit;
    end;
    LoadFromText(Lines.Text);
    Result := True;
  finally
    Lines.Free;
  end;
end;

function TFontConfiguration.FamiliesFor(const Name: string): TFamilyList;
var
  Index: Integer;
  Key: string;
begin
  Result := nil;
  Key := LowerCase(Trim(Name));
  for Index := 0 to High(FAliases) do
    if FAliases[Index].Name = Key then
      Exit(FAliases[Index].Families);
end;

function TFontConfiguration.ScriptOf(CodePoint: LongWord): string;
var
  Script: Integer;
  Range: Integer;
begin
  Result := '';
  for Script := 0 to High(FScripts) do
    for Range := 0 to High(FScripts[Script].Ranges) do
      if (CodePoint >= FScripts[Script].Ranges[Range].First) and (CodePoint <= FScripts[Script].Ranges[Range].Last) then
        Exit(FScripts[Script].Name);
end;

procedure AddOnce(var List: TFamilyList; const Name: string);
var
  Index: Integer;
begin
  for Index := 0 to High(List) do
    if SameText(List[Index], Name) then
      Exit;
  SetLength(List, Length(List) + 1);
  List[High(List)] := Name;
end;

function TFontConfiguration.FallbackFamilies(CodePoint: LongWord): TFamilyList;
var
  Script: Integer;
  Range: Integer;
  Index: Integer;
begin
  Result := nil;
  for Script := 0 to High(FScripts) do
    for Range := 0 to High(FScripts[Script].Ranges) do
      if (CodePoint >= FScripts[Script].Ranges[Range].First) and (CodePoint <= FScripts[Script].Ranges[Range].Last) then
      begin
        for Index := 0 to High(FScripts[Script].Families) do
          AddOnce(Result, FScripts[Script].Families[Index]);
        Break;
      end;
  for Index := 0 to High(FDefaultFallback) do
    AddOnce(Result, FDefaultFallback[Index]);
end;

finalization
  FreeAndNil(SharedConfiguration);
end.
