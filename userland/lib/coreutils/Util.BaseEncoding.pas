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

{$mode objfpc}
{$pointermath on}

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
  Util.Options;

const
  Base64Alphabet: PChar = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  Base64UrlAlphabet: PChar = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  Base32Alphabet: PChar = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  Base32HexAlphabet: PChar = '0123456789ABCDEFGHIJKLMNOPQRSTUV';
  Base16Alphabet: PChar = '0123456789ABCDEF';
  Z85Alphabet: PChar = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ.-:+=^!/*?&<>()[]{}@%$#';

  OptionDecode = 1;
  OptionIgnoreGarbage = 2;
  OptionWrap = 3;
  OptionFirstEncoding = 10;

type
  { A bit stream encoder/decoder state shared by the base 64/32/16/2
    encodings: bits collect in Accumulator. }
  TCoder = record
    Encoding: TBaseEncoding;
    Alphabet: PChar;
    BitsPerSymbol: Integer;
    { Bytes per group and symbols per group (for padding). }
    GroupBytes: Integer;
    GroupSymbols: Integer;
    Accumulator: QWord;
    AccumulatedBits: Integer;
    SymbolsInGroup: Integer;
    { Output column, for wrapping. }
    Column: Integer;
    WrapColumn: Integer;
    IgnoreGarbage: Boolean;
    HadError: Boolean;
    Z85Buffer: array[0..4] of Byte;
    Z85Fill: Integer;
  end;

procedure PrepareCoder(out Coder: TCoder; Encoding: TBaseEncoding);
begin
  ZeroMemory(@Coder, SizeOf(Coder));
  Coder.Encoding := Encoding;
  Coder.WrapColumn := 76;
  case Encoding of
    EncodingBase64, EncodingBase64Url:
      begin
        if Encoding = EncodingBase64 then
          Coder.Alphabet := Base64Alphabet
        else
          Coder.Alphabet := Base64UrlAlphabet;
        Coder.BitsPerSymbol := 6;
        Coder.GroupBytes := 3;
        Coder.GroupSymbols := 4;
      end;
    EncodingBase32, EncodingBase32Hex:
      begin
        if Encoding = EncodingBase32 then
          Coder.Alphabet := Base32Alphabet
        else
          Coder.Alphabet := Base32HexAlphabet;
        Coder.BitsPerSymbol := 5;
        Coder.GroupBytes := 5;
        Coder.GroupSymbols := 8;
      end;
    EncodingBase16:
      begin
        Coder.Alphabet := Base16Alphabet;
        Coder.BitsPerSymbol := 4;
        Coder.GroupBytes := 1;
        Coder.GroupSymbols := 2;
      end;
    EncodingZ85:
      Coder.Alphabet := Z85Alphabet;
  else
    begin
      Coder.Alphabet := '01';
      Coder.BitsPerSymbol := 1;
      Coder.GroupBytes := 1;
      Coder.GroupSymbols := 8;
    end;
  end;
end;

procedure EmitSymbol(var Coder: TCoder; Symbol: Char);
begin
  if (Coder.WrapColumn > 0) and (Coder.Column = Coder.WrapColumn) then
  begin
    WriteCharacter(StandardOutput, #10);
    Coder.Column := 0;
  end;
  WriteCharacter(StandardOutput, Symbol);
  Inc(Coder.Column);
end;

{ --- Encoding -------------------------------------------------------- }

procedure EncodeZ85Group(var Coder: TCoder);
var
  Value: QWord;
  Digits: array[0..4] of Char;
  Index: Integer;
begin
  Value := (QWord(Coder.Z85Buffer[0]) shl 24) or (QWord(Coder.Z85Buffer[1]) shl 16) or
    (QWord(Coder.Z85Buffer[2]) shl 8) or Coder.Z85Buffer[3];
  for Index := 4 downto 0 do
  begin
    Digits[Index] := Coder.Alphabet[Value mod 85];
    Value := Value div 85;
  end;
  for Index := 0 to 4 do
    EmitSymbol(Coder, Digits[Index]);
  Coder.Z85Fill := 0;
end;

procedure EncodeByte(var Coder: TCoder; Value: Byte);
var
  Index: Integer;
begin
  case Coder.Encoding of
    EncodingZ85:
      begin
        Coder.Z85Buffer[Coder.Z85Fill] := Value;
        Inc(Coder.Z85Fill);
        if Coder.Z85Fill = 4 then
          EncodeZ85Group(Coder);
      end;
    EncodingBase2LeastSignificantFirst:
      for Index := 0 to 7 do
        EmitSymbol(Coder, Coder.Alphabet[(Value shr Index) and 1]);
  else
    begin
      Coder.Accumulator := (Coder.Accumulator shl 8) or Value;
      Coder.AccumulatedBits := Coder.AccumulatedBits + 8;
      while Coder.AccumulatedBits >= Coder.BitsPerSymbol do
      begin
        Coder.AccumulatedBits := Coder.AccumulatedBits - Coder.BitsPerSymbol;
        EmitSymbol(Coder, Coder.Alphabet[(Coder.Accumulator shr Coder.AccumulatedBits) and
          ((QWord(1) shl Coder.BitsPerSymbol) - 1)]);
        Coder.SymbolsInGroup := (Coder.SymbolsInGroup + 1) mod Coder.GroupSymbols;
      end;
    end;
  end;
end;

procedure FinishEncoding(var Coder: TCoder);
begin
  if Coder.Encoding = EncodingZ85 then
  begin
    if Coder.Z85Fill <> 0 then
    begin
      Report('invalid input (length must be multiple of 4 characters)', []);
      Coder.HadError := True;
    end;
  end
  else if Coder.AccumulatedBits > 0 then
  begin
    { Remaining bits, zero filled, then "=" up to a whole group. }
    EmitSymbol(Coder, Coder.Alphabet[(Coder.Accumulator shl (Coder.BitsPerSymbol - Coder.AccumulatedBits)) and
      ((QWord(1) shl Coder.BitsPerSymbol) - 1)]);
    Coder.SymbolsInGroup := (Coder.SymbolsInGroup + 1) mod Coder.GroupSymbols;
    Coder.AccumulatedBits := 0;
    while Coder.SymbolsInGroup <> 0 do
    begin
      EmitSymbol(Coder, '=');
      Coder.SymbolsInGroup := (Coder.SymbolsInGroup + 1) mod Coder.GroupSymbols;
    end;
  end;
  if Coder.Column > 0 then
    WriteCharacter(StandardOutput, #10);
end;

{ --- Decoding -------------------------------------------------------- }

function SymbolValue(const Coder: TCoder; Symbol: Char): Integer;
var
  Index: Integer;
begin
  Index := 0;
  while Coder.Alphabet[Index] <> #0 do
  begin
    if Coder.Alphabet[Index] = Symbol then
      Exit(Index);
    Inc(Index);
  end;
  { Hexadecimal and base32 also accept lower case. }
  if Coder.Encoding in [EncodingBase16, EncodingBase32, EncodingBase32Hex] then
  begin
    Index := 0;
    while Coder.Alphabet[Index] <> #0 do
    begin
      if Coder.Alphabet[Index] = ToUpperCase(Symbol) then
        Exit(Index);
      Inc(Index);
    end;
  end;
  Result := -1;
end;

procedure DecodeSymbol(var Coder: TCoder; Symbol: Char);
var
  Value: Integer;
  Z85Value: QWord;
  Index: Integer;
begin
  if (Symbol = #10) or (Symbol = #13) then
    Exit;
  if Coder.HadError then
    Exit;
  if Symbol = '=' then
  begin
    { Padding: drop the leftover bits. }
    Coder.AccumulatedBits := 0;
    Exit;
  end;
  Value := SymbolValue(Coder, Symbol);
  if Value < 0 then
  begin
    if Coder.IgnoreGarbage then
      Exit;
    Report('invalid input', []);
    Coder.HadError := True;
    Exit;
  end;

  case Coder.Encoding of
    EncodingZ85:
      begin
        Coder.Z85Buffer[Coder.Z85Fill] := Byte(Value);
        Inc(Coder.Z85Fill);
        if Coder.Z85Fill = 5 then
        begin
          Z85Value := 0;
          for Index := 0 to 4 do
            Z85Value := Z85Value * 85 + Coder.Z85Buffer[Index];
          for Index := 3 downto 0 do
            WriteCharacter(StandardOutput, Char((Z85Value shr (8 * Index)) and $FF));
          Coder.Z85Fill := 0;
        end;
      end;
    EncodingBase2LeastSignificantFirst:
      begin
        Coder.Accumulator := Coder.Accumulator or (QWord(Value) shl Coder.AccumulatedBits);
        Inc(Coder.AccumulatedBits);
        if Coder.AccumulatedBits = 8 then
        begin
          WriteCharacter(StandardOutput, Char(Coder.Accumulator));
          Coder.Accumulator := 0;
          Coder.AccumulatedBits := 0;
        end;
      end;
  else
    begin
      Coder.Accumulator := (Coder.Accumulator shl Coder.BitsPerSymbol) or QWord(Value);
      Coder.AccumulatedBits := Coder.AccumulatedBits + Coder.BitsPerSymbol;
      if Coder.AccumulatedBits >= 8 then
      begin
        Coder.AccumulatedBits := Coder.AccumulatedBits - 8;
        WriteCharacter(StandardOutput, Char((Coder.Accumulator shr Coder.AccumulatedBits) and $FF));
      end;
    end;
  end;
end;

procedure FinishDecoding(var Coder: TCoder);
begin
  if (Coder.Encoding = EncodingZ85) and (Coder.Z85Fill <> 0) and not Coder.HadError then
  begin
    Report('invalid input', []);
    Coder.HadError := True;
  end;
end;

{ --- The program ----------------------------------------------------- }

procedure RunBaseEncodingTool(Default: TBaseEncoding; AllowSelection: Boolean);
var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Decode: Boolean;
  Coder: TCoder;
  Encoding: TBaseEncoding;
  Selected: Boolean;
  Wrap: Int64;
  IgnoreGarbage: Boolean;
  Handle: Int64;
  Buffer: array[0..4095] of Byte;
  Count: Int64;
  Index: Int64;
  Usage: TTextBuilder;
begin
  BeginText(Usage);
  AppendFormatted(Usage, 'Usage: %s [OPTION]... [FILE]'#10 +
    'Encode or decode FILE, or standard input, to standard output.'#10#10, [ArgumentText(ProgramName)]);
  if AllowSelection then
    AppendText(Usage, '      --base64 --base64url --base32 --base32hex --base16'#10 +
      '      --base2msbf --base2lsbf --z85   choose the encoding'#10);
  AppendText(Usage, '  -d, --decode          decode data'#10 +
    '  -i, --ignore-garbage  when decoding, ignore non-alphabet characters'#10 +
    '  -w, --wrap=COLS       wrap encoded lines after COLS character (default 76).'#10 +
    '                          Use 0 to disable line wrapping'#10);

  Decode := False;
  IgnoreGarbage := False;
  Wrap := 76;
  Encoding := Default;
  Selected := not AllowSelection;
  BeginOptions(Parser, [
    OptionDefinition('d', 'decode', False, OptionDecode),
    OptionDefinition('i', 'ignore-garbage', False, OptionIgnoreGarbage),
    OptionDefinition('w', 'wrap', True, OptionWrap),
    OptionDefinition(#0, 'base64', False, OptionFirstEncoding + Ord(EncodingBase64)),
    OptionDefinition(#0, 'base64url', False, OptionFirstEncoding + Ord(EncodingBase64Url)),
    OptionDefinition(#0, 'base32', False, OptionFirstEncoding + Ord(EncodingBase32)),
    OptionDefinition(#0, 'base32hex', False, OptionFirstEncoding + Ord(EncodingBase32Hex)),
    OptionDefinition(#0, 'base16', False, OptionFirstEncoding + Ord(EncodingBase16)),
    OptionDefinition(#0, 'base2msbf', False, OptionFirstEncoding + Ord(EncodingBase2MostSignificantFirst)),
    OptionDefinition(#0, 'base2lsbf', False, OptionFirstEncoding + Ord(EncodingBase2LeastSignificantFirst)),
    OptionDefinition(#0, 'z85', False, OptionFirstEncoding + Ord(EncodingZ85))], Usage.Text);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionDecode: Decode := True;
      OptionIgnoreGarbage: IgnoreGarbage := True;
      OptionWrap:
        if not ParseInteger(Value, Wrap) or (Wrap < 0) then
          Fail(1, 'invalid wrap size: ''%s''', [ArgumentText(Value)]);
    else
      if AllowSelection and (Code >= OptionFirstEncoding) then
      begin
        Encoding := TBaseEncoding(Code - OptionFirstEncoding);
        Selected := True;
      end
      else
        FailWithUsageHint('unrecognized option', []);
    end;
  if not Selected then
    FailWithUsageHint('missing encoding type', []);
  if Parser.OperandCount > 1 then
    FailWithUsageHint('extra operand ''%s''', [ArgumentText(Parser.Operands[1])]);

  Handle := StandardInputHandle;
  if (Parser.OperandCount = 1) and not TextIsEqual(Parser.Operands[0], '-') then
  begin
    Handle := OpenFile(Parser.Operands[0], OpenRead);
    if Handle < 0 then
      FailWithError(1, ErrorCodeOf(Handle), '%s', [ArgumentText(Parser.Operands[0])]);
  end;

  PrepareCoder(Coder, Encoding);
  Coder.WrapColumn := Integer(Wrap);
  Coder.IgnoreGarbage := IgnoreGarbage;
  repeat
    Count := ReadFile(Handle, @Buffer[0], SizeOf(Buffer));
    if Count < 0 then
      FailWithError(1, ErrorCodeOf(Count), 'read error', []);
    Index := 0;
    while Index < Count do
    begin
      if Decode then
        DecodeSymbol(Coder, Char(Buffer[Index]))
      else
        EncodeByte(Coder, Buffer[Index]);
      Inc(Index);
    end;
  until (Count = 0) or Coder.HadError;
  if Decode then
    FinishDecoding(Coder)
  else
    FinishEncoding(Coder);
  DiscardText(Usage);
  if Coder.HadError then
    Halt(1);
  Halt(0);
end;

end.
