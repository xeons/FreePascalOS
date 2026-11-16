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
  The values settings hold, and how they are written in a settings file.

  A value is a string, an integer (64-bit), a boolean or a list of
  strings. In a file, what follows "Key =" says which:

    "DejaVu Sans"            a string, in double quotes, with \" \\ \n
                             \r \t and \xHH for a quote, a backslash, the
                             control characters and any other byte
    150   -3   0x1F          an integer (decimal, or hexadecimal after 0x)
    true  false              a boolean (yes/no and on/off are read too)
    ["a", "b c"]             a list of strings (empty: [])
    /home/user/sky.bmp       anything else is a string as it stands
                             (spaces at its ends dropped), so files are
                             easy to write by hand

  Strings are always written quoted, so "true" or "150" stay strings
  when written back. Text is UTF-8 and is kept as it is; only control
  characters, quotes and backslashes are escaped.

  Reading is strict about kinds, so a value of the wrong kind never
  becomes a nonsense setting: an integer is only read from an integer.
  The one leniency is that any value but a list can be read as a string
  (its text).
}
unit Configuration.Values;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils;

type
  TSettingKind = (SettingString, SettingInteger, SettingBoolean, SettingList);

  TSettingValue = record
    Kind: TSettingKind;
    Text: string;
    Number: Int64;
    Flag: Boolean;
    Items: TStringArray;
  end;

function StringSetting(const Text: string): TSettingValue;
function IntegerSetting(Number: Int64): TSettingValue;
function BooleanSetting(Flag: Boolean): TSettingValue;
function ListSetting(const Items: TStringArray): TSettingValue;

{ The value as it is written after "Key = ". }
function FormatSettingValue(const Value: TSettingValue): string;
{ Reads what follows "Key = " in a file; False if it is malformed (an
  unfinished string or list, a bad escape). }
function ParseSettingValue(const Text: string; out Value: TSettingValue): Boolean;
{ Text in double quotes, escaped. }
function QuoteSettingText(const Text: string): string;

{ A string, or the text of an integer or boolean; False for a list. }
function SettingAsString(const Value: TSettingValue; out Text: string): Boolean;
function SettingAsInteger(const Value: TSettingValue; out Number: Int64): Boolean;
function SettingAsBoolean(const Value: TSettingValue; out Flag: Boolean): Boolean;
function SettingAsList(const Value: TSettingValue; out Items: TStringArray): Boolean;
function SameSettingValue(const First, Second: TSettingValue): Boolean;
function SettingKindName(Kind: TSettingKind): string;

implementation

const
  HexadecimalDigits = '0123456789ABCDEF';

function StringSetting(const Text: string): TSettingValue;
begin
  Result := Default(TSettingValue);
  Result.Kind := SettingString;
  Result.Text := Text;
end;

function IntegerSetting(Number: Int64): TSettingValue;
begin
  Result := Default(TSettingValue);
  Result.Kind := SettingInteger;
  Result.Number := Number;
end;

function BooleanSetting(Flag: Boolean): TSettingValue;
begin
  Result := Default(TSettingValue);
  Result.Kind := SettingBoolean;
  Result.Flag := Flag;
end;

function ListSetting(const Items: TStringArray): TSettingValue;
begin
  Result := Default(TSettingValue);
  Result.Kind := SettingList;
  Result.Items := Copy(Items);
end;

function QuoteSettingText(const Text: string): string;
var
  Index: Integer;
  Character: Char;
begin
  Result := '"';
  for Index := 1 to Length(Text) do
  begin
    Character := Text[Index];
    case Character of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #10: Result := Result + '\n';
      #13: Result := Result + '\r';
      #9: Result := Result + '\t';
      #0..#8, #11, #12, #14..#31, #127:
        Result := Result + '\x' + HexadecimalDigits[Ord(Character) shr 4 + 1] +
          HexadecimalDigits[Ord(Character) and 15 + 1];
    else
      Result := Result + Character;
    end;
  end;
  Result := Result + '"';
