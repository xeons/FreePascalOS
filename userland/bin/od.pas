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
  od - dump files in octal and other formats

  od [-A RADIX] [-t TYPE]... [-j SKIP] [-N COUNT] [-w WIDTH] [-v] [FILE]...
  od [-bcdox] [FILE]...

  TYPE is a (named characters), c (characters), d SIZE (signed decimal),
  o SIZE (octal), u SIZE (unsigned decimal) or x SIZE (hexadecimal);
  SIZE is 1, 2, 4 or 8 bytes (C, S, I, L also work). Repeated lines are
  shown as "*" unless -v. Offsets are octal by default (-A d, x, o, n).
}
program od;

{$mode objfpc}
{$H+}
{$pointermath on}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Files,
  Sys.Streams,
  Util.CommandLine,
  Util.Messages,
  Util.Numbers,
  Util.Output,
  Util.Sizes;

const
  Usage = 'Usage: od [OPTION]... [FILE]...'#10 +
    'Write an unambiguous representation, octal bytes by default,'#10 +
    'of FILE to standard output.'#10#10 +
    '  -A, --address-radix=RADIX   output format for file offsets; RADIX is one'#10 +
    '                                of [doxn], for Decimal, Octal, Hex or None'#10 +
    '  -j, --skip-bytes=BYTES      skip BYTES input bytes first'#10 +
    '  -N, --read-bytes=BYTES      limit dump to BYTES input bytes'#10 +
    '  -t, --format=TYPE           select output format or formats'#10 +
    '  -v, --output-duplicates     do not use * to mark line suppression'#10 +
    '  -w, --width[=BYTES]         output BYTES bytes per output line'#10 +
    '  -b  same as -t o1    -c  same as -t c    -d  same as -t u2'#10 +
    '  -o  same as -t o2    -x  same as -t x2'#10;

  OptionRadix = 1;
  OptionSkip = 2;
  OptionCount = 3;
  OptionFormat = 4;
  OptionDuplicates = 5;
  OptionWidth = 6;
  OptionB = 7;
  OptionC = 8;
  OptionD = 9;
  OptionO = 10;
  OptionX = 11;
  MaximumWidth = 256;

  NamedCharacters: array[0..32] of string = ('nul', 'soh', 'stx', 'etx', 'eot', 'enq', 'ack', 'bel',
    'bs', 'ht', 'nl', 'vt', 'ff', 'cr', 'so', 'si', 'dle', 'dc1', 'dc2', 'dc3', 'dc4', 'nak', 'syn',
    'etb', 'can', 'em', 'sub', 'esc', 'fs', 'gs', 'rs', 'us', 'sp');

type
  TFormat = record
    Kind: Char;    { a c d o u x }
    Size: Integer;
  end;

var
  Formats: array of TFormat;
  Radix: Char;
  Width: Integer;

procedure AddFormat(Kind: Char; Size: Integer);
var
  Format: TFormat;
begin
  Format.Kind := Kind;
  Format.Size := Size;
  Insert(Format, Formats, Length(Formats));
end;

procedure ParseFormat(const Text: string);
var
  Position: Integer;
  Kind: Char;
  Size: Integer;
begin
  Position := 1;
  while Position <= Length(Text) do
  begin
    Kind := Text[Position];
    Inc(Position);
    if not (Kind in ['a', 'c', 'd', 'o', 'u', 'x']) then
      Fail(1, SysUtils.Format('invalid character ''%s'' in type string ''%s''', [Kind, Text]));
    Size := 1;
    if Kind in ['d', 'o', 'u', 'x'] then
      Size := 4;
    if (Kind in ['d', 'o', 'u', 'x']) and (Position <= Length(Text)) then
    begin
      case Text[Position] of
        'C': begin Size := 1; Inc(Position); end;
        'S': begin Size := 2; Inc(Position); end;
        'I': begin Size := 4; Inc(Position); end;
        'L': begin Size := 8; Inc(Position); end;
        '1', '2', '4', '8':
          begin
            Size := Ord(Text[Position]) - Ord('0');
            Inc(Position);
          end;
      end;
    end;
    AddFormat(Kind, Size);
  end;
