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
  Permission modes as chmod, mkdir -m and install -m accept them:

    755, 0644              octal
    u+x, go-w, a=r, u=rw,g=r,o=
    +X                     execute only for directories, or files that
                           already have some execute bit

  The mode bits are the usual Unix ones (0o7777: set-user-id, set-group-id,
  sticky, then rwx for user, group and others).
}
unit Util.Modes;

{$mode objfpc}{$H+}

interface

type
  { A parsed mode, applied later to each file's current mode. }
  TModeChange = record
    { The symbolic form (when not octal). }
    Symbolic: string;
    IsOctal: Boolean;
    OctalValue: LongWord;
  end;

{ Returns False if Text is not a valid mode. }
function ParseModeChange(const Text: string; out Change: TModeChange): Boolean;
{ The new mode for a file with CurrentMode. }
function ApplyModeChange(const Change: TModeChange; CurrentMode: LongWord; IsDirectory: Boolean): LongWord;
{ "rwxr-xr-x" (9 characters). }
function FormatModeText(Mode: LongWord): string;

implementation

const
  DefaultMask = $12; { the usual umask 022 }

{ The character at Position (from 0), #0 past the end: the scanning
  below looks one past the text. }
function CharacterAt(const Text: string; Position: Integer): Char;
begin
  if Position < Length(Text) then
    Result := Text[Position + 1]
  else
    Result := #0;
end;

function ParseOctalMode(const Text: string; out Change: TModeChange): Boolean;
var
  Position: Integer;
  Value: LongWord;
begin
  Value := 0;
  Position := 0;
  while CharacterAt(Text, Position) in ['0'..'7'] do
  begin
    Value := Value * 8 + LongWord(Ord(Text[Position + 1]) - Ord('0'));
    Inc(Position);
  end;
  if (Position < Length(Text)) or (Value > $FFF) then
    Exit(False);
  Change.IsOctal := True;
  Change.OctalValue := Value;
  Result := True;
end;

function ParseModeChange(const Text: string; out Change: TModeChange): Boolean;
var
  Position: Integer;
begin
  Change.Symbolic := Text;
  Change.IsOctal := False;
  Change.OctalValue := 0;
  if Text = '' then
    Exit(False);
  if Text[1] in ['0'..'7'] then
    Exit(ParseOctalMode(Text, Change));

  { Check the symbolic form's shape. }
  Position := 0;
  while Position < Length(Text) do
  begin
    while CharacterAt(Text, Position) in ['u', 'g', 'o', 'a'] do
      Inc(Position);
    if not (CharacterAt(Text, Position) in ['+', '-', '=']) then
      Exit(False);
    while CharacterAt(Text, Position) in ['+', '-', '='] do
    begin
      Inc(Position);
      while CharacterAt(Text, Position) in ['r', 'w', 'x', 'X', 's', 't', 'u', 'g', 'o'] do
        Inc(Position);
    end;
    if CharacterAt(Text, Position) = ',' then
      Inc(Position)
    else if Position < Length(Text) then
      Exit(False);
  end;
  Result := True;
end;

{ The rwx bits (in "user" position 0o700 scale 0..7) for who letters. }
function WhoMask(UserSelected, GroupSelected, OthersSelected: Boolean): LongWord;
begin
  Result := 0;
  if UserSelected then
    Result := Result or $9C0;   { 4700: setuid + rwx }
  if GroupSelected then
    Result := Result or $438;   { 2070: setgid + rwx }
  if OthersSelected then
    Result := Result or $207;   { 1007: sticky + rwx }
end;

{ Spreads an rwx value (0..7) to every selected class. }
function Spread(Bits: LongWord): LongWord;
begin
  Result := (Bits shl 6) or (Bits shl 3) or Bits;
end;

function ApplyModeChange(const Change: TModeChange; CurrentMode: LongWord; IsDirectory: Boolean): LongWord;
var
  Text: string;
  Position: Integer;
  UserSelected, GroupSelected, OthersSelected: Boolean;
  NoneGiven: Boolean;
  Operation: Char;
  Permissions: LongWord;
  Mask: LongWord;
  Affected: LongWord;
begin
  if Change.IsOctal then
    Exit(Change.OctalValue);
  Result := CurrentMode and $FFF;
  Text := Change.Symbolic;
  Position := 0;
  while Position < Length(Text) do
  begin
    UserSelected := False;
    GroupSelected := False;
    OthersSelected := False;
    NoneGiven := True;
    while CharacterAt(Text, Position) in ['u', 'g', 'o', 'a'] do
    begin
      case Text[Position + 1] of
        'u': UserSelected := True;
        'g': GroupSelected := True;
        'o': OthersSelected := True;
        'a':
          begin
            UserSelected := True;
            GroupSelected := True;
            OthersSelected := True;
          end;
      end;
      NoneGiven := False;
      Inc(Position);
    end;
    if NoneGiven then
    begin
      UserSelected := True;
      GroupSelected := True;
      OthersSelected := True;
    end;
    Mask := WhoMask(UserSelected, GroupSelected, OthersSelected);

    while CharacterAt(Text, Position) in ['+', '-', '='] do
    begin
      Operation := Text[Position + 1];
      Inc(Position);
      Permissions := 0;
      while CharacterAt(Text, Position) in ['r', 'w', 'x', 'X', 's', 't', 'u', 'g', 'o'] do
      begin
        case Text[Position + 1] of
          'r': Permissions := Permissions or Spread(4);
          'w': Permissions := Permissions or Spread(2);
          'x': Permissions := Permissions or Spread(1);
          'X':
            if IsDirectory or ((Result and $49) <> 0) then
              Permissions := Permissions or Spread(1);
          's': Permissions := Permissions or $C00;
          't': Permissions := Permissions or $200;
          'u': Permissions := Permissions or Spread((Result shr 6) and 7);
          'g': Permissions := Permissions or Spread((Result shr 3) and 7);
          'o': Permissions := Permissions or Spread(Result and 7);
        end;
        Inc(Position);
      end;
      Affected := Permissions and Mask;
      { Without who letters, "+" and "=" respect the usual umask. }
      if NoneGiven and (Operation <> '-') then
        Affected := Affected and not DefaultMask;
      case Operation of
        '+': Result := Result or Affected;
        '-': Result := Result and not Affected;
        '=':
          begin
            { Directories keep set-id bits unless explicitly named. }
            if IsDirectory then
              Result := (Result and not (Mask and $1FF)) or Affected
            else
              Result := (Result and not Mask) or Affected;
          end;
      end;
    end;
    if CharacterAt(Text, Position) = ',' then
      Inc(Position);
  end;
end;

function FormatModeText(Mode: LongWord): string;
const
  Letters: array[1..9] of Char = ('r', 'w', 'x', 'r', 'w', 'x', 'r', 'w', 'x');
var
  Bit: Integer;
begin
  SetLength(Result, 9);
  for Bit := 1 to 9 do
  begin
    if (Mode and (1 shl (9 - Bit))) <> 0 then
      Result[Bit] := Letters[Bit]
    else
      Result[Bit] := '-';
  end;
  { Special bits show in the execute positions. }
  if (Mode and $800) <> 0 then
    if Result[3] = 'x' then Result[3] := 's' else Result[3] := 'S';
  if (Mode and $400) <> 0 then
    if Result[6] = 'x' then Result[6] := 's' else Result[6] := 'S';
  if (Mode and $200) <> 0 then
    if Result[9] = 'x' then Result[9] := 't' else Result[9] := 'T';
end;

end.
