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
  printf style formatting.

  A format string contains ordinary text and conversions:

    %[flags][width][.precision]conversion

  flags:       '-' left align, '0' pad numbers with zeros, '+' show the
               sign of positive numbers
  width and precision may be '*': taken from the next argument
  conversions: s text, d/i signed decimal, u unsigned decimal, x/X hex,
               o octal, c character, % a percent sign

  Arguments are passed as an array of TFormatArgument built with the
  Argument* functions, for example:

    FormatText('%s has %d lines', [ArgumentText(Name), ArgumentNumber(Count)])
}
unit Sys.Format;

{$mode objfpc}
{$pointermath on}

interface

uses
  Sys.Text,
  Sys.Streams;

type
  TFormatArgumentKind = (FormatArgumentText, FormatArgumentSigned, FormatArgumentUnsigned,
    FormatArgumentCharacter);

  TFormatArgument = record
    Kind: TFormatArgumentKind;
    Text: PChar;
    Number: Int64;
  end;

function ArgumentText(Text: PChar): TFormatArgument;
function ArgumentNumber(Value: Int64): TFormatArgument;
function ArgumentUnsigned(Value: QWord): TFormatArgument;
function ArgumentCharacter(Character: Char): TFormatArgument;

{ Appends the formatted text to Builder. }
procedure AppendFormatted(var Builder: TTextBuilder; Format: PChar; const Arguments: array of TFormatArgument);
{ Returns a new heap string. }
function FormatText(Format: PChar; const Arguments: array of TFormatArgument): PChar;
procedure WriteFormatted(Stream: POutputStream; Format: PChar; const Arguments: array of TFormatArgument);
procedure PrintFormatted(Format: PChar; const Arguments: array of TFormatArgument);

implementation

uses
  Runtime.Text,
  Sys.Memory;

function ArgumentText(Text: PChar): TFormatArgument;
begin
  Result.Kind := FormatArgumentText;
  if Text = nil then
    Result.Text := '(null)'
  else
    Result.Text := Text;
  Result.Number := 0;
end;

function ArgumentNumber(Value: Int64): TFormatArgument;
begin
  Result.Kind := FormatArgumentSigned;
  Result.Text := nil;
  Result.Number := Value;
end;

function ArgumentUnsigned(Value: QWord): TFormatArgument;
begin
  Result.Kind := FormatArgumentUnsigned;
  Result.Text := nil;
  Result.Number := Int64(Value);
end;

function ArgumentCharacter(Character: Char): TFormatArgument;
begin
  Result.Kind := FormatArgumentCharacter;
  Result.Text := nil;
  Result.Number := Ord(Character);
end;

procedure AppendPadded(var Builder: TTextBuilder; Text: PChar; Width: Integer;
  LeftAlign: Boolean; PadCharacter: Char);
var
  Length: Integer;
  Padding: Integer;
  Index: Integer;
begin
  Length := Integer(TextLength(Text));
  Padding := Width - Length;
  if (not LeftAlign) and (PadCharacter = '0') and (Padding > 0) and
     ((Text^ = '-') or (Text^ = '+')) then
  begin
    { Zeros go after the sign. }
    AppendCharacter(Builder, Text^);
    Inc(Text);
  end;
  if not LeftAlign then
    for Index := 1 to Padding do
      AppendCharacter(Builder, PadCharacter);
  AppendText(Builder, Text);
  if LeftAlign then
    for Index := 1 to Padding do
      AppendCharacter(Builder, ' ');
end;

procedure AppendFormatted(var Builder: TTextBuilder; Format: PChar; const Arguments: array of TFormatArgument);
var
  Position: PtrUInt;
  ArgumentIndex: Integer;
  LeftAlign: Boolean;
  ZeroPad: Boolean;
  ShowSign: Boolean;
  Width: Integer;
  Precision: Integer;
  Conversion: Char;
  Argument: TFormatArgument;
  NumberText: TNumberText;
  Converted: array[0..95] of Char;
  Value: PChar;
  Index: Integer;
