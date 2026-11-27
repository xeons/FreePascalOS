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
  Versions and dependencies, compared exactly as the ports tool does
  (scripts/portstool/versions.py; the host tests check both on the same
  pairs).

  A version is compared part by part: runs of digits as numbers, runs
  of letters as text, anything else separating them, so 1.10 > 1.9.
  A run of letters starting with alpha, beta, pre or rc is a
  pre-release (1.0rc1 < 1.0); other letters come after (1.0a > 1.0).
  A missing part is less than a number or text and more than a
  pre-release. The revision after the last '_' (the port's own
  changes) decides last: 1.0_2 > 1.0_1 > 1.0.

  A dependency is NAME, or NAME OP VERSION with OP >= <= > < =.
}
unit Pkg.Versions;

{$mode objfpc}
{$H+}

interface

type
  TDependency = record
    Name: string;
    { '', '>=', '<=', '>', '<' or '='. }
    Operation: string;
    Version: string;
  end;

{ -1, 0 or 1 as Left is older than, the same as or newer than Right. }
function CompareVersions(const Left, Right: string): Integer;
{ 1.3.1 with revision 0, 1.3.1_2 with revision 2. }
function FullVersion(const Version: string; Revision: Integer): string;
function ParseDependency(const Text: string; out Dependency: TDependency): Boolean;
function DependencySatisfied(const Dependency: TDependency; const Version: string): Boolean;
function DependencyText(const Dependency: TDependency): string;

implementation

uses
  SysUtils;

type
  { The order of the kinds is the order of the parts. }
  TPartKind = (PartPreRelease, PartMissing, PartNumber, PartText);

  TVersionPart = record
    Kind: TPartKind;
    { Digits without leading zeros, or the letters in lower case. }
    Text: string;
  end;

  TVersionParts = array of TVersionPart;

function IsDigit(Character: Char): Boolean; inline;
begin
  Result := Character in ['0'..'9'];
end;

function IsLetter(Character: Char): Boolean; inline;
begin
  Result := Character in ['A'..'Z', 'a'..'z'];
end;

function IsPreReleaseWord(const Word: string): Boolean;
begin
  Result := (Pos('alpha', Word) = 1) or (Pos('beta', Word) = 1) or (Pos('pre', Word) = 1) or (Pos('rc', Word) = 1);
end;

function SplitParts(const Version: string): TVersionParts;
var
  Position, Start, Count: Integer;
  Part: TVersionPart;
begin
  Result := nil;
  Count := 0;
  Position := 1;
  while Position <= Length(Version) do
  begin
    if IsDigit(Version[Position]) then
    begin
      Start := Position;
      while (Position <= Length(Version)) and IsDigit(Version[Position]) do
        Inc(Position);
      Part.Kind := PartNumber;
      Part.Text := Copy(Version, Start, Position - Start);
      while (Length(Part.Text) > 1) and (Part.Text[1] = '0') do
        Delete(Part.Text, 1, 1);
    end
    else if IsLetter(Version[Position]) then
    begin
      Start := Position;
      while (Position <= Length(Version)) and IsLetter(Version[Position]) do
        Inc(Position);
      Part.Text := LowerCase(Copy(Version, Start, Position - Start));
      if IsPreReleaseWord(Part.Text) then
      begin
        { Python compares (0, 0, word): pre-releases by their word. }
        Part.Kind := PartPreRelease;
      end
      else
        Part.Kind := PartText;
    end
    else
    begin
      Inc(Position);
      Continue;
    end;
    SetLength(Result, Count + 1);
    Result[Count] := Part;
    Inc(Count);
  end;
end;

procedure SplitRevision(const Version: string; out Base: string; out Revision: QWord);
var
  Underscore, Index: Integer;
  Digits: string;
begin
  Base := Version;
  Revision := 0;
  Underscore := 0;
  for Index := Length(Version) downto 1 do
    if Version[Index] = '_' then
    begin
      Underscore := Index;
      Break;
    end;
  if Underscore = 0 then
    Exit;
  Digits := Copy(Version, Underscore + 1, MaxInt);
  if (Digits = '') or not TryStrToQWord(Digits, Revision) then
  begin
    Revision := 0;
    Exit;
  end;
  for Index := 1 to Length(Digits) do
    if not IsDigit(Digits[Index]) then
    begin
      Revision := 0;
      Exit;
    end;
  Base := Copy(Version, 1, Underscore - 1);
end;

function CompareNumberTexts(const Left, Right: string): Integer;
begin
  if Length(Left) <> Length(Right) then
  begin
    if Length(Left) < Length(Right) then
      Exit(-1);
    Exit(1);
  end;
  Result := CompareStr(Left, Right);
  if Result < 0 then
    Result := -1
  else if Result > 0 then
    Result := 1;
