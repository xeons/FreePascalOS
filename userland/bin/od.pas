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
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Runtime.Text,
  Sys.Errors,
  Sys.Files,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
  Util.Messages,
  Util.Options,
  Util.Sizes;

const
  Usage: PChar = 'Usage: od [OPTION]... [FILE]...'#10 +
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
  MaximumFormats = 8;
  MaximumWidth = 256;

  NamedCharacters: array[0..32] of PChar = ('nul', 'soh', 'stx', 'etx', 'eot', 'enq', 'ack', 'bel',
    'bs', 'ht', 'nl', 'vt', 'ff', 'cr', 'so', 'si', 'dle', 'dc1', 'dc2', 'dc3', 'dc4', 'nak', 'syn',
    'etb', 'can', 'em', 'sub', 'esc', 'fs', 'gs', 'rs', 'us', 'sp');

type
  TFormat = record
    Kind: Char;    { a c d o u x }
    Size: Integer;
  end;

var
  Formats: array[0..MaximumFormats - 1] of TFormat;
  FormatCount: Integer;
  Radix: Char;
  Width: Integer;

procedure AddFormat(Kind: Char; Size: Integer);
begin
  if FormatCount = MaximumFormats then
    Fail(1, 'too many formats', []);
  Formats[FormatCount].Kind := Kind;
  Formats[FormatCount].Size := Size;
  Inc(FormatCount);
end;

procedure ParseFormat(Text: PChar);
var
  Position: Integer;
  Kind: Char;
  Size: Integer;
begin
  Position := 0;
  while Text[Position] <> #0 do
  begin
    Kind := Text[Position];
    Inc(Position);
    if not (Kind in ['a', 'c', 'd', 'o', 'u', 'x']) then
      Fail(1, 'invalid character ''%c'' in type string ''%s''', [ArgumentCharacter(Kind), ArgumentText(Text)]);
    Size := 1;
    if Kind in ['d', 'o', 'u', 'x'] then
    begin
      Size := 4;
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