end;

{ Text padded with spaces on the left to Width columns. }
function RightAligned(const Text: string; Width: Integer): string;
begin
  Result := StringOfChar(' ', Width - Length(Text)) + Text;
end;

{ Text padded with zeros on the left to Width digits. }
function ZeroFilled(const Text: string; Width: Integer): string;
begin
  Result := StringOfChar('0', Width - Length(Text)) + Text;
end;

function LowerHexText(Value: QWord; Digits: Integer): string;
begin
  Result := LowerCase(IntToHex(Value, Digits));
end;

procedure WriteOffset(Offset: QWord);
begin
  case Radix of
    'd': PrintString(ZeroFilled(UIntToStr(Offset), 7));
    'x': PrintString(LowerHexText(Offset, 6));
    'o': PrintString(OctalText(Offset, 7));
  end;
end;

function FieldWidth(const Format: TFormat): Integer;
begin
  case Format.Kind of
    'a', 'c': Result := 3;
    'o': case Format.Size of 1: Result := 3; 2: Result := 6; 4: Result := 11; else Result := 22; end;
    'x': Result := 2 * Format.Size;
    'u': case Format.Size of 1: Result := 3; 2: Result := 5; 4: Result := 10; else Result := 20; end;
  else
    case Format.Size of 1: Result := 4; 2: Result := 6; 4: Result := 11; else Result := 20; end;
  end;
end;

procedure WriteLineInFormat(const Format: TFormat; Bytes: PByte; Count: Integer);
var
  Index: Integer;
  Value: QWord;
  Signed: Int64;
  ByteIndex: Integer;
  Field: Integer;
  Character: Byte;
begin
  Field := FieldWidth(Format);
  Index := 0;
  while Index < Count do
  begin
    Value := 0;
    for ByteIndex := Format.Size - 1 downto 0 do
    begin
      Value := Value shl 8;
      if Index + ByteIndex < Count then
        Value := Value or Bytes[Index + ByteIndex];
    end;
    PrintString(' ');
    case Format.Kind of
      'o': PrintString(OctalText(Value, Field));
      'x': PrintString(LowerHexText(Value, Field));
      'u': PrintString(RightAligned(UIntToStr(Value), Field));
      'd':
        begin
          if (Format.Size < 8) and ((Value shr (8 * Format.Size - 1)) and 1 <> 0) then
            Signed := Int64(Value) - (Int64(1) shl (8 * Format.Size))
          else
            Signed := Int64(Value);
          PrintString(RightAligned(IntToStr(Signed), Field));
        end;
      'a':
        begin
          Character := Bytes[Index] and $7F;
          if Character <= 32 then
            PrintString(RightAligned(NamedCharacters[Character], 3))
          else if Character = 127 then
            PrintString('del')
          else
            PrintString(RightAligned(Char(Character), 3));
        end;
      'c':
        begin
          Character := Bytes[Index];
          case Character of
            0: PrintString(' \0');
            7: PrintString(' \a');
            8: PrintString(' \b');
            9: PrintString(' \t');
            10: PrintString(' \n');
            11: PrintString(' \v');
            12: PrintString(' \f');
            13: PrintString(' \r');
          else
            if (Character >= 32) and (Character < 127) then
              PrintString(RightAligned(Char(Character), 3))
            else
              PrintString(OctalText(Character, 3));
          end;
        end;
    end;
    Index := Index + Format.Size;
  end;
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Skip: QWord;
  Limit: Int64;
  ShowDuplicates: Boolean;
  Number: Int64;
  Size: QWord;
  FileName: string;
  Handle: Int64;
  Line: array[0..MaximumWidth - 1] of Byte;
  Previous: array[0..MaximumWidth - 1] of Byte;
  HavePrevious: Boolean;
  Suppressing: Boolean;
  LineFill: Integer;
  Offset: QWord;
  Remaining: Int64;
  Byte1: Byte;
  Count: Int64;
  Index: Integer;
  ExitStatus: LongInt;

procedure FlushLine;
var
  FormatIndex: Integer;