end;

function CompareParts(const Left, Right: TVersionPart): Integer;
begin
  if Left.Kind <> Right.Kind then
  begin
    if Ord(Left.Kind) < Ord(Right.Kind) then
      Exit(-1);
    Exit(1);
  end;
  if Left.Kind = PartNumber then
    Exit(CompareNumberTexts(Left.Text, Right.Text));
  Result := CompareStr(Left.Text, Right.Text);
  if Result < 0 then
    Result := -1
  else if Result > 0 then
    Result := 1;
end;

function CompareVersions(const Left, Right: string): Integer;
var
  LeftBase, RightBase: string;
  LeftRevision, RightRevision: QWord;
  LeftParts, RightParts: TVersionParts;
  Index: Integer;
  LeftPart, RightPart, Missing: TVersionPart;
begin
  SplitRevision(Left, LeftBase, LeftRevision);
  SplitRevision(Right, RightBase, RightRevision);
  LeftParts := SplitParts(LeftBase);
  RightParts := SplitParts(RightBase);
  Missing.Kind := PartMissing;
  Missing.Text := '';
  Index := 0;
  while (Index < Length(LeftParts)) or (Index < Length(RightParts)) do
  begin
    if Index < Length(LeftParts) then
      LeftPart := LeftParts[Index]
    else
      LeftPart := Missing;
    if Index < Length(RightParts) then
      RightPart := RightParts[Index]
    else
      RightPart := Missing;
    Result := CompareParts(LeftPart, RightPart);
    if Result <> 0 then
      Exit;
    Inc(Index);
  end;
  if LeftRevision < RightRevision then
    Exit(-1);
  if LeftRevision > RightRevision then
    Exit(1);
  Result := 0;
end;

function FullVersion(const Version: string; Revision: Integer): string;
begin
  if Revision > 0 then
    Result := Version + '_' + IntToStr(Revision)
  else
    Result := Version;
end;

function IsNameCharacter(Character: Char): Boolean;
begin
  Result := Character in ['a'..'z', '0'..'9', '+', '.', '_', '-'];
end;

function ParseDependency(const Text: string; out Dependency: TDependency): Boolean;
var
  Position, Start: Integer;
begin
  Dependency.Name := '';
  Dependency.Operation := '';
  Dependency.Version := '';
  Result := False;
  Position := 1;
  while (Position <= Length(Text)) and (Text[Position] = ' ') do
    Inc(Position);
  Start := Position;
  while (Position <= Length(Text)) and IsNameCharacter(Text[Position]) do
    Inc(Position);
  Dependency.Name := Copy(Text, Start, Position - Start);
  if (Dependency.Name = '') or not (Dependency.Name[1] in ['a'..'z', '0'..'9']) then
    Exit;
  while (Position <= Length(Text)) and (Text[Position] = ' ') do
    Inc(Position);
  if Position > Length(Text) then
    Exit(True);
  Start := Position;
  while (Position <= Length(Text)) and (Text[Position] in ['<', '>', '=']) do
    Inc(Position);
  Dependency.Operation := Copy(Text, Start, Position - Start);
  if (Dependency.Operation <> '>=') and (Dependency.Operation <> '<=') and (Dependency.Operation <> '>') and
    (Dependency.Operation <> '<') and (Dependency.Operation <> '=') then
    Exit;
  while (Position <= Length(Text)) and (Text[Position] = ' ') do
    Inc(Position);
  Start := Position;
  while (Position <= Length(Text)) and not (Text[Position] in [' ', '<', '>', '=']) do
    Inc(Position);
  Dependency.Version := Copy(Text, Start, Position - Start);
  while (Position <= Length(Text)) and (Text[Position] = ' ') do
    Inc(Position);
  Result := (Dependency.Version <> '') and (Position > Length(Text));
end;

function DependencySatisfied(const Dependency: TDependency; const Version: string): Boolean;
var
  Order: Integer;
begin
  if Dependency.Operation = '' then
    Exit(True);
  Order := CompareVersions(Version, Dependency.Version);
  if Dependency.Operation = '>=' then
    Result := Order >= 0
  else if Dependency.Operation = '<=' then
    Result := Order <= 0
  else if Dependency.Operation = '>' then
    Result := Order > 0
  else if Dependency.Operation = '<' then
    Result := Order < 0
  else
    Result := Order = 0;
end;

function DependencyText(const Dependency: TDependency): string;
begin
  if Dependency.Operation = '' then
    Result := Dependency.Name
  else
    Result := Dependency.Name + ' ' + Dependency.Operation + ' ' + Dependency.Version;
end;

end.