procedure WriteOffset(Offset: QWord);
begin
  case Radix of
    'd': WriteFormatted(StandardOutput, '%07u', [ArgumentUnsigned(Offset)]);
    'x': WriteFormatted(StandardOutput, '%06x', [ArgumentUnsigned(Offset)]);
    'o': WriteFormatted(StandardOutput, '%07o', [ArgumentUnsigned(Offset)]);
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
    WriteCharacter(StandardOutput, ' ');
    case Format.Kind of
      'o': WriteFormatted(StandardOutput, '%0*o', [ArgumentNumber(Field), ArgumentUnsigned(Value)]);
      'x': WriteFormatted(StandardOutput, '%0*x', [ArgumentNumber(Field), ArgumentUnsigned(Value)]);
      'u': WriteFormatted(StandardOutput, '%*u', [ArgumentNumber(Field), ArgumentUnsigned(Value)]);
      'd':
        begin
          if (Format.Size < 8) and ((Value shr (8 * Format.Size - 1)) and 1 <> 0) then
            Signed := Int64(Value) - (Int64(1) shl (8 * Format.Size))
          else
            Signed := Int64(Value);
          WriteFormatted(StandardOutput, '%*d', [ArgumentNumber(Field), ArgumentNumber(Signed)]);
        end;
      'a':
        begin
          Character := Bytes[Index] and $7F;
          if Character <= 32 then
            WriteFormatted(StandardOutput, '%3s', [ArgumentText(NamedCharacters[Character])])
          else if Character = 127 then
            WriteText(StandardOutput, 'del')
          else
            WriteFormatted(StandardOutput, '%3c', [ArgumentCharacter(Char(Character))]);
        end;
      'c':
        begin
          Character := Bytes[Index];
          case Character of
            0: WriteText(StandardOutput, ' \0');
            7: WriteText(StandardOutput, ' \a');
            8: WriteText(StandardOutput, ' \b');
            9: WriteText(StandardOutput, ' \t');
            10: WriteText(StandardOutput, ' \n');
            11: WriteText(StandardOutput, ' \v');
            12: WriteText(StandardOutput, ' \f');
            13: WriteText(StandardOutput, ' \r');
          else
            if (Character >= 32) and (Character < 127) then
              WriteFormatted(StandardOutput, '%3c', [ArgumentCharacter(Char(Character))])
            else
              WriteFormatted(StandardOutput, '%03o', [ArgumentUnsigned(Character)]);
          end;
        end;
    end;
    Index := Index + Format.Size;
  end;
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Skip: QWord;
  Limit: Int64;
  ShowDuplicates: Boolean;
  Number: Int64;
  Size: QWord;
  FileIndex: Integer;
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
     MemoryIsEqual(@Line[0], @Previous[0], Width) then
  begin
    if not Suppressing then
      WriteLine(StandardOutput, '*');
    Suppressing := True;
  end
  else
  begin
    Suppressing := False;
    for FormatIndex := 0 to FormatCount - 1 do
    begin
      if FormatIndex = 0 then
        WriteOffset(Offset - QWord(LineFill))
      else if Radix <> 'n' then
        WriteText(StandardOutput, '       ');
      WriteLineInFormat(Formats[FormatIndex], @Line[0], LineFill);
      WriteCharacter(StandardOutput, #10);
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
  FormatCount := 0;
  BeginOptions(Parser, [
    OptionDefinition('A', 'address-radix', True, OptionRadix),
    OptionDefinition('j', 'skip-bytes', True, OptionSkip),
    OptionDefinition('N', 'read-bytes', True, OptionCount),
    OptionDefinition('t', 'format', True, OptionFormat),
    OptionDefinition('v', 'output-duplicates', False, OptionDuplicates),
    OptionDefinition('w', 'width', True, OptionWidth),
    OptionDefinition('b', nil, False, OptionB),
    OptionDefinition('c', nil, False, OptionC),
    OptionDefinition('d', nil, False, OptionD),
    OptionDefinition('o', nil, False, OptionO),
    OptionDefinition('x', nil, False, OptionX)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionRadix:
        begin
          if not (Value[0] in ['d', 'o', 'x', 'n']) or (Value[1] <> #0) then
            Fail(1, 'invalid output address radix ''%s''', [ArgumentText(Value)]);
          Radix := Value[0];
        end;
      OptionSkip:
        if not ParseSize(Value, Skip) then
          Fail(1, 'invalid skip count ''%s''', [ArgumentText(Value)]);
      OptionCount:
        begin
          if not ParseSize(Value, Size) then
            Fail(1, 'invalid count ''%s''', [ArgumentText(Value)]);
          Limit := Int64(Size);
        end;
      OptionFormat: ParseFormat(Value);
      OptionDuplicates: ShowDuplicates := True;
      OptionWidth:
        begin
          if not ParseInteger(Value, Number) or (Number < 1) or (Number > MaximumWidth) then
            Fail(1, 'invalid width ''%s''', [ArgumentText(Value)]);
          Width := Integer(Number);
        end;
      OptionB: AddFormat('o', 1);
      OptionC: AddFormat('c', 1);
      OptionD: AddFormat('u', 2);
      OptionO: AddFormat('o', 2);
      OptionX: AddFormat('x', 2);
    end;
  if FormatCount = 0 then
    AddFormat('o', 2);
  if Parser.OperandCount = 0 then
  begin
    Parser.Operands[0] := '-';
    Parser.OperandCount := 1;
  end;

  { All files form one stream of bytes. }
  ExitStatus := 0;
  Offset := 0;
  LineFill := 0;
  HavePrevious := False;
  Suppressing := False;
  Remaining := Limit;
  for FileIndex := 0 to Parser.OperandCount - 1 do
  begin
    if TextIsEqual(Parser.Operands[FileIndex], '-') then
      Handle := StandardInputHandle
    else
      Handle := OpenFile(Parser.Operands[FileIndex], OpenRead);
    if Handle < 0 then
    begin
      ReportError(ErrorCodeOf(Handle), '%s', [ArgumentText(Parser.Operands[FileIndex])]);
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
    WriteCharacter(StandardOutput, #10);
  end;
  Halt(ExitStatus);
end.
