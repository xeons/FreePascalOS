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
  cksum - compute checksums of files

  cksum [-a ALGORITHM] [--tag] [FILE]...

  Without -a prints the POSIX CRC, the byte count and the name. With
  -a crc32b (the CRC of zip and gzip), md5, sha1, sha224, sha256,
  sha384, sha512, blake2b, bsd or sysv selects another algorithm; the
  digests are printed in the tagged form "ALGORITHM (NAME) = DIGEST".
}
program cksum;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Crypto.Checksums,
  Crypto.Digests,
  Sys.Errors,
  Sys.Files,
  Util.CommandLine,
  Util.DigestTool,
  Util.Messages,
  Util.Output;

const
  Usage = 'Usage: cksum [OPTION]... [FILE]...'#10 +
    'Print CRC checksum and byte counts of each FILE.'#10#10 +
    '  -a, --algorithm=TYPE  select the digest type to use:'#10 +
    '                          crc (default), crc32b, sysv, bsd, md5, sha1,'#10 +
    '                          sha224, sha256, sha384, sha512, blake2b'#10 +
    '      --untagged        create a reversed style checksum, without digest type'#10;

  OptionAlgorithm = 1;
  OptionUntagged = 2;

  ReadSize = 65536;

type
  TChecksumKind = (ChecksumPosixCrc, ChecksumCrc32, ChecksumSystemV, ChecksumBsd, ChecksumDigest);

var
  Kind: TChecksumKind;
  Algorithm: TDigestAlgorithm;
  Untagged: Boolean;

procedure SelectAlgorithm(const Name: string);
begin
  Kind := ChecksumDigest;
  case Name of
    'crc': Kind := ChecksumPosixCrc;
    'crc32b': Kind := ChecksumCrc32;
    'sysv': Kind := ChecksumSystemV;
    'bsd': Kind := ChecksumBsd;
    'md5': Algorithm := DigestMd5;
    'sha1': Algorithm := DigestSha1;
    'sha224': Algorithm := DigestSha224;
    'sha256': Algorithm := DigestSha256;
    'sha384': Algorithm := DigestSha384;
    'sha512': Algorithm := DigestSha512;
    'blake2b': Algorithm := DigestBlake2b;
  else
    FailWithUsageHint(Format('invalid argument ''%s'' for ''--algorithm''', [Name]));
  end;
end;

{ Feeds a file through the selected checksum; False on error. }
function ChecksumFile(const Path: string; out Value: QWord; out ByteCount: QWord): Boolean;
var
  Handle: Int64;
  Buffer: array of Byte;
  Count: Int64;
  Crc: LongWord;
  BsdSum: Word;
  SystemVSum: QWord;
begin
  Value := 0;
  ByteCount := 0;
  if Path = '-' then
    Handle := StandardInputHandle
  else
  begin
    Handle := OpenFile(PChar(Path), OpenRead);
    if Handle < 0 then
    begin
      ReportError(ErrorCodeOf(Handle), Path);
      Exit(False);
    end;
  end;
  if Kind = ChecksumCrc32 then
    Crc := Crc32Initial
  else
    Crc := Crc32PosixInitial;
  BsdSum := 0;
  SystemVSum := 0;
  Buffer := nil;
  SetLength(Buffer, ReadSize);
  Result := True;
  repeat
    Count := ReadFile(Handle, @Buffer[0], ReadSize);
    if Count < 0 then
    begin
      ReportError(ErrorCodeOf(Count), Path);
      Result := False;
      Break;
    end;
    case Kind of
      ChecksumPosixCrc: Crc := Crc32PosixUpdate(Crc, @Buffer[0], QWord(Count));
      ChecksumCrc32: Crc := Crc32Update(Crc, @Buffer[0], QWord(Count));
      ChecksumSystemV: SystemVSum := SystemVSumUpdate(SystemVSum, @Buffer[0], QWord(Count));
      ChecksumBsd: BsdSum := BsdSumUpdate(BsdSum, @Buffer[0], QWord(Count));
    end;
    ByteCount := ByteCount + QWord(Count);
  until Count = 0;
  if Handle <> StandardInputHandle then
    CloseFile(Handle);
  case Kind of
    ChecksumPosixCrc: Value := Crc32PosixFinish(Crc, ByteCount);
    ChecksumCrc32: Value := Crc32Finish(Crc);
    ChecksumSystemV: Value := SystemVSumFinish(SystemVSum);
    ChecksumBsd: Value := BsdSum;
  end;
end;

{ Bytes as lower case hexadecimal digits. }
function HexText(const Bytes: array of Byte; Count: Integer): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 0 to Count - 1 do
    Result := Result + LowerCase(IntToHex(Bytes[Index], 2));
end;

procedure PrintDigest(const Path: string; var ExitStatus: LongInt);
var
  Output: TDigestOutput;
  Hex: string;
begin
  if not DigestFile(Algorithm, PChar(Path), Output) then
  begin
    ExitStatus := 1;
    Exit;
  end;
  Hex := HexText(Output, DigestSize(Algorithm));
  if Untagged then
    PrintString(Hex + '  ' + Path + #10)
  else
    PrintString(Format('%s (%s) = %s'#10, [string(DigestTagName(Algorithm)), Path, Hex]));
end;

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Checksum: QWord;
  ByteCount: QWord;
  Name: string;
  ExitStatus: LongInt;
  IsStandardInput: Boolean;
begin
  Kind := ChecksumPosixCrc;
  Untagged := False;
  CommandLine := TCommandLine.Create([
    CommandOption('a', 'algorithm', True, OptionAlgorithm),
    CommandOption(#0, 'untagged', False, OptionUntagged)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionAlgorithm: SelectAlgorithm(Value);
      OptionUntagged: Untagged := True;
    end;
  IsStandardInput := CommandLine.OperandCount = 0;
  if IsStandardInput then
    CommandLine.Operands := ['-'];

  ExitStatus := 0;
  for Name in CommandLine.Operands do
  begin
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
        PrintString(Format('%u %u', [Checksum, (ByteCount + 511) div 512]));
      ChecksumBsd:
        PrintString(Format('%.5u %5u', [Checksum, (ByteCount + 1023) div 1024]));
    else
      PrintString(Format('%u %u', [Checksum, ByteCount]));
    end;
    if not IsStandardInput then
      PrintString(' ' + Name);
    PrintString(#10);
  end;
  Halt(ExitStatus);
end.
