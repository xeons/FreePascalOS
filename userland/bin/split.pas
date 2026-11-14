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
  split - split a file into pieces

  split [-l LINES | -b SIZE | -C SIZE | -n CHUNKS] [-a LENGTH] [-d | -x]
        [--additional-suffix=SUFFIX] [FILE [PREFIX]]

  Pieces are named PREFIX (default "x") followed by aa, ab, ... (or 00,
  01, ... with -d). The default is 1000 lines per piece.
}
program split;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
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
  Usage: PChar = 'Usage: split [OPTION]... [FILE [PREFIX]]'#10 +
    'Output pieces of FILE to PREFIXaa, PREFIXab, ...;'#10 +
    'default size is 1000 lines, and default PREFIX is ''x''.'#10#10 +
    '  -a, --suffix-length=N   generate suffixes of length N (default 2)'#10 +
    '      --additional-suffix=SUFFIX  append an additional SUFFIX to file names'#10 +
    '  -b, --bytes=SIZE        put SIZE bytes per output file'#10 +
    '  -C, --line-bytes=SIZE   put at most SIZE bytes of records per output file'#10 +
    '  -d                      use numeric suffixes starting at 0, not alphabetic'#10 +
    '  -x                      use hex suffixes starting at 0, not alphabetic'#10 +
    '  -l, --lines=NUMBER      put NUMBER lines/records per output file'#10 +
    '  -n, --number=CHUNKS     generate CHUNKS output files of equal size'#10 +
    '      --verbose           print a diagnostic just before each'#10 +
    '                            output file is opened'#10;

  OptionSuffixLength = 1;
  OptionAdditionalSuffix = 2;
  OptionBytes = 3;
  OptionLineBytes = 4;
  OptionNumeric = 5;
  OptionHex = 6;
  OptionLines = 7;
  OptionChunks = 8;
  OptionVerbose = 9;

type
  TSplitMode = (SplitLines, SplitBytes, SplitLineBytes, SplitChunks);

var
  Prefix: PChar;
  Suffix: PChar;
  SuffixLength: Integer;
  SuffixAlphabet: PChar;
  Verbose: Boolean;
  PieceNumber: QWord;
  PieceHandle: Int64;
  PieceStream: POutputStream;

function PieceName: PChar;
var
  Builder: TTextBuilder;
  Digits: array[0..63] of Char;
  Base: QWord;
  Value: QWord;
  Index: Integer;
begin
  Base := TextLength(SuffixAlphabet);
  Value := PieceNumber;
  for Index := SuffixLength - 1 downto 0 do
  begin
    Digits[Index] := SuffixAlphabet[Value mod Base];
    Value := Value div Base;
  end;
  if Value <> 0 then
    Fail(1, 'output file suffixes exhausted', []);
  Digits[SuffixLength] := #0;
  BeginText(Builder);
  AppendText(Builder, Prefix);
  AppendText(Builder, @Digits[0]);
  AppendText(Builder, Suffix);
  Result := FinishText(Builder);
end;

procedure ClosePiece;
begin
  if PieceStream = nil then
    Exit;
  DestroyOutputStream(PieceStream);
  CloseFile(PieceHandle);
  PieceStream := nil;
end;

procedure OpenNextPiece;
var
  Name: PChar;
