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
  Binary to text encodings, and the program behind base64, base32 and
  basenc.

    base64     RFC 4648, "+/" with "=" padding
    base64url  RFC 4648 section 5, "-_"
    base32     RFC 4648, A-Z 2-7
    base32hex  RFC 4648 section 7, 0-9 A-V
    base16     upper case hexadecimal
    base2msbf, base2lsbf   bits as "0"/"1", most or least significant first
    z85        ZeroMQ Z85 (input length must be a multiple of 4)

  The program encodes standard input or a file, wrapping lines at 76
  columns (-w), or decodes it (-d), ignoring line ends and, with -i,
  anything outside the alphabet.
}
unit Util.BaseEncoding;

{$mode objfpc}{$H+}

interface

type
  TBaseEncoding = (EncodingBase64, EncodingBase64Url, EncodingBase32, EncodingBase32Hex,
    EncodingBase16, EncodingBase2MostSignificantFirst, EncodingBase2LeastSignificantFirst,
    EncodingZ85);

{ Runs the program; with AllowSelection (basenc) an encoding option is
  required, otherwise Default is used. }
procedure RunBaseEncodingTool(Default: TBaseEncoding; AllowSelection: Boolean);

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Files,
  Sys.Streams,
  Util.CommandLine,
  Util.Messages,
  Util.Numbers;

const
  Base64Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  Base64UrlAlphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  Base32Alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  Base32HexAlphabet = '0123456789ABCDEFGHIJKLMNOPQRSTUV';
  Base16Alphabet = '0123456789ABCDEF';
  Base2Alphabet = '01';
  Z85Alphabet = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?&<>()[]{}@%$#';

  OptionDecode = 1;
  OptionIgnoreGarbage = 2;
  OptionWrap = 3;
  OptionFirstEncoding = 10;

  DefaultWrapColumn = 76;
  ReadBufferSize = 4096;

type
  { The encoder and decoder of one encoding. The base 64/32/16/2
    encodings collect bits in Accumulator; Z85 works in groups of four
    bytes and five symbols. }
  TBaseCoder = class
  private
    FEncoding: TBaseEncoding;
    FAlphabet: string;
    FBitsPerSymbol: Integer;
    { Symbols per group (for padding). }
    FGroupSymbols: Integer;
    FAccumulator: QWord;
    FAccumulatedBits: Integer;
    FSymbolsInGroup: Integer;
    { Output column, for wrapping. }
    FColumn: Integer;
    FWrapColumn: Integer;
    FIgnoreGarbage: Boolean;
    FHadError: Boolean;
    FZ85Buffer: array[0..4] of Byte;
    FZ85Fill: Integer;
    procedure EmitSymbol(Symbol: Char);
    function AlphabetSymbol(Value: QWord): Char;
    procedure EncodeZ85Group;
    function SymbolValue(Symbol: Char): Integer;
    procedure DecodeZ85Value(Value: Integer);
  public
    constructor Create(Encoding: TBaseEncoding);
    procedure EncodeByte(Value: Byte);
    procedure FinishEncoding;
    procedure DecodeSymbol(Symbol: Char);
    procedure FinishDecoding;
    property WrapColumn: Integer read FWrapColumn write FWrapColumn;
    property IgnoreGarbage: Boolean read FIgnoreGarbage write FIgnoreGarbage;
    property HadError: Boolean read FHadError;
  end;

