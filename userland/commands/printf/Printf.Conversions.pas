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
  One C style conversion for printf, which SysUtils' Format does not
  do (its flags, %o and lower case %x):

    %[flags][width][.precision]conversion

  flags:       '-' left align, '0' pad numbers with zeros, '+' show the
               sign of positive numbers
  conversions: s text, d/i signed decimal, u unsigned decimal, x/X hex,
               o octal, % a percent sign

  A conversion it does not know is copied through as it is written
  (with the text after it), as printf has always shown it.
}
unit Printf.Conversions;

{$mode objfpc}{$H+}

interface

type
  TConversionArgumentKind = (ConversionText, ConversionSigned, ConversionUnsigned);

  TConversionArgument = record
    Kind: TConversionArgumentKind;
    Text: string;
    Number: Int64;
  end;

function TextArgument(const Text: string): TConversionArgument;
function SignedArgument(Value: Int64): TConversionArgument;
function UnsignedArgument(Value: QWord): TConversionArgument;

{ Specification with its conversion filled in from Argument. }
function FormatConversion(const Specification: string; const Argument: TConversionArgument): string;

implementation

uses
  SysUtils;

type
  TConversionFlags = record
    LeftAlign: Boolean;
    ZeroPad: Boolean;
    ShowSign: Boolean;
    Width: Integer;
    Precision: Integer;
  end;

function TextArgument(const Text: string): TConversionArgument;
begin
  Result.Kind := ConversionText;
  Result.Text := Text;
  Result.Number := 0;
end;

function SignedArgument(Value: Int64): TConversionArgument;
begin
  Result.Kind := ConversionSigned;
  Result.Text := '';
  Result.Number := Value;
end;

function UnsignedArgument(Value: QWord): TConversionArgument;
begin
  Result.Kind := ConversionUnsigned;
  Result.Text := '';
  Result.Number := Int64(Value);
end;

{ The character at Position (from 1), #0 past the end. }
function CharacterAt(const Text: string; Position: Integer): Char;
begin
  if Position <= Length(Text) then
    Result := Text[Position]
  else
    Result := #0;
end;

{ Text padded to Width with PadCharacter (zeros go after a sign). }
function Padded(const Text: string; const Flags: TConversionFlags; PadCharacter: Char): string;
var
  Padding: Integer;
  Body: string;
begin
  Padding := Flags.Width - Length(Text);
  if Padding <= 0 then
    Exit(Text);
  if Flags.LeftAlign then
    Exit(Text + StringOfChar(' ', Padding));
  Result := '';
  Body := Text;
  if (PadCharacter = '0') and (Body <> '') and (Body[1] in ['-', '+']) then
  begin
    Result := Body[1];
    Delete(Body, 1, 1);
  end;
  Result := Result + StringOfChar(PadCharacter, Padding) + Body;
end;

function NumberPadding(const Flags: TConversionFlags): Char;
begin
  if Flags.ZeroPad then
    Result := '0'
  else
    Result := ' ';
end;

function UnsignedInBase(Value: QWord; Base: Integer): string;
const
  DigitCharacters = '0123456789ABCDEF';
begin
  Result := '';
  repeat
    Result := DigitCharacters[Value mod QWord(Base) + 1] + Result;
    Value := Value div QWord(Base);
  until Value = 0;
end;

function ConvertText(const Argument: TConversionArgument; const Flags: TConversionFlags): string;
begin
  if Argument.Kind = ConversionText then
    Result := Argument.Text
  else
    Result := IntToStr(Argument.Number);
  if (Flags.Precision >= 0) and (Length(Result) > Flags.Precision) then
    SetLength(Result, Flags.Precision);
  Result := Padded(Result, Flags, ' ');
end;

function ConvertSigned(const Argument: TConversionArgument; const Flags: TConversionFlags): string;
begin
  Result := IntToStr(Argument.Number);
  if Flags.ShowSign and (Argument.Number >= 0) then
    Result := '+' + Result;
  Result := Padded(Result, Flags, NumberPadding(Flags));
end;

function ConvertUnsigned(const Argument: TConversionArgument; const Flags: TConversionFlags;
  Conversion: Char): string;
begin
  case Conversion of
    'u': Result := UnsignedInBase(QWord(Argument.Number), 10);
    'o': Result := UnsignedInBase(QWord(Argument.Number), 8);
  else
    Result := UnsignedInBase(QWord(Argument.Number), 16);
  end;
  if Conversion = 'x' then
    Result := LowerCase(Result);
  Result := Padded(Result, Flags, NumberPadding(Flags));
end;

{ Reads the flags, width and precision from Position on. }
procedure ReadFlags(const Specification: string; var Position: Integer; out Flags: TConversionFlags);
begin
  Flags := Default(TConversionFlags);
  while CharacterAt(Specification, Position) in ['-', '0', '+'] do
  begin
    case Specification[Position] of
      '-': Flags.LeftAlign := True;
      '0': Flags.ZeroPad := True;
      '+': Flags.ShowSign := True;
    end;
    Inc(Position);
  end;
  while CharacterAt(Specification, Position) in ['0'..'9'] do
  begin
    Flags.Width := Flags.Width * 10 + Ord(Specification[Position]) - Ord('0');
    Inc(Position);
  end;
  Flags.Precision := -1;
  if CharacterAt(Specification, Position) = '.' then
  begin
    Inc(Position);
    Flags.Precision := 0;
    while CharacterAt(Specification, Position) in ['0'..'9'] do
    begin
      Flags.Precision := Flags.Precision * 10 + Ord(Specification[Position]) - Ord('0');
      Inc(Position);
    end;
  end;
end;

function FormatConversion(const Specification: string; const Argument: TConversionArgument): string;
var
  Position: Integer;
  Flags: TConversionFlags;
  Conversion: Char;
  Used: Boolean;
  Given: TConversionArgument;
begin
  Result := '';
  Used := False;
  Position := 1;
  while Position <= Length(Specification) do
  begin
    if Specification[Position] <> '%' then
    begin
      Result := Result + Specification[Position];
      Inc(Position);
      Continue;
    end;
    Inc(Position);
    ReadFlags(Specification, Position, Flags);
    Conversion := CharacterAt(Specification, Position);
    if Conversion = #0 then
      Break;
    Inc(Position);
    if Conversion = '%' then
    begin
      Result := Result + '%';
      Continue;
    end;
    { The one argument goes to the first conversion; any later one gets
      nothing. }
    if Used then
      Given := TextArgument('')
    else
      Given := Argument;
    Used := True;
    case Conversion of
      's': Result := Result + ConvertText(Given, Flags);
      'd', 'i': Result := Result + ConvertSigned(Given, Flags);
      'u', 'x', 'X', 'o': Result := Result + ConvertUnsigned(Given, Flags, Conversion);
    else
      Result := Result + '%' + Conversion;
    end;
  end;
end;

end.
