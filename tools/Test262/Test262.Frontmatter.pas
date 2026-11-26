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
  The metadata of a test262 test: the YAML block between "/*---" and
  "---*/" at its top. Only the subset test262 uses is read: scalar keys,
  inline lists ("[a, b]"), block lists ("- a") and one nested mapping
  (negative's phase and type); block scalars (description, info) are
  skipped.
}
unit Test262.Frontmatter;

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  Classes;

type
  TTestFlag = (tfOnlyStrict, tfNoStrict, tfRaw, tfModule, tfAsync, tfCanBlockIsFalse, tfCanBlockIsTrue,
    tfNonDeterministic, tfGenerated);
  TTestFlags = set of TTestFlag;

  TNegativePhase = (npNone, npParse, npResolution, npRuntime);

  TTestMetadata = record
    Includes: TStringArray;
    Features: TStringArray;
    Flags: TTestFlags;
    NegativePhase: TNegativePhase;
    { The constructor name of the expected error ('' when not negative). }
    NegativeType: string;
  end;

{ Reads Source's frontmatter; False when it has none (a malformed test). }
function ParseFrontmatter(const Source: string; out Metadata: TTestMetadata): Boolean;

function HasFeature(const Metadata: TTestMetadata; const Feature: string): Boolean;

implementation

const
  FrontmatterStart = '/*---';
  FrontmatterEnd = '---*/';

function IndentOf(const Line: string): Integer;
begin
  Result := 0;
  while (Result < Length(Line)) and (Line[Result + 1] = ' ') do
    Inc(Result);
end;

{ Strips YAML quotes and a trailing comment. }
function CleanScalar(const Text: string): string;
var
  CommentAt: Integer;
begin
  Result := Trim(Text);
  CommentAt := Pos(' #', Result);
  if CommentAt > 0 then
    Result := Trim(Copy(Result, 1, CommentAt - 1));
  if (Length(Result) >= 2) and (Result[1] in ['''', '"']) and (Result[Length(Result)] = Result[1]) then
    Result := Copy(Result, 2, Length(Result) - 2);
end;

procedure AppendItem(var Items: TStringArray; const Item: string);
begin
  if Item = '' then
    Exit;
  SetLength(Items, Length(Items) + 1);
  Items[High(Items)] := Item;
end;

{ "[a, b, c]" to its items. }
procedure ParseInlineList(const Text: string; var Items: TStringArray);
var
  Inner: string;
  Parts: TStringArray;
  Index: Integer;
begin
  Inner := Trim(Text);
  if (Inner = '') or (Inner[1] <> '[') then
    Exit;
  Delete(Inner, 1, 1);
  if Pos(']', Inner) > 0 then
    Inner := Copy(Inner, 1, Pos(']', Inner) - 1);
  Parts := Inner.Split([',']);
  for Index := 0 to High(Parts) do
    AppendItem(Items, CleanScalar(Parts[Index]));
end;

procedure ApplyFlag(var Metadata: TTestMetadata; const Name: string);
begin
  if Name = 'onlyStrict' then
    Include(Metadata.Flags, tfOnlyStrict)
  else if Name = 'noStrict' then
    Include(Metadata.Flags, tfNoStrict)
  else if Name = 'raw' then
    Include(Metadata.Flags, tfRaw)
  else if Name = 'module' then
    Include(Metadata.Flags, tfModule)
  else if Name = 'async' then
    Include(Metadata.Flags, tfAsync)
  else if Name = 'CanBlockIsFalse' then
    Include(Metadata.Flags, tfCanBlockIsFalse)
  else if Name = 'CanBlockIsTrue' then
    Include(Metadata.Flags, tfCanBlockIsTrue)
  else if Name = 'non-deterministic' then
    Include(Metadata.Flags, tfNonDeterministic)
  else if Name = 'generated' then
    Include(Metadata.Flags, tfGenerated);
end;

function PhaseOf(const Name: string): TNegativePhase;
begin
  if Name = 'parse' then
    Result := npParse
  else if Name = 'resolution' then
    Result := npResolution
  else if Name = 'runtime' then
    Result := npRuntime
  else
    Result := npNone;
end;

{ A top-level key and its value, with the indented lines below it. }
procedure ApplyKey(var Metadata: TTestMetadata; const Key, Value: string; Children: TStrings);
var
  Items: TStringArray;
  Index: Integer;
  Child, ChildKey, ChildValue: string;
  ColonAt: Integer;
begin
  Items := nil;
  if (Key = 'includes') or (Key = 'flags') or (Key = 'features') then
  begin
    if Value <> '' then
      ParseInlineList(Value, Items)
    else
      for Index := 0 to Children.Count - 1 do
      begin
        Child := Trim(Children[Index]);
        if (Child <> '') and (Child[1] = '-') then
          AppendItem(Items, CleanScalar(Copy(Child, 2, Length(Child))));
      end;
    if Key = 'includes' then
      Metadata.Includes := Items
    else if Key = 'features' then
      Metadata.Features := Items
    else
      for Index := 0 to High(Items) do
        ApplyFlag(Metadata, Items[Index]);
  end
  else if Key = 'negative' then
    for Index := 0 to Children.Count - 1 do
    begin
      Child := Trim(Children[Index]);
      ColonAt := Pos(':', Child);
      if ColonAt = 0 then
        Continue;
      ChildKey := Trim(Copy(Child, 1, ColonAt - 1));
      ChildValue := CleanScalar(Copy(Child, ColonAt + 1, Length(Child)));
      if ChildKey = 'phase' then
        Metadata.NegativePhase := PhaseOf(ChildValue)
      else if ChildKey = 'type' then
        Metadata.NegativeType := ChildValue;
    end;
end;

function ParseFrontmatter(const Source: string; out Metadata: TTestMetadata): Boolean;
var
  StartAt, EndAt, Index, ColonAt: Integer;
  Lines, Children: TStringList;
  Line, Key, Value: string;
begin
  Metadata := Default(TTestMetadata);
  StartAt := Pos(FrontmatterStart, Source);
  if StartAt = 0 then
    Exit(False);
  EndAt := Pos(FrontmatterEnd, Source, StartAt + Length(FrontmatterStart));
  if EndAt = 0 then
    Exit(False);
  Lines := TStringList.Create;
  Children := TStringList.Create;
  try
    Lines.Text := Copy(Source, StartAt + Length(FrontmatterStart), EndAt - StartAt - Length(FrontmatterStart));
    Index := 0;
    while Index < Lines.Count do
    begin
      Line := TrimRight(Lines[Index]);
      Inc(Index);
      if (Line = '') or (IndentOf(Line) > 0) then
        Continue;
      ColonAt := Pos(':', Line);
      if ColonAt = 0 then
        Continue;
      Key := Trim(Copy(Line, 1, ColonAt - 1));
      Value := Trim(Copy(Line, ColonAt + 1, Length(Line)));
      if (Value = '|') or (Value = '>') or (Value = '|-') or (Value = '>-') then
        Value := '';
      { The block below the key: indented lines (and blank ones). }
      Children.Clear;
      while (Index < Lines.Count) and ((Trim(Lines[Index]) = '') or (IndentOf(Lines[Index]) > 0) or
        (Copy(TrimLeft(Lines[Index]), 1, 1) = '-')) do
      begin
        { A list may sit at the key's own indentation ("flags:\n- raw"). }
        if (IndentOf(Lines[Index]) = 0) and (Copy(Lines[Index], 1, 1) <> '-') and (Trim(Lines[Index]) <> '') then
          Break;
        Children.Add(Lines[Index]);
        Inc(Index);
      end;
      ApplyKey(Metadata, Key, Value, Children);
    end;
  finally
    Children.Free;
    Lines.Free;
  end;
  { raw implies noStrict. }
  if tfRaw in Metadata.Flags then
    Include(Metadata.Flags, tfNoStrict);
  Result := True;
end;

function HasFeature(const Metadata: TTestMetadata; const Feature: string): Boolean;
var
  Index: Integer;
begin
  for Index := 0 to High(Metadata.Features) do
    if Metadata.Features[Index] = Feature then
      Exit(True);
  Result := False;
end;

end.