constructor TBaseCoder.Create(Encoding: TBaseEncoding);
begin
  inherited Create;
  FEncoding := Encoding;
  FWrapColumn := DefaultWrapColumn;
  case Encoding of
    EncodingBase64, EncodingBase64Url:
      begin
        if Encoding = EncodingBase64 then
          FAlphabet := Base64Alphabet
        else
          FAlphabet := Base64UrlAlphabet;
        FBitsPerSymbol := 6;
        FGroupSymbols := 4;
      end;
    EncodingBase32, EncodingBase32Hex:
      begin
        if Encoding = EncodingBase32 then
          FAlphabet := Base32Alphabet
        else
          FAlphabet := Base32HexAlphabet;
        FBitsPerSymbol := 5;
        FGroupSymbols := 8;
      end;
    EncodingBase16:
      begin
        FAlphabet := Base16Alphabet;
        FBitsPerSymbol := 4;
        FGroupSymbols := 2;
      end;
    EncodingZ85:
      FAlphabet := Z85Alphabet;
  else
    begin
      FAlphabet := Base2Alphabet;
      FBitsPerSymbol := 1;
      FGroupSymbols := 8;
    end;
  end;
end;

function TBaseCoder.AlphabetSymbol(Value: QWord): Char;
begin
  Result := FAlphabet[Value + 1];
end;