end;

function FormatSettingValue(const Value: TSettingValue): string;
var
  Index: Integer;
begin
  case Value.Kind of
    SettingString: Result := QuoteSettingText(Value.Text);
    SettingInteger: Result := IntToStr(Value.Number);
    SettingBoolean:
      if Value.Flag then
        Result := 'true'
      else
        Result := 'false';
    SettingList:
      begin
        Result := '[';
        for Index := 0 to High(Value.Items) do
        begin
          if Index > 0 then
            Result := Result + ', ';
          Result := Result + QuoteSettingText(Value.Items[Index]);
        end;
        Result := Result + ']';
      end;
  end;
end;

function HexadecimalValue(Character: Char; out Digit: Integer): Boolean;
begin
  Result := True;
  case Character of
    '0'..'9': Digit := Ord(Character) - Ord('0');
    'A'..'F': Digit := Ord(Character) - Ord('A') + 10;
    'a'..'f': Digit := Ord(Character) - Ord('a') + 10;
  else
    Digit := 0;
    Result := False;
  end;
end;

{ Reads a quoted string starting at Text[Position] (the opening quote);
  Position ends after the closing quote. }
function ReadQuoted(const Text: string; var Position: Integer; out Unquoted: string): Boolean;
var
  Character: Char;
  HighDigit: Integer;
  LowDigit: Integer;
begin
  Unquoted := '';
  Inc(Position);
  while Position <= Length(Text) do
  begin
    Character := Text[Position];
    Inc(Position);
    if Character = '"' then
      Exit(True);
    if Character <> '\' then
    begin
      Unquoted := Unquoted + Character;
      Continue;
    end;
    if Position > Length(Text) then
      Exit(False);
    Character := Text[Position];
    Inc(Position);
    case Character of
      '"', '\': Unquoted := Unquoted + Character;
      'n': Unquoted := Unquoted + #10;
      'r': Unquoted := Unquoted + #13;
      't': Unquoted := Unquoted + #9;
      'x':
        begin
          if (Position + 1 > Length(Text)) or not HexadecimalValue(Text[Position], HighDigit) or
             not HexadecimalValue(Text[Position + 1], LowDigit) then
            Exit(False);
          Unquoted := Unquoted + Chr(HighDigit * 16 + LowDigit);
          Inc(Position, 2);
        end;
    else
      Exit(False);
    end;
  end;
  Result := False;
end;

