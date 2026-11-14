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
  The common program behind md5sum, sha1sum, sha224sum, sha256sum,
  sha384sum, sha512sum and b2sum.

    PROGRAM [-bt] [--tag] [-z] [FILE]...         print digests
    PROGRAM -c [--quiet] [--status] [-w] [FILE]...  check digests

  Output lines are "DIGEST  NAME" ("DIGEST *NAME" with -b), or with
  --tag "ALGORITHM (NAME) = DIGEST". Check mode reads either form.
}
unit Util.DigestTool;

{$mode objfpc}
{$pointermath on}

interface

uses
  Crypto.Digests;

procedure RunDigestTool(Algorithm: TDigestAlgorithm);

{ Digest of a whole file ('-' for standard input); False on error
  (already reported). }
function DigestFile(Algorithm: TDigestAlgorithm; Path: PChar; out Output: TDigestOutput): Boolean;

implementation

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Errors,
  Sys.Files,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
  Util.Input,
  Util.Messages,
  Util.Options;

const
  OptionBinary = 1;
  OptionText = 2;
  OptionTag = 3;
  OptionZero = 4;
  OptionCheck = 5;
  OptionQuiet = 6;
  OptionStatus = 7;
  OptionWarn = 8;
  OptionStrict = 9;
  OptionIgnoreMissing = 10;

  HexDigits: array[0..15] of Char = '0123456789abcdef';

var
  Algorithm: TDigestAlgorithm;

function DigestFile(Algorithm: TDigestAlgorithm; Path: PChar; out Output: TDigestOutput): Boolean;
var
  Handle: Int64;
  Context: TDigestContext;
  Buffer: PByte;
  Count: Int64;
  Information: TFileInformation;
begin
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
    if (GetHandleInformation(Handle, Information) = ErrorNone) and (Information.Kind = KindDirectory) then
    begin
      ReportError(ErrorIsDirectory, '%s', [ArgumentText(Path)]);
      CloseFile(Handle);
      Exit(False);
    end;
  end;

  Buffer := PByte(AllocateMemory(65536));
  BeginDigest(Context, Algorithm);
  Result := True;
  repeat
    Count := ReadFile(Handle, Buffer, 65536);
    if Count < 0 then
    begin
      ReportError(ErrorCodeOf(Count), '%s', [ArgumentText(Path)]);
      Result := False;
      Break;
    end;
    UpdateDigest(Context, Buffer, QWord(Count));
  until Count = 0;
  FinishDigest(Context, Output);
  FreeMemory(Buffer);
  if Handle <> StandardInputHandle then
    CloseFile(Handle);
end;

procedure WriteHex(const Output: TDigestOutput);
var
  Index: Integer;
begin
  for Index := 0 to DigestSize(Algorithm) - 1 do
  begin
    WriteCharacter(StandardOutput, HexDigits[Output[Index] shr 4]);
    WriteCharacter(StandardOutput, HexDigits[Output[Index] and 15]);
  end;
end;

function HexEquals(const Output: TDigestOutput; Text: PChar): Boolean;
var
  Index: Integer;
begin
  if Integer(TextLength(Text)) <> 2 * DigestSize(Algorithm) then
    Exit(False);
  for Index := 0 to DigestSize(Algorithm) - 1 do
  begin
    if (ToLowerCase(Text[2 * Index]) <> HexDigits[Output[Index] shr 4]) or
       (ToLowerCase(Text[2 * Index + 1]) <> HexDigits[Output[Index] and 15]) then
      Exit(False);
  end;
  Result := True;
end;

{ Splits a check line into digest and file name; False if malformed. }
function ParseCheckLine(Line: PChar; out Digest, Name: PChar): Boolean;
var
  TagPrefix: TTextBuilder;
  Close: PtrInt;