begin
  ClosePiece;
  Name := PieceName;
  if Verbose then
    WriteFormatted(StandardOutput, 'creating file ''%s'''#10, [ArgumentText(Name)]);
  PieceHandle := OpenFile(Name, OpenWrite or OpenCreate or OpenTruncate);
  if PieceHandle < 0 then
    FailWithError(1, ErrorCodeOf(PieceHandle), '%s', [ArgumentText(Name)]);
  PieceStream := CreateOutputStream(PieceHandle);
  FreeMemory(Name);
  Inc(PieceNumber);
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Mode: TSplitMode;
  Amount: QWord;
  Number: Int64;
  Input: Int64;
  Buffer: PChar;
  Count: Int64;
  Index: Int64;
  InPiece: QWord;
  Information: TFileInformation;
  TotalSize: QWord;
  ChunkSize: QWord;
  Pending: TTextBuilder;
begin
  Prefix := 'x';
  Suffix := '';
  SuffixLength := 2;
  SuffixAlphabet := 'abcdefghijklmnopqrstuvwxyz';
  Mode := SplitLines;
  Amount := 1000;
  BeginOptions(Parser, [
    OptionDefinition('a', 'suffix-length', True, OptionSuffixLength),
    OptionDefinition(#0, 'additional-suffix', True, OptionAdditionalSuffix),
    OptionDefinition('b', 'bytes', True, OptionBytes),
    OptionDefinition('C', 'line-bytes', True, OptionLineBytes),
    OptionDefinition('d', 'numeric-suffixes', False, OptionNumeric),
    OptionDefinition('x', 'hex-suffixes', False, OptionHex),
    OptionDefinition('l', 'lines', True, OptionLines),
    OptionDefinition('n', 'number', True, OptionChunks),
    OptionDefinition(#0, 'verbose', False, OptionVerbose)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionSuffixLength:
        begin
          if not ParseInteger(Value, Number) or (Number < 1) or (Number > 60) then
            Fail(1, 'invalid suffix length: ''%s''', [ArgumentText(Value)]);
          SuffixLength := Integer(Number);
        end;
      OptionAdditionalSuffix: Suffix := Value;
      OptionBytes, OptionLineBytes, OptionLines, OptionChunks:
        begin
          if not ParseSize(Value, Amount) or (Amount = 0) then
            Fail(1, 'invalid number: ''%s''', [ArgumentText(Value)]);
          case Code of
            OptionBytes: Mode := SplitBytes;
            OptionLineBytes: Mode := SplitLineBytes;
            OptionLines: Mode := SplitLines;
          else
            Mode := SplitChunks;
          end;
        end;
      OptionNumeric: SuffixAlphabet := '0123456789';
      OptionHex: SuffixAlphabet := '0123456789abcdef';
      OptionVerbose: Verbose := True;
    end;
  if Parser.OperandCount > 2 then
    FailWithUsageHint('extra operand ''%s''', [ArgumentText(Parser.Operands[2])]);
  if Parser.OperandCount = 2 then
    Prefix := Parser.Operands[1];

  Input := StandardInputHandle;
  if (Parser.OperandCount >= 1) and not TextIsEqual(Parser.Operands[0], '-') then
  begin
    Input := OpenFile(Parser.Operands[0], OpenRead);
    if Input < 0 then
      FailWithError(1, ErrorCodeOf(Input), 'cannot open ''%s'' for reading', [ArgumentText(Parser.Operands[0])]);
  end;

  if Mode = SplitChunks then
  begin
    if (GetHandleInformation(Input, Information) <> 0) or (Information.Kind <> KindFile) then
      Fail(1, 'cannot determine file size', []);
    TotalSize := Information.SizeInBytes;
    ChunkSize := TotalSize div Amount;
    Mode := SplitBytes;
    { The last piece takes the remainder. }
    Amount := ChunkSize;
    if Amount = 0 then
      Amount := 1;
  end;

  Buffer := PChar(AllocateMemory(65536));
  PieceStream := nil;
  PieceNumber := 0;
  InPiece := 0;
  BeginText(Pending);
  repeat
    Count := ReadFile(Input, Buffer, 65536);
    if Count < 0 then
      FailWithError(1, ErrorCodeOf(Count), 'read error', []);
    Index := 0;
    while Index < Count do
    begin
      case Mode of
        SplitBytes:
          begin
            if (PieceStream = nil) or (InPiece = Amount) then
            begin
              OpenNextPiece;
              InPiece := 0;
            end;
            WriteCharacter(PieceStream, Buffer[Index]);
            Inc(InPiece);
          end;
        SplitLines:
          begin
            if PieceStream = nil then
            begin
              OpenNextPiece;
              InPiece := 0;
            end;
            WriteCharacter(PieceStream, Buffer[Index]);
            if Buffer[Index] = #10 then
            begin
              Inc(InPiece);
              if InPiece = Amount then
              begin
                ClosePiece;
                PieceStream := nil;
              end;
            end;
          end;
        SplitLineBytes:
          begin
            { Whole lines, at most Amount bytes per piece (longer lines
              are split). }
            AppendCharacter(Pending, Buffer[Index]);
            if (Buffer[Index] = #10) or (Pending.Length = Amount) then
            begin
              if (PieceStream = nil) or (InPiece + Pending.Length > Amount) then
              begin
                OpenNextPiece;
                InPiece := 0;
              end;
              WriteBytes(PieceStream, Pending.Text, Pending.Length);
              InPiece := InPiece + Pending.Length;
              Pending.Length := 0;
              Pending.Text[0] := #0;
            end;
          end;
      end;
      Inc(Index);
    end;
  until Count = 0;
  if Pending.Length > 0 then
  begin
    if (PieceStream = nil) or (InPiece + Pending.Length > Amount) then
      OpenNextPiece;
    WriteBytes(PieceStream, Pending.Text, Pending.Length);
  end;
  ClosePiece;
  FreeMemory(Buffer);
end.