begin
  if LineFill = 0 then
    Exit;
  if not ShowDuplicates and HavePrevious and (LineFill = Width) and
     CompareMem(@Line[0], @Previous[0], Width) then
  begin
    if not Suppressing then
      PrintStringLine('*');
    Suppressing := True;
  end
  else
  begin
    Suppressing := False;
    for FormatIndex := 0 to High(Formats) do
    begin
      if FormatIndex = 0 then
        WriteOffset(Offset - QWord(LineFill))
      else if Radix <> 'n' then
        PrintString('       ');
      WriteLineInFormat(Formats[FormatIndex], @Line[0], LineFill);
      PrintString(#10);
    end;
  end;
  for Index := 0 to LineFill - 1 do
    Previous[Index] := Line[Index];
  HavePrevious := LineFill = Width;
  LineFill := 0;
end;

begin
  Radix := 'o';
  Width := 16;
  Skip := 0;
  Limit := -1;
  ShowDuplicates := False;
  CommandLine := TCommandLine.Create([
    CommandOption('A', 'address-radix', True, OptionRadix),
    CommandOption('j', 'skip-bytes', True, OptionSkip),
    CommandOption('N', 'read-bytes', True, OptionCount),
    CommandOption('t', 'format', True, OptionFormat),
    CommandOption('v', 'output-duplicates', False, OptionDuplicates),
    CommandOption('w', 'width', True, OptionWidth),
    CommandOption('b', '', False, OptionB),
    CommandOption('c', '', False, OptionC),
    CommandOption('d', '', False, OptionD),
    CommandOption('o', '', False, OptionO),
    CommandOption('x', '', False, OptionX)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionRadix:
        begin
          if (Length(Value) <> 1) or not (Value[1] in ['d', 'o', 'x', 'n']) then
            Fail(1, SysUtils.Format('invalid output address radix ''%s''', [Value]));
          Radix := Value[1];
        end;
      OptionSkip:
        if not ParseSize(Value, Skip) then
          Fail(1, SysUtils.Format('invalid skip count ''%s''', [Value]));
      OptionCount:
        begin
          if not ParseSize(Value, Size) then
            Fail(1, SysUtils.Format('invalid count ''%s''', [Value]));
          Limit := Int64(Size);
        end;
      OptionFormat: ParseFormat(Value);
      OptionDuplicates: ShowDuplicates := True;
      OptionWidth:
        begin
          if not ParseDecimal(Value, Number) or (Number < 1) or (Number > MaximumWidth) then
            Fail(1, SysUtils.Format('invalid width ''%s''', [Value]));
          Width := Integer(Number);
        end;
      OptionB: AddFormat('o', 1);
      OptionC: AddFormat('c', 1);
      OptionD: AddFormat('u', 2);
      OptionO: AddFormat('o', 2);
      OptionX: AddFormat('x', 2);
    end;
  if Length(Formats) = 0 then
    AddFormat('o', 2);
  if CommandLine.OperandCount = 0 then
    CommandLine.Operands := ['-'];

  { All files form one stream of bytes. }
  ExitStatus := 0;
  Offset := 0;
  LineFill := 0;
  HavePrevious := False;
  Suppressing := False;
  Remaining := Limit;
  for FileName in CommandLine.Operands do
  begin
    if FileName = '-' then
      Handle := StandardInputHandle
    else
      Handle := OpenFile(PChar(FileName), OpenRead);
    if Handle < 0 then
    begin
      ReportError(ErrorCodeOf(Handle), FileName);
      ExitStatus := 1;
      Continue;
    end;
    repeat
      if Remaining = 0 then
        Break;
      Count := ReadFile(Handle, @Byte1, 1);
      if Count <= 0 then
        Break;
      if Skip > 0 then
      begin
        Dec(Skip);
        Continue;
      end;
      Line[LineFill] := Byte1;
      Inc(LineFill);
      Inc(Offset);
      if Remaining > 0 then
        Dec(Remaining);
      if LineFill = Width then
        FlushLine;
    until False;
    if Handle <> StandardInputHandle then
      CloseFile(Handle);
  end;
  FlushLine;
  if Radix <> 'n' then
  begin
    WriteOffset(Offset);
    PrintString(#10);
  end;
  Halt(ExitStatus);
end.
