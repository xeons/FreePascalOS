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
  Small text helpers the shell's scanners share.

  The scanners (lexer, expansion, patterns, arithmetic) look one or two
  characters ahead; CharAt gives #0 past the end of the text, so a look
  ahead never needs its own bounds check. Text the shell takes in is cut
  at its first NUL (TextBeforeNull): a NUL ends shell input and
  variable values, as the strings handed to programs end there anyway.
}
unit Shell.Text;

{$mode objfpc}
{$H+}
{$modeswitch advancedrecords}

interface

uses
  SysUtils,
  Classes;

type
  { Text built a character at a time, with room to grow, so that each
    append does not reallocate. }
  TTextBuffer = record
  private
    FText: string;
    FLength: Integer;
    procedure Reserve(Extra: Integer);
  public
    procedure Clear;
    procedure Append(Character: Char); overload;
    procedure Append(const Text: string); overload;
    function Value: string;
    property Length: Integer read FLength;
  end;

{ Text[Index] (1-based), or #0 outside the text. }
function CharAt(const Text: string; Index: Integer): Char; inline;
{ Text up to its first NUL. }
function TextBeforeNull(const Text: string): string;
{ A decimal integer with an optional '-' (and leading blanks), as
  everywhere in the system; nothing else is accepted. }
function TryParseInteger(const Text: string; out Value: Int64): Boolean;

{ A letter or '_'; a name continues with letters, digits and '_'. }
function IsNameStart(Character: Char): Boolean;
function IsNameCharacter(Character: Char): Boolean;

{ Items[First..] of List. }
function StringsFrom(List: TStrings; First: Integer): TStringArray;

implementation

uses
  Sys.Text,
  Util.Numbers;

function CharAt(const Text: string; Index: Integer): Char;
begin
  if (Index >= 1) and (Index <= Length(Text)) then
    Result := Text[Index]
  else
    Result := #0;
end;

function TextBeforeNull(const Text: string): string;
var
  NullPosition: Integer;
begin
  NullPosition := Pos(#0, Text);
  if NullPosition = 0 then
    Result := Text
  else
    Result := Copy(Text, 1, NullPosition - 1);
end;

function TryParseInteger(const Text: string; out Value: Int64): Boolean;
begin
  Result := ParseDecimal(Text, Value);
end;

function IsNameStart(Character: Char): Boolean;
begin
  Result := IsLetter(Character) or (Character = '_');
end;

function IsNameCharacter(Character: Char): Boolean;
begin
  Result := IsAlphanumeric(Character) or (Character = '_');
end;

function StringsFrom(List: TStrings; First: Integer): TStringArray;
var
  Index: Integer;
begin
  Result := nil;
  if First >= List.Count then
    Exit;
  SetLength(Result, List.Count - First);
  for Index := First to List.Count - 1 do
    Result[Index - First] := List[Index];
end;

{ --- TTextBuffer ------------------------------------------------------- }

procedure TTextBuffer.Reserve(Extra: Integer);
var
  Capacity: Integer;
begin
  Capacity := System.Length(FText);
  if FLength + Extra <= Capacity then
    Exit;
  Capacity := Capacity * 2 + 64;
  if Capacity < FLength + Extra then
    Capacity := FLength + Extra;
  SetLength(FText, Capacity);
end;

procedure TTextBuffer.Clear;
begin
  FText := '';
  FLength := 0;
end;

procedure TTextBuffer.Append(Character: Char);
begin
  Reserve(1);
  Inc(FLength);
  FText[FLength] := Character;
end;

procedure TTextBuffer.Append(const Text: string);
begin
  if Text = '' then
    Exit;
  Reserve(System.Length(Text));
  Move(Text[1], FText[FLength + 1], System.Length(Text));
  Inc(FLength, System.Length(Text));
end;

function TTextBuffer.Value: string;
begin
  Result := Copy(FText, 1, FLength);
end;

end.
