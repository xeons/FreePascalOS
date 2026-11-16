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
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Files,
  Sys.Format,
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
  Prefix: string;
  Suffix: string;
  SuffixLength: Integer;
  SuffixAlphabet: string;
  Verbose: Boolean;
  PieceNumber: QWord;
  PieceHandle: Int64;
  PieceStream: POutputStream;

function PieceName: string;
var
  Digits: string;
  Base: QWord;
  Value: QWord;
  Index: Integer;
begin
  Base := Length(SuffixAlphabet);
  Value := PieceNumber;
  SetLength(Digits, SuffixLength);
  for Index := SuffixLength downto 1 do
  begin
    Digits[Index] := SuffixAlphabet[1 + Value mod Base];
    Value := Value div Base;
  end;
  if Value <> 0 then
    Fail(1, 'output file suffixes exhausted', []);
  Result := Prefix + Digits + Suffix;
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
  Name: string;
begin
  ClosePiece;
  Name := PieceName;
  if Verbose then
    WriteText(StandardOutput, PChar('creating file ''' + Name + ''''#10));
  PieceHandle := OpenFile(PChar(Name), OpenWrite or OpenCreate or OpenTruncate);
  if PieceHandle < 0 then
    FailWithError(1, ErrorCodeOf(PieceHandle), '%s', [ArgumentText(PChar(Name))]);
  PieceStream := CreateOutputStream(PieceHandle);
  Inc(PieceNumber);
end;

{ The bytes of a -C record not written yet. }
var
  Pending: string;
  PendingLength: QWord;

procedure AddPending(Character: Char);
begin
  if PendingLength = QWord(Length(Pending)) then
    SetLength(Pending, Length(Pending) * 2 + 256);
  Inc(PendingLength);
  Pending[PendingLength] := Character;
end;

{ Writes the pending record, into a new piece if it does not fit. }
procedure WritePending(Amount: QWord; var InPiece: QWord);
begin
  if (PieceStream = nil) or (InPiece + PendingLength > Amount) then
  begin
    OpenNextPiece;
    InPiece := 0;
  end;
  WriteBytes(PieceStream, PChar(Pending), PendingLength);
  InPiece := InPiece + PendingLength;
  PendingLength := 0;
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Mode: TSplitMode;
  Amount: QWord;
  Number: Int64;
  Input: Int64;
  Buffer: array of Char;
  Count: Int64;
  Index: Int64;
  InPiece: QWord;
  Information: TFileInformation;
  TotalSize: QWord;
  ChunkSize: QWord;
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
  if (Parser.OperandCount >= 1) and (string(Parser.Operands[0]) <> '-') then
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

  SetLength(Buffer, 65536);
  PieceStream := nil;
  PieceNumber := 0;
  InPiece := 0;
  Pending := '';
  PendingLength := 0;
  repeat
    Count := ReadFile(Input, @Buffer[0], Length(Buffer));
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
            AddPending(Buffer[Index]);
            if (Buffer[Index] = #10) or (PendingLength = Amount) then
              WritePending(Amount, InPiece);
          end;
      end;
      Inc(Index);
    end;
  until Count = 0;
  if PendingLength > 0 then
    WritePending(Amount, InPiece);
  ClosePiece;
end.