procedure TBaseCoder.EmitSymbol(Symbol: Char);
begin
  if (FWrapColumn > 0) and (FColumn = FWrapColumn) then
  begin
    WriteCharacter(StandardOutput, #10);
    FColumn := 0;
  end;
  WriteCharacter(StandardOutput, Symbol);
  Inc(FColumn);
end;

{ --- Encoding -------------------------------------------------------- }

procedure TBaseCoder.EncodeZ85Group;
var
  Value: QWord;
  Digits: string[5];
  Index: Integer;
begin
  Value := (QWord(FZ85Buffer[0]) shl 24) or (QWord(FZ85Buffer[1]) shl 16) or
    (QWord(FZ85Buffer[2]) shl 8) or FZ85Buffer[3];
  Digits := '';
  for Index := 1 to 5 do
  begin
    Digits := AlphabetSymbol(Value mod 85) + Digits;
    Value := Value div 85;
  end;
  for Index := 1 to 5 do
    EmitSymbol(Digits[Index]);
  FZ85Fill := 0;
end;

procedure TBaseCoder.EncodeByte(Value: Byte);
var
  Index: Integer;
begin
  case FEncoding of
    EncodingZ85:
      begin
        FZ85Buffer[FZ85Fill] := Value;
        Inc(FZ85Fill);
        if FZ85Fill = 4 then
          EncodeZ85Group;
      end;
    EncodingBase2LeastSignificantFirst:
      for Index := 0 to 7 do
        EmitSymbol(AlphabetSymbol((Value shr Index) and 1));
  else
    begin
      FAccumulator := (FAccumulator shl 8) or Value;
      FAccumulatedBits := FAccumulatedBits + 8;
      while FAccumulatedBits >= FBitsPerSymbol do
      begin
        FAccumulatedBits := FAccumulatedBits - FBitsPerSymbol;
        EmitSymbol(AlphabetSymbol((FAccumulator shr FAccumulatedBits) and
          ((QWord(1) shl FBitsPerSymbol) - 1)));
        FSymbolsInGroup := (FSymbolsInGroup + 1) mod FGroupSymbols;
      end;
    end;
  end;
end;

procedure TBaseCoder.FinishEncoding;
begin
  if FEncoding = EncodingZ85 then
  begin
    if FZ85Fill <> 0 then
    begin
      Report('invalid input (length must be multiple of 4 characters)');
      FHadError := True;
    end;
  end
  else if FAccumulatedBits > 0 then
  begin
    { Remaining bits, zero filled, then "=" up to a whole group. }
    EmitSymbol(AlphabetSymbol((FAccumulator shl (FBitsPerSymbol - FAccumulatedBits)) and
      ((QWord(1) shl FBitsPerSymbol) - 1)));
    FSymbolsInGroup := (FSymbolsInGroup + 1) mod FGroupSymbols;
    FAccumulatedBits := 0;
    while FSymbolsInGroup <> 0 do
    begin
      EmitSymbol('=');
      FSymbolsInGroup := (FSymbolsInGroup + 1) mod FGroupSymbols;
    end;
  end;
  if FColumn > 0 then
    WriteCharacter(StandardOutput, #10);
end;

{ --- Decoding -------------------------------------------------------- }

function TBaseCoder.SymbolValue(Symbol: Char): Integer;
begin
  Result := Pos(Symbol, FAlphabet) - 1;
  { Hexadecimal and base32 also accept lower case. }
  if (Result < 0) and (FEncoding in [EncodingBase16, EncodingBase32, EncodingBase32Hex]) then
    Result := Pos(UpCase(Symbol), FAlphabet) - 1;
end;

procedure TBaseCoder.DecodeZ85Value(Value: Integer);
var
  Z85Value: QWord;
  Index: Integer;
begin
  FZ85Buffer[FZ85Fill] := Byte(Value);
  Inc(FZ85Fill);
  if FZ85Fill < 5 then
    Exit;
  Z85Value := 0;
  for Index := 0 to 4 do
    Z85Value := Z85Value * 85 + FZ85Buffer[Index];
  for Index := 3 downto 0 do
    WriteCharacter(StandardOutput, Char((Z85Value shr (8 * Index)) and $FF));
  FZ85Fill := 0;
end;

procedure TBaseCoder.DecodeSymbol(Symbol: Char);
var
  Value: Integer;
begin
  if (Symbol = #10) or (Symbol = #13) then
    Exit;
  if FHadError then
    Exit;
  if Symbol = '=' then
  begin
    { Padding: drop the leftover bits. }
    FAccumulatedBits := 0;
    Exit;
  end;
  Value := SymbolValue(Symbol);
  if Value < 0 then
  begin
    if FIgnoreGarbage then
      Exit;
    Report('invalid input');
    FHadError := True;
    Exit;
  end;

  case FEncoding of
    EncodingZ85:
      DecodeZ85Value(Value);
    EncodingBase2LeastSignificantFirst:
      begin
        FAccumulator := FAccumulator or (QWord(Value) shl FAccumulatedBits);
        Inc(FAccumulatedBits);
        if FAccumulatedBits = 8 then
        begin
          WriteCharacter(StandardOutput, Char(FAccumulator));
          FAccumulator := 0;
          FAccumulatedBits := 0;
        end;
      end;
  else
    begin
      FAccumulator := (FAccumulator shl FBitsPerSymbol) or QWord(Value);
      FAccumulatedBits := FAccumulatedBits + FBitsPerSymbol;
      if FAccumulatedBits >= 8 then
      begin
        FAccumulatedBits := FAccumulatedBits - 8;
        WriteCharacter(StandardOutput, Char((FAccumulator shr FAccumulatedBits) and $FF));
      end;
    end;
  end;
end;

procedure TBaseCoder.FinishDecoding;
begin
  if (FEncoding = EncodingZ85) and (FZ85Fill <> 0) and not FHadError then
  begin
    Report('invalid input');
    FHadError := True;
  end;
end;

{ --- The program ----------------------------------------------------- }

function UsageText(AllowSelection: Boolean): string;
begin
  Result := Format('Usage: %s [OPTION]... [FILE]'#10 +
    'Encode or decode FILE, or standard input, to standard output.'#10#10, [ProgramName]);
  if AllowSelection then
    Result := Result + '      --base64 --base64url --base32 --base32hex --base16'#10 +
      '      --base2msbf --base2lsbf --z85   choose the encoding'#10;
  Result := Result + '  -d, --decode          decode data'#10 +
    '  -i, --ignore-garbage  when decoding, ignore non-alphabet characters'#10 +
    '  -w, --wrap=COLS       wrap encoded lines after COLS character (default 76).'#10 +
    '                          Use 0 to disable line wrapping'#10;
end;

{ Feeds Handle through Coder, encoding or decoding, until its end or an
  error. }
procedure CodeInput(Coder: TBaseCoder; Handle: Int64; Decode: Boolean);
var
  Buffer: array[0..ReadBufferSize - 1] of Byte;
  Count: Int64;
  Index: Int64;
begin
  repeat
    Count := ReadFile(Handle, @Buffer[0], SizeOf(Buffer));
    if Count < 0 then
      FailWithError(1, ErrorCodeOf(Count), 'read error');
    Index := 0;
    while Index < Count do
    begin
      if Decode then
        Coder.DecodeSymbol(Char(Buffer[Index]))
      else
        Coder.EncodeByte(Buffer[Index]);
      Inc(Index);
    end;
  until (Count = 0) or Coder.HadError;
  if Decode then
    Coder.FinishDecoding
  else
    Coder.FinishEncoding;
end;

procedure RunBaseEncodingTool(Default: TBaseEncoding; AllowSelection: Boolean);
var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Decode: Boolean;
  Coder: TBaseCoder;
  Encoding: TBaseEncoding;
  Selected: Boolean;
  Wrap: Int64;
  IgnoreGarbage: Boolean;
  Handle: Int64;
begin
  Decode := False;
  IgnoreGarbage := False;
  Wrap := DefaultWrapColumn;
  Encoding := Default;
  Selected := not AllowSelection;
  CommandLine := TCommandLine.Create([
    CommandOption('d', 'decode', False, OptionDecode),
    CommandOption('i', 'ignore-garbage', False, OptionIgnoreGarbage),
    CommandOption('w', 'wrap', True, OptionWrap),
    CommandOption(#0, 'base64', False, OptionFirstEncoding + Ord(EncodingBase64)),
    CommandOption(#0, 'base64url', False, OptionFirstEncoding + Ord(EncodingBase64Url)),
    CommandOption(#0, 'base32', False, OptionFirstEncoding + Ord(EncodingBase32)),
    CommandOption(#0, 'base32hex', False, OptionFirstEncoding + Ord(EncodingBase32Hex)),
    CommandOption(#0, 'base16', False, OptionFirstEncoding + Ord(EncodingBase16)),
    CommandOption(#0, 'base2msbf', False, OptionFirstEncoding + Ord(EncodingBase2MostSignificantFirst)),
    CommandOption(#0, 'base2lsbf', False, OptionFirstEncoding + Ord(EncodingBase2LeastSignificantFirst)),
    CommandOption(#0, 'z85', False, OptionFirstEncoding + Ord(EncodingZ85))], UsageText(AllowSelection));
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionDecode: Decode := True;
      OptionIgnoreGarbage: IgnoreGarbage := True;
      OptionWrap:
        if not ParseDecimal(Value, Wrap) or (Wrap < 0) then
          Fail(1, Format('invalid wrap size: ''%s''', [Value]));
    else
      if AllowSelection and (Code >= OptionFirstEncoding) then
      begin
        Encoding := TBaseEncoding(Code - OptionFirstEncoding);
        Selected := True;
      end
      else
        FailWithUsageHint('unrecognized option');
    end;
  if not Selected then
    FailWithUsageHint('missing encoding type');
  if CommandLine.OperandCount > 1 then
    FailWithUsageHint(Format('extra operand ''%s''', [CommandLine.Operands[1]]));

  Handle := StandardInputHandle;
  if (CommandLine.OperandCount = 1) and (CommandLine.Operands[0] <> '-') then
  begin
    Handle := OpenFile(PChar(CommandLine.Operands[0]), OpenRead);
    if Handle < 0 then
      FailWithError(1, ErrorCodeOf(Handle), CommandLine.Operands[0]);
  end;

  Coder := TBaseCoder.Create(Encoding);
  Coder.WrapColumn := Integer(Wrap);
  Coder.IgnoreGarbage := IgnoreGarbage;
  CodeInput(Coder, Handle, Decode);
  if Coder.HadError then
    Halt(1);
  Halt(0);
end;

end.