begin
  Digest := nil;
  Name := nil;
  BeginText(TagPrefix);
  AppendText(TagPrefix, DigestTagName(Algorithm));
  AppendText(TagPrefix, ' (');
  if TextStartsWith(Line, TagPrefix.Text) then
  begin
    { ALGORITHM (NAME) = DIGEST }
    Name := Line + TagPrefix.Length;
    Close := FindText(Name, ') = ');
    DiscardText(TagPrefix);
    if Close < 0 then
      Exit(False);
    Name[Close] := #0;
    Digest := Name + Close + 4;
    Exit(True);
  end;
  DiscardText(TagPrefix);
  { DIGEST  NAME or DIGEST *NAME }
  Close := FindCharacter(Line, ' ');
  if (Close <= 0) or ((Line[Close + 1] <> ' ') and (Line[Close + 1] <> '*')) then
    Exit(False);
  Line[Close] := #0;
  Digest := Line;
  Name := Line + Close + 2;
  Result := Name^ <> #0;
end;

function PluralSuffix(Count: Integer): PChar;
begin
  if Count = 1 then
    Result := ''
  else
    Result := 's';
end;

var
  Quiet: Boolean;
  StatusOnly: Boolean;
  Warn: Boolean;
  Strict: Boolean;
  IgnoreMissing: Boolean;

{ Returns False if any check failed. }
function CheckList(ListPath: PChar): Boolean;
var
  Stream: PInputStream;
  Line: PChar;
  HadLineEnd: Boolean;
  Digest: PChar;
  Name: PChar;
  Output: TDigestOutput;
  LineNumber: Integer;
  Malformed: Integer;
  Mismatched: Integer;
  Unreadable: Integer;
  Checked: Integer;