begin
  Position := 0;
  ArgumentIndex := 0;
  while Format[Position] <> #0 do
  begin
    if Format[Position] <> '%' then
    begin
      AppendCharacter(Builder, Format[Position]);
      Inc(Position);
      Continue;
    end;
    Inc(Position);

    LeftAlign := False;
    ZeroPad := False;
    ShowSign := False;
    while (Format[Position] = '-') or (Format[Position] = '0') or (Format[Position] = '+') do
    begin
      case Format[Position] of
        '-': LeftAlign := True;
        '0': ZeroPad := True;
        '+': ShowSign := True;
      end;
      Inc(Position);
    end;
    Width := 0;
    if Format[Position] = '*' then
    begin
      { The width comes from the next argument. }
      if ArgumentIndex <= High(Arguments) then
        Width := Integer(Arguments[ArgumentIndex].Number);
      Inc(ArgumentIndex);
      Inc(Position);
      if Width < 0 then
      begin
        LeftAlign := True;
        Width := -Width;
      end;
    end;
    while IsDigit(Format[Position]) do
    begin
      Width := Width * 10 + Ord(Format[Position]) - Ord('0');
      Inc(Position);
    end;
    Precision := -1;
    if Format[Position] = '.' then
    begin
      Inc(Position);
      Precision := 0;
      if Format[Position] = '*' then
      begin
        if ArgumentIndex <= High(Arguments) then
          Precision := Integer(Arguments[ArgumentIndex].Number);
        Inc(ArgumentIndex);
        Inc(Position);
      end;
      while IsDigit(Format[Position]) do
      begin
        Precision := Precision * 10 + Ord(Format[Position]) - Ord('0');
        Inc(Position);
      end;
    end;

    Conversion := Format[Position];
    if Conversion = #0 then
      Break;
    Inc(Position);
    if Conversion = '%' then
    begin
      AppendCharacter(Builder, '%');
      Continue;
    end;

    if ArgumentIndex <= High(Arguments) then
      Argument := Arguments[ArgumentIndex]
    else
      Argument := ArgumentText('');
    Inc(ArgumentIndex);

    case Conversion of
      's':
        begin
          if Argument.Kind = FormatArgumentText then
            Value := Argument.Text
          else
            Value := FormatSignedDecimal(Argument.Number, NumberText);
          if (Precision >= 0) and (TextLength(Value) > PtrUInt(Precision)) then
          begin
            CopyText(@Converted[0], Value, PtrUInt(Precision) + 1);
            Value := @Converted[0];
          end;
          AppendPadded(Builder, Value, Width, LeftAlign, ' ');
        end;
      'd', 'i':
        begin
          Value := FormatSignedDecimal(Argument.Number, NumberText);
          if ShowSign and (Argument.Number >= 0) then
          begin
            Converted[0] := '+';
            CopyText(@Converted[1], Value, Length(Converted) - 1);
            Value := @Converted[0];
          end;
          if ZeroPad then
            AppendPadded(Builder, Value, Width, LeftAlign, '0')
          else
            AppendPadded(Builder, Value, Width, LeftAlign, ' ');
        end;
      'u', 'x', 'X', 'o':
        begin
          case Conversion of
            'u': Value := FormatUnsigned(QWord(Argument.Number), 10, 1, NumberText);
            'o': Value := FormatUnsigned(QWord(Argument.Number), 8, 1, NumberText);
          else
            Value := FormatUnsigned(QWord(Argument.Number), 16, 1, NumberText);
          end;
          if Conversion = 'x' then
          begin
            CopyText(@Converted[0], Value, Length(Converted));
            for Index := 0 to Integer(TextLength(@Converted[0])) - 1 do
              Converted[Index] := ToLowerCase(Converted[Index]);
            Value := @Converted[0];
          end;
          if ZeroPad then
            AppendPadded(Builder, Value, Width, LeftAlign, '0')
          else
            AppendPadded(Builder, Value, Width, LeftAlign, ' ');
        end;
      'c':
        begin
          Converted[0] := Char(Argument.Number);
          Converted[1] := #0;
          AppendPadded(Builder, @Converted[0], Width, LeftAlign, ' ');
        end;
    else
      begin
        { Unknown conversions are copied through unchanged. }
        AppendCharacter(Builder, '%');
        AppendCharacter(Builder, Conversion);
      end;
    end;
  end;
end;

function FormatText(Format: PChar; const Arguments: array of TFormatArgument): PChar;
var
  Builder: TTextBuilder;
begin
  BeginText(Builder);
  AppendFormatted(Builder, Format, Arguments);
  Result := FinishText(Builder);
end;

procedure WriteFormatted(Stream: POutputStream; Format: PChar; const Arguments: array of TFormatArgument);
var
  Builder: TTextBuilder;
begin
  BeginText(Builder);
  AppendFormatted(Builder, Format, Arguments);
  WriteBytes(Stream, Builder.Text, Builder.Length);
  DiscardText(Builder);
end;

procedure PrintFormatted(Format: PChar; const Arguments: array of TFormatArgument);
begin
  WriteFormatted(StandardOutput, Format, Arguments);
end;

end.
