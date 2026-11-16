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
  A settings file: one group's settings, as lines of text.

    # Notepad's settings              a comment ("#" or ";" first)
    WordWrap = true                   a key of the group itself
    Font = "DejaVu Sans Mono"

    [Window]                          a section (sections nest: [A/B])
    Width = 640
    fixed Height = 480                fixed: in the system's settings,
                                      not to be changed by users

  Keys and sections are names (Configuration.Names); values are written
  as Configuration.Values says. Keys before the first section header
  belong to the group itself. Comments take whole lines (so a value may
  hold "#"). A key that appears twice is read from its first line.

  The document keeps every line as it was read and changes only the
  lines it must: a new key goes after the last key of its section, a new
  section at the end. So comments, order, blank lines and even lines it
  cannot make sense of survive any number of changes. Such a broken line
  (or a key under a broken section header) is ignored when reading and
  listed in Problems with its number.
}
unit Configuration.Documents;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Configuration.Values;

type
  TSettingsLineKind = (LineBlank, LineComment, LineSection, LineEntry, LineInvalid);

  TSettingsLine = record
    Kind: TSettingsLineKind;
    { The line as read or as made (without its line end). }
    Text: string;
    { Sections and entries: the section they are in. }
    Section: string;
    Key: string;
    { What follows "=" (spaces at its ends removed). }
    ValueText: string;
    Fixed: Boolean;
  end;

  TSettingsDocument = class
  private
    FLines: array of TSettingsLine;
    FLineCount: Integer;
    procedure AddLine(const Line: TSettingsLine);
    procedure InsertLine(Index: Integer; const Line: TSettingsLine);
    procedure RemoveLine(Index: Integer);
    function ParseLine(const Text: string; var Section: string; var SectionIsValid: Boolean): TSettingsLine;
    function FindEntry(const Section, Key: string): Integer;
    function PlaceForNewEntry(const Section: string): Integer;
    function EntryLine(const Section, Key: string; const Value: TSettingValue; Fixed: Boolean): TSettingsLine;
    function SectionLine(const Section: string): TSettingsLine;
    function LineAt(Index: Integer): TSettingsLine;
  public
    { Replaces the contents with Text's lines. }
    procedure Parse(const Text: string);
    { The text to write: every line, each ending with a line feed. }
    function Serialize: string;
    procedure Clear;

    { Section's Key; False if it is not there or its value is malformed. }
    function GetValue(const Section, Key: string; out Value: TSettingValue; out Fixed: Boolean): Boolean;
    procedure SetValue(const Section, Key: string; const Value: TSettingValue; Fixed: Boolean);
    { False if there was no such key. }
    function DeleteValue(const Section, Key: string): Boolean;
    { Removes Section, its subsections and their keys (the lines from
      their headers to the next other section's); '' removes everything. }
    function DeleteSection(const Section: string): Boolean;

    { The keys of Section, in the order of the file. }
    function ListKeys(const Section: string): TStringArray;
    { The names of the sections directly below Parent ('' for the
      group's) that hold a key (themselves or below). }
    function ListSections(const Parent: string): TStringArray;
    { True if no line holds a key. }
    function HasNoKeys: Boolean;
    { "line N: TEXT" for every line that could not be read. }
    function Problems: TStringArray;

    property LineCount: Integer read FLineCount;
    property Lines[Index: Integer]: TSettingsLine read LineAt;
  end;

implementation

uses
  Configuration.Names;

const
  FixedWord = 'fixed';

procedure AppendText(var Items: TStringArray; const Text: string);
var
  Index: Integer;
begin
  for Index := 0 to High(Items) do
    if Items[Index] = Text then
      Exit;
  SetLength(Items, Length(Items) + 1);
  Items[High(Items)] := Text;
end;

{ A section header, readable or not: either way the keys after it are
  not the previous section's. }
function IsHeaderLine(const Line: TSettingsLine): Boolean;
var
  Trimmed: string;
begin
  Trimmed := Trim(Line.Text);
  Result := (Line.Kind in [LineSection, LineInvalid]) and (Trimmed <> '') and (Trimmed[1] = '[');
end;

function TSettingsDocument.LineAt(Index: Integer): TSettingsLine;
begin
  Result := FLines[Index];
end;

procedure TSettingsDocument.AddLine(const Line: TSettingsLine);
begin
  InsertLine(FLineCount, Line);
end;

procedure TSettingsDocument.InsertLine(Index: Integer; const Line: TSettingsLine);
var
  Moving: Integer;
begin
  if FLineCount = Length(FLines) then
    SetLength(FLines, 2 * Length(FLines) + 8);
  for Moving := FLineCount downto Index + 1 do
    FLines[Moving] := FLines[Moving - 1];
  FLines[Index] := Line;
  Inc(FLineCount);
end;

procedure TSettingsDocument.RemoveLine(Index: Integer);
var
  Moving: Integer;
begin
  for Moving := Index to FLineCount - 2 do
    FLines[Moving] := FLines[Moving + 1];
  Dec(FLineCount);
  FLines[FLineCount] := Default(TSettingsLine);
end;

procedure TSettingsDocument.Clear;
begin
  FLines := nil;
  FLineCount := 0;
end;

{ What one line is; a section header changes the section the lines after
  it are in. }
function TSettingsDocument.ParseLine(const Text: string; var Section: string;
  var SectionIsValid: Boolean): TSettingsLine;
var
  Trimmed: string;
  Left: string;
  EqualsPosition: Integer;
  Space: Integer;
  Value: TSettingValue;
begin
  Result := Default(TSettingsLine);
  Result.Text := Text;
  Result.Kind := LineInvalid;
  Trimmed := Trim(Text);
  if Pos(#0, Text) > 0 then
    Exit;
  if Trimmed = '' then
    Result.Kind := LineBlank
  else if Trimmed[1] in ['#', ';'] then
    Result.Kind := LineComment
  else if Trimmed[1] = '[' then
  begin
    { A header that cannot be read leaves the keys after it nowhere:
      they are not taken for the previous section's. }
    Section := Trim(Copy(Trimmed, 2, Length(Trimmed) - 2));
    SectionIsValid := (Trimmed[Length(Trimmed)] = ']') and IsSectionPath(Section);
    if SectionIsValid then
    begin
      Result.Kind := LineSection;
      Result.Section := Section;
    end;
  end
  else
  begin
    EqualsPosition := Pos('=', Trimmed);
    if (EqualsPosition = 0) or not SectionIsValid then
      Exit;
    Left := Trim(Copy(Trimmed, 1, EqualsPosition - 1));
    Space := Pos(' ', Left);
    if Space = 0 then
      Space := Pos(#9, Left);
    if Space > 0 then
    begin
      if Copy(Left, 1, Space - 1) <> FixedWord then
        Exit;
      Result.Fixed := True;
      Left := Trim(Copy(Left, Space + 1, Length(Left)));
    end;
    if not IsSettingsName(Left) then
      Exit;
    Result.ValueText := Trim(Copy(Trimmed, EqualsPosition + 1, Length(Trimmed)));
    if not ParseSettingValue(Result.ValueText, Value) then
      Exit;
    Result.Kind := LineEntry;
    Result.Section := Section;
    Result.Key := Left;
  end;
end;

procedure TSettingsDocument.Parse(const Text: string);
var
  Start: Integer;
  Index: Integer;
  LineText: string;
  Section: string;
  SectionIsValid: Boolean;
begin
  Clear;
  Section := '';
  SectionIsValid := True;
  Start := 1;
  for Index := 1 to Length(Text) do
    if Text[Index] = #10 then
    begin
      LineText := Copy(Text, Start, Index - Start);
      if (LineText <> '') and (LineText[Length(LineText)] = #13) then
        SetLength(LineText, Length(LineText) - 1);
      AddLine(ParseLine(LineText, Section, SectionIsValid));
      Start := Index + 1;
    end;
  { A last line without a line feed (a file written by hand). }
  if Start <= Length(Text) then
  begin
    LineText := Copy(Text, Start, Length(Text) - Start + 1);
    if LineText[Length(LineText)] = #13 then
      SetLength(LineText, Length(LineText) - 1);
    AddLine(ParseLine(LineText, Section, SectionIsValid));
  end;
end;

function TSettingsDocument.Serialize: string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 0 to FLineCount - 1 do
    Result := Result + FLines[Index].Text + #10;
end;

function TSettingsDocument.FindEntry(const Section, Key: string): Integer;
var
  Index: Integer;
begin
  for Index := 0 to FLineCount - 1 do
    if (FLines[Index].Kind = LineEntry) and (FLines[Index].Section = Section) and
       (FLines[Index].Key = Key) then
      Exit(Index);
  Result := -1;
end;

function TSettingsDocument.GetValue(const Section, Key: string; out Value: TSettingValue;
  out Fixed: Boolean): Boolean;
var
  Index: Integer;
begin
  Value := StringSetting('');
  Fixed := False;
  Index := FindEntry(Section, Key);
  if Index < 0 then
    Exit(False);
  Fixed := FLines[Index].Fixed;
  Result := ParseSettingValue(FLines[Index].ValueText, Value);
end;

function TSettingsDocument.EntryLine(const Section, Key: string; const Value: TSettingValue;
  Fixed: Boolean): TSettingsLine;
begin
  Result := Default(TSettingsLine);
  Result.Kind := LineEntry;
  Result.Section := Section;
  Result.Key := Key;
  Result.ValueText := FormatSettingValue(Value);
  Result.Fixed := Fixed;
  Result.Text := Key + ' = ' + Result.ValueText;
  if Fixed then
    Result.Text := FixedWord + ' ' + Result.Text;
end;

function TSettingsDocument.SectionLine(const Section: string): TSettingsLine;
begin
  Result := Default(TSettingsLine);
  Result.Kind := LineSection;
  Result.Section := Section;
  Result.Text := '[' + Section + ']';
end;

{ Where a new key of Section goes: after the section's last key (or its
  header); -1 if the section has no lines yet. Keys of the group itself
  go before the first section, above the blank lines that set it off. }
function TSettingsDocument.PlaceForNewEntry(const Section: string): Integer;
var
  Index: Integer;
  FirstHeader: Integer;
begin
  Result := -1;
  FirstHeader := -1;
  for Index := 0 to FLineCount - 1 do
  begin
    if (FirstHeader < 0) and IsHeaderLine(FLines[Index]) then
      FirstHeader := Index;
    if (FLines[Index].Kind in [LineSection, LineEntry]) and (FLines[Index].Section = Section) then
      Result := Index + 1;
  end;
  if (Result >= 0) or (Section <> '') then
    Exit;
  if FirstHeader < 0 then
    Exit(FLineCount);
  Result := FirstHeader;
  while (Result > 0) and (FLines[Result - 1].Kind = LineBlank) do
    Dec(Result);
end;

procedure TSettingsDocument.SetValue(const Section, Key: string; const Value: TSettingValue; Fixed: Boolean);
var
  Index: Integer;
  Place: Integer;
begin
  Index := FindEntry(Section, Key);
  if Index >= 0 then
  begin
    FLines[Index] := EntryLine(Section, Key, Value, Fixed);
    Exit;
  end;
  Place := PlaceForNewEntry(Section);
  if Place >= 0 then
  begin
    InsertLine(Place, EntryLine(Section, Key, Value, Fixed));
    Exit;
  end;
  { A new section, at the end, after a blank line. }
  if (FLineCount > 0) and (FLines[FLineCount - 1].Kind <> LineBlank) then
    AddLine(Default(TSettingsLine));
  AddLine(SectionLine(Section));
  AddLine(EntryLine(Section, Key, Value, Fixed));
end;

function TSettingsDocument.DeleteValue(const Section, Key: string): Boolean;
var
  Index: Integer;
begin
  Result := False;
  Index := FindEntry(Section, Key);
  while Index >= 0 do
  begin
    RemoveLine(Index);
    Result := True;
    Index := FindEntry(Section, Key);
  end;
end;

function IsSameOrBelow(const Section, Ancestor: string): Boolean;
begin
  Result := (Ancestor = '') or (Section = Ancestor) or
    (Copy(Section, 1, Length(Ancestor) + 1) = Ancestor + SettingsPathSeparator);
end;

function TSettingsDocument.DeleteSection(const Section: string): Boolean;
var
  Index: Integer;
  Removing: Boolean;
begin
  Result := False;
  if Section = '' then
  begin
    Result := not HasNoKeys;
    Clear;
    Exit;
  end;
  Removing := False;
  Index := 0;
  while Index < FLineCount do
  begin
    if FLines[Index].Kind = LineSection then
      Removing := IsSameOrBelow(FLines[Index].Section, Section)
    else if IsHeaderLine(FLines[Index]) then
      Removing := False;
    if Removing then
    begin
      if FLines[Index].Kind = LineEntry then
        Result := True;
      RemoveLine(Index);
    end
    else
      Inc(Index);
  end;
end;

function TSettingsDocument.ListKeys(const Section: string): TStringArray;
var
  Index: Integer;
begin
  Result := nil;
  for Index := 0 to FLineCount - 1 do
    if (FLines[Index].Kind = LineEntry) and (FLines[Index].Section = Section) then
      AppendText(Result, FLines[Index].Key);
end;

function TSettingsDocument.ListSections(const Parent: string): TStringArray;
var
  Index: Integer;
  Section: string;
  Rest: string;
  Separator: Integer;
begin
  Result := nil;
  for Index := 0 to FLineCount - 1 do
  begin
    if FLines[Index].Kind <> LineEntry then
      Continue;
    Section := FLines[Index].Section;
    if (Section = '') or (Section = Parent) or not IsSameOrBelow(Section, Parent) then
      Continue;
    if Parent = '' then
      Rest := Section
    else
      Rest := Copy(Section, Length(Parent) + 2, Length(Section));
    Separator := Pos(SettingsPathSeparator, Rest);
    if Separator > 0 then
      Rest := Copy(Rest, 1, Separator - 1);
    AppendText(Result, Rest);
  end;
end;

function TSettingsDocument.HasNoKeys: Boolean;
var
  Index: Integer;
begin
  for Index := 0 to FLineCount - 1 do
    if FLines[Index].Kind = LineEntry then
      Exit(False);
  Result := True;
end;

function TSettingsDocument.Problems: TStringArray;
var
  Index: Integer;
begin
  Result := nil;
  for Index := 0 to FLineCount - 1 do
    if FLines[Index].Kind = LineInvalid then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := 'line ' + IntToStr(Index + 1) + ': ' + FLines[Index].Text;
    end;
end;

end.
