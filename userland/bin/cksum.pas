{
  cksum - compute checksums of files

  cksum [-a ALGORITHM] [--tag] [FILE]...

  Without -a prints the POSIX CRC, the byte count and the name. With
  -a crc32b (the CRC of zip and gzip), md5, sha1, sha224, sha256,
  sha384, sha512, blake2b, bsd or sysv selects another algorithm; the
  digests are printed in the tagged form "ALGORITHM (NAME) = DIGEST".
}
program cksum;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Text,
  Crypto.Checksums,
  Crypto.Digests,
  Sys.Errors,
  Sys.Files,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Util.DigestTool,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: cksum [OPTION]... [FILE]...'#10 +
    'Print CRC checksum and byte counts of each FILE.'#10#10 +
    '  -a, --algorithm=TYPE  select the digest type to use:'#10 +
    '                          crc (default), crc32b, sysv, bsd, md5, sha1,'#10 +
    '                          sha224, sha256, sha384, sha512, blake2b'#10 +
    '      --untagged        create a reversed style checksum, without digest type'#10;

  OptionAlgorithm = 1;
  OptionUntagged = 2;

type
  TChecksumKind = (ChecksumPosixCrc, ChecksumCrc32, ChecksumSystemV, ChecksumBsd, ChecksumDigest);

var
  Kind: TChecksumKind;
  Algorithm: TDigestAlgorithm;
  Untagged: Boolean;

procedure SelectAlgorithm(Name: PChar);
begin
  Kind := ChecksumDigest;
  if TextIsEqual(Name, 'crc') then
    Kind := ChecksumPosixCrc
  else if TextIsEqual(Name, 'crc32b') then
    Kind := ChecksumCrc32
  else if TextIsEqual(Name, 'sysv') then
    Kind := ChecksumSystemV
  else if TextIsEqual(Name, 'bsd') then
    Kind := ChecksumBsd
  else if TextIsEqual(Name, 'md5') then
    Algorithm := DigestMd5
  else if TextIsEqual(Name, 'sha1') then
    Algorithm := DigestSha1
  else if TextIsEqual(Name, 'sha224') then
    Algorithm := DigestSha224
  else if TextIsEqual(Name, 'sha256') then
    Algorithm := DigestSha256
  else if TextIsEqual(Name, 'sha384') then
    Algorithm := DigestSha384
  else if TextIsEqual(Name, 'sha512') then
    Algorithm := DigestSha512
  else if TextIsEqual(Name, 'blake2b') then
    Algorithm := DigestBlake2b
  else
    FailWithUsageHint('invalid argument ''%s'' for ''--algorithm''', [ArgumentText(Name)]);
end;

{ Feeds a file through the selected checksum; False on error. }
function ChecksumFile(Path: PChar; out Value: QWord; out ByteCount: QWord): Boolean;
var
  Handle: Int64;
  Buffer: PByte;
  Count: Int64;
  Crc: LongWord;
  BsdSum: Word;
  SystemVSum: QWord;
begin
  Value := 0;
  ByteCount := 0;
  if TextIsEqual(Path, '-') then
    Handle := StandardInputHandle
  else
  begin
    Handle := OpenFile(Path, OpenRead);
    if Handle < 0 then
    begin
      ReportError(ErrorCodeOf(Handle), '%s', [ArgumentText(Path)]);
      Exit(False);
    end;
  end;
  if Kind = ChecksumCrc32 then
    Crc := Crc32Initial
  else
    Crc := Crc32PosixInitial;
  BsdSum := 0;
  SystemVSum := 0;
  Buffer := PByte(AllocateMemory(65536));
  Result := True;
  repeat
    Count := ReadFile(Handle, Buffer, 65536);
    if Count < 0 then
    begin
      ReportError(ErrorCodeOf(Count), '%s', [ArgumentText(Path)]);
      Result := False;
      Break;
    end;
    case Kind of
      ChecksumPosixCrc: Crc := Crc32PosixUpdate(Crc, Buffer, QWord(Count));
      ChecksumCrc32: Crc := Crc32Update(Crc, Buffer, QWord(Count));
      ChecksumSystemV: SystemVSum := SystemVSumUpdate(SystemVSum, Buffer, QWord(Count));
      ChecksumBsd: BsdSum := BsdSumUpdate(BsdSum, Buffer, QWord(Count));
    end;
    ByteCount := ByteCount + QWord(Count);
  until Count = 0;
  FreeMemory(Buffer);
  if Handle <> StandardInputHandle then
    CloseFile(Handle);
  case Kind of
    ChecksumPosixCrc: Value := Crc32PosixFinish(Crc, ByteCount);
    ChecksumCrc32: Value := Crc32Finish(Crc);
    ChecksumSystemV: Value := SystemVSumFinish(SystemVSum);
    ChecksumBsd: Value := BsdSum;
  end;
end;

procedure PrintDigest(Path: PChar; var ExitStatus: LongInt);
var
  Output: TDigestOutput;
  Hex: array[0..2 * MaximumDigestSize] of Char;
begin
  if not DigestFile(Algorithm, Path, Output) then
  begin
    ExitStatus := 1;
    Exit;
  end;
  FormatHexBytes(@Output[0], DigestSize(Algorithm), @Hex[0]);
  if Untagged then
    WriteFormatted(StandardOutput, '%s  %s'#10, [ArgumentText(@Hex[0]), ArgumentText(Path)])
  else
    WriteFormatted(StandardOutput, '%s (%s) = %s'#10, [ArgumentText(DigestTagName(Algorithm)),
      ArgumentText(Path), ArgumentText(@Hex[0])]);
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Index: Integer;
  Checksum: QWord;
  ByteCount: QWord;
  Name: PChar;
  ExitStatus: LongInt;
  IsStandardInput: Boolean;
begin
  Kind := ChecksumPosixCrc;
  Untagged := False;
  BeginOptions(Parser, [
    OptionDefinition('a', 'algorithm', True, OptionAlgorithm),
    OptionDefinition(#0, 'untagged', False, OptionUntagged)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionAlgorithm: SelectAlgorithm(Value);
      OptionUntagged: Untagged := True;
    end;
  IsStandardInput := Parser.OperandCount = 0;
  if IsStandardInput then
  begin
    Parser.Operands[0] := '-';
    Parser.OperandCount := 1;
  end;

  ExitStatus := 0;
  for Index := 0 to Parser.OperandCount - 1 do
  begin
    Name := Parser.Operands[Index];
    if Kind = ChecksumDigest then
    begin
      PrintDigest(Name, ExitStatus);
      Continue;
    end;
    if not ChecksumFile(Name, Checksum, ByteCount) then
    begin
      ExitStatus := 1;
      Continue;
    end;
    case Kind of
      ChecksumSystemV:
        WriteFormatted(StandardOutput, '%u %u', [ArgumentUnsigned(Checksum),
          ArgumentUnsigned((ByteCount + 511) div 512)]);
      ChecksumBsd:
        WriteFormatted(StandardOutput, '%05u %5u', [ArgumentUnsigned(Checksum),
          ArgumentUnsigned((ByteCount + 1023) div 1024)]);
    else
      WriteFormatted(StandardOutput, '%u %u', [ArgumentUnsigned(Checksum), ArgumentUnsigned(ByteCount)]);
    end;
    if not IsStandardInput then
      WriteFormatted(StandardOutput, ' %s', [ArgumentText(Name)]);
    WriteCharacter(StandardOutput, #10);
  end;
  Halt(ExitStatus);
end.