procedure SkipSpaces(const Text: string; var Position: Integer);
begin
  while (Position <= Length(Text)) and (Text[Position] in [' ', #9]) do
    Inc(Position);
end;

function ParseList(const Text: string; out Items: TStringArray): Boolean;
var
  Position: Integer;
  Item: string;
  Start: Integer;
  Count: Integer;
begin
  Items := nil;
  Count := 0;
  Position := 2;
  SkipSpaces(Text, Position);
  if (Position <= Length(Text)) and (Text[Position] = ']') then
    Exit(Position = Length(Text));
  while Position <= Length(Text) do
  begin
    SkipSpaces(Text, Position);
    if (Position <= Length(Text)) and (Text[Position] = '"') then
    begin
      if not ReadQuoted(Text, Position, Item) then
        Exit(False);
    end
    else
    begin
      { A bare item runs to the next comma or the end of the list. }
      Start := Position;
      while (Position <= Length(Text)) and not (Text[Position] in [',', ']']) do
        Inc(Position);
      Item := Trim(Copy(Text, Start, Position - Start));
      if Item = '' then
        Exit(False);
    end;
    SetLength(Items, Count + 1);
    Items[Count] := Item;
    Inc(Count);
    SkipSpaces(Text, Position);
    if Position > Length(Text) then
      Exit(False);
    if Text[Position] = ']' then
      Exit(Position = Length(Text));
    if Text[Position] <> ',' then
      Exit(False);
    Inc(Position);
  end;
  Result := False;
end;

function ParseBoolean(const Text: string; out Flag: Boolean): Boolean;
var
  Lower: string;
begin
  Lower := LowerCase(Text);
  Result := True;
  if (Lower = 'true') or (Lower = 'yes') or (Lower = 'on') then
    Flag := True
  else if (Lower = 'false') or (Lower = 'no') or (Lower = 'off') then
    Flag := False
  else
    Result := False;
end;

function ParseInteger(const Text: string; out Number: Int64): Boolean;
var
  Index: Integer;
  Digits: string;
  Negative: Boolean;
begin
  Number := 0;
  Digits := Text;
  Negative := False;
  if (Digits <> '') and (Digits[1] in ['-', '+']) then
  begin
    Negative := Digits[1] = '-';
    Delete(Digits, 1, 1);
  end;
  if Digits = '' then
    Exit(False);
  if (Length(Digits) > 2) and (Digits[1] = '0') and (Digits[2] in ['x', 'X']) then
  begin
    for Index := 3 to Length(Digits) do
      if not (Digits[Index] in ['0'..'9', 'A'..'F', 'a'..'f']) then
        Exit(False);
    Result := TryStrToInt64('$' + Copy(Digits, 3, Length(Digits)), Number);
  end
  else
  begin
    for Index := 1 to Length(Digits) do
      if not (Digits[Index] in ['0'..'9']) then
        Exit(False);
    Result := TryStrToInt64(Digits, Number);
  end;
  if Result and Negative then
    Number := -Number;
end;

function ParseSettingValue(const Text: string; out Value: TSettingValue): Boolean;
var
  Trimmed: string;
  Position: Integer;
  Unquoted: string;
  Items: TStringArray;
  Number: Int64;
  Flag: Boolean;
begin
  Value := StringSetting('');
  Trimmed := Trim(Text);
  if (Trimmed <> '') and (Trimmed[1] = '"') then
  begin
    Position := 1;
    if not ReadQuoted(Trimmed, Position, Unquoted) or (Position <= Length(Trimmed)) then
      Exit(False);
    Value := StringSetting(Unquoted);
  end
  else if (Trimmed <> '') and (Trimmed[1] = '[') then
  begin
    if not ParseList(Trimmed, Items) then
      Exit(False);
    Value := ListSetting(Items);
  end
  else if ParseBoolean(Trimmed, Flag) then
    Value := BooleanSetting(Flag)
  else if ParseInteger(Trimmed, Number) then
    Value := IntegerSetting(Number)
  else
    Value := StringSetting(Trimmed);
  Result := True;
end;

function SettingAsString(const Value: TSettingValue; out Text: string): Boolean;
begin
  Result := True;
  case Value.Kind of
    SettingString: Text := Value.Text;
    SettingInteger, SettingBoolean: Text := FormatSettingValue(Value);
  else
    Text := '';
    Result := False;
  end;
end;

function SettingAsInteger(const Value: TSettingValue; out Number: Int64): Boolean;
begin
  Result := Value.Kind = SettingInteger;
  Number := Value.Number;
end;

function SettingAsBoolean(const Value: TSettingValue; out Flag: Boolean): Boolean;
begin
  Result := Value.Kind = SettingBoolean;
  Flag := Value.Flag;
end;

function SettingAsList(const Value: TSettingValue; out Items: TStringArray): Boolean;
begin
  Result := Value.Kind = SettingList;
  Items := Copy(Value.Items);
end;

function SameSettingValue(const First, Second: TSettingValue): Boolean;
begin
  Result := (First.Kind = Second.Kind) and (FormatSettingValue(First) = FormatSettingValue(Second));
end;

function SettingKindName(Kind: TSettingKind): string;
begin
  case Kind of
    SettingString: Result := 'string';
    SettingInteger: Result := 'integer';
    SettingBoolean: Result := 'boolean';
  else
    Result := 'list';
  end;
end;

end.