begin
  Stream := OpenInput(ListPath);
  if Stream = nil then
    Exit(False);
  LineNumber := 0;
  Malformed := 0;
  Mismatched := 0;
  Unreadable := 0;
  Checked := 0;
  while ReadLine(Stream, Line, HadLineEnd) do
  begin
    Inc(LineNumber);
    if not ParseCheckLine(Line, Digest, Name) then
    begin
      Inc(Malformed);
      if Warn then
        Report('%s: %d: improperly formatted %s checksum line', [ArgumentText(ListPath),
          ArgumentNumber(LineNumber), ArgumentText(DigestTagName(Algorithm))]);
      FreeMemory(Line);
      Continue;
    end;
    if IgnoreMissing and not PathExists(Name) then
    begin
      FreeMemory(Line);
      Continue;
    end;
    Inc(Checked);
    if not DigestFile(Algorithm, Name, Output) then
    begin
      Inc(Unreadable);
      if not StatusOnly then
        WriteFormatted(StandardOutput, '%s: FAILED open or read'#10, [ArgumentText(Name)]);
    end
    else if HexEquals(Output, Digest) then
    begin
      if not Quiet and not StatusOnly then
        WriteFormatted(StandardOutput, '%s: OK'#10, [ArgumentText(Name)]);
    end
    else
    begin
      Inc(Mismatched);
      if not StatusOnly then
        WriteFormatted(StandardOutput, '%s: FAILED'#10, [ArgumentText(Name)]);
    end;
    FreeMemory(Line);
  end;
  CloseInput(Stream);

  if not StatusOnly then
  begin
    if Malformed > 0 then
      Report('WARNING: %d line%s improperly formatted', [ArgumentNumber(Malformed),
        ArgumentText(PluralSuffix(Malformed))]);
    if Unreadable > 0 then
      Report('WARNING: %d listed file%s could not be read', [ArgumentNumber(Unreadable),
        ArgumentText(PluralSuffix(Unreadable))]);
    if Mismatched > 0 then
      Report('WARNING: %d computed checksum%s did NOT match', [ArgumentNumber(Mismatched),
        ArgumentText(PluralSuffix(Mismatched))]);
  end;
  if (Checked = 0) and (Malformed > 0) then
  begin
    Report('%s: no properly formatted checksum lines found', [ArgumentText(ListPath)]);
    Exit(False);
  end;
  Result := (Mismatched = 0) and (Unreadable = 0) and not (Strict and (Malformed > 0));
end;

procedure RunDigestTool(Algorithm: TDigestAlgorithm);
var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Binary: Boolean;
  Tagged: Boolean;
  LineEnd: Char;
  Check: Boolean;
  Index: Integer;
  Output: TDigestOutput;
  ExitStatus: LongInt;
  Usage: TTextBuilder;
begin
  Util.DigestTool.Algorithm := Algorithm;
  BeginText(Usage);
  AppendFormatted(Usage, 'Usage: %s [OPTION]... [FILE]...'#10 +
    'Print or check %s checksums.'#10 +
    'With no FILE, or when FILE is -, read standard input.'#10#10 +
    '  -b, --binary          read in binary mode (marks names with *)'#10 +
    '  -c, --check           read checksums from the FILEs and check them'#10 +
    '      --tag             create a BSD-style checksum'#10 +
    '  -t, --text            read in text mode (default)'#10 +
    '  -z, --zero            end each output line with NUL, not newline'#10 +
    #10'The following options are useful only when verifying checksums:'#10 +
    '      --ignore-missing  don''t fail or report status for missing files'#10 +
    '      --quiet           don''t print OK for each successfully verified file'#10 +
    '      --status          don''t output anything, status code shows success'#10 +
    '      --strict          exit non-zero for improperly formatted checksum lines'#10 +
    '  -w, --warn            warn about improperly formatted checksum lines'#10,
    [ArgumentText(ProgramName), ArgumentText(DigestTagName(Algorithm))]);

  Binary := False;
  Tagged := False;
  LineEnd := #10;
  Check := False;
  BeginOptions(Parser, [
    OptionDefinition('b', 'binary', False, OptionBinary),
    OptionDefinition('t', 'text', False, OptionText),
    OptionDefinition(#0, 'tag', False, OptionTag),
    OptionDefinition('z', 'zero', False, OptionZero),
    OptionDefinition('c', 'check', False, OptionCheck),
    OptionDefinition(#0, 'quiet', False, OptionQuiet),
    OptionDefinition(#0, 'status', False, OptionStatus),
    OptionDefinition('w', 'warn', False, OptionWarn),
    OptionDefinition(#0, 'strict', False, OptionStrict),
    OptionDefinition(#0, 'ignore-missing', False, OptionIgnoreMissing)], Usage.Text);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionBinary: Binary := True;
      OptionText: Binary := False;
      OptionTag: Tagged := True;
      OptionZero: LineEnd := #0;
      OptionCheck: Check := True;
      OptionQuiet: Quiet := True;
      OptionStatus: StatusOnly := True;
      OptionWarn: Warn := True;
      OptionStrict: Strict := True;
      OptionIgnoreMissing: IgnoreMissing := True;
    end;
  if Parser.OperandCount = 0 then
  begin
    Parser.Operands[0] := '-';
    Parser.OperandCount := 1;
  end;

  ExitStatus := 0;
  for Index := 0 to Parser.OperandCount - 1 do
  begin
    if Check then
    begin
      if not CheckList(Parser.Operands[Index]) then
        ExitStatus := 1;
      Continue;
    end;
    if not DigestFile(Algorithm, Parser.Operands[Index], Output) then
    begin
      ExitStatus := 1;
      Continue;
    end;
    if Tagged then
    begin
      WriteFormatted(StandardOutput, '%s (%s) = ', [ArgumentText(DigestTagName(Algorithm)),
        ArgumentText(Parser.Operands[Index])]);
      WriteHex(Output);
    end
    else
    begin
      WriteHex(Output);
      if Binary then
        WriteText(StandardOutput, ' *')
      else
        WriteText(StandardOutput, '  ');
      WriteText(StandardOutput, Parser.Operands[Index]);
    end;
    WriteCharacter(StandardOutput, LineEnd);
  end;
  DiscardText(Usage);
  Halt(ExitStatus);
end;

end.
