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

{$mode objfpc}{$H+}

interface

uses
  Crypto.Digests;

procedure RunDigestTool(Algorithm: TDigestAlgorithm);

{ Digest of a whole file ('-' for standard input); False on error
  (already reported). }
function DigestFile(Algorithm: TDigestAlgorithm; const Path: string; out Output: TDigestOutput): Boolean;

implementation

uses
  SysUtils,
  StrUtils,
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Files,
  Sys.Streams,
  Util.CommandLine,
  Util.Input,
  Util.Messages,
  Util.Output;

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

  ReadBufferSize = 65536;

type
  { What -c reads and how much of it it says. }
  TDigestChecker = class
  private
    FAlgorithm: TDigestAlgorithm;
    FQuiet: Boolean;
    FStatusOnly: Boolean;
    FWarn: Boolean;
    FStrict: Boolean;
    FIgnoreMissing: Boolean;
    function ParseCheckLine(const Line: string; out Digest, Name: string): Boolean;
    function DigestMatches(const Output: TDigestOutput; const Digest: string): Boolean;
  public
    constructor Create(Algorithm: TDigestAlgorithm);
    { Returns False if any check failed. }
    function CheckList(const ListPath: string): Boolean;
    property Quiet: Boolean read FQuiet write FQuiet;
    property StatusOnly: Boolean read FStatusOnly write FStatusOnly;
    property Warn: Boolean read FWarn write FWarn;
    property Strict: Boolean read FStrict write FStrict;
    property IgnoreMissing: Boolean read FIgnoreMissing write FIgnoreMissing;
  end;

function DigestFile(Algorithm: TDigestAlgorithm; const Path: string; out Output: TDigestOutput): Boolean;
var
  Handle: Int64;
  Context: TDigestContext;
  Buffer: array of Byte;
  Count: Int64;
  Information: TFileInformation;
begin
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
    if (GetHandleInformation(Handle, Information) = ErrorNone) and (Information.Kind = KindDirectory) then
    begin
      ReportError(ErrorIsDirectory, Path);
      CloseFile(Handle);
      Exit(False);
    end;
  end;

  Buffer := nil;
  SetLength(Buffer, ReadBufferSize);
  BeginDigest(Context, Algorithm);
  Result := True;
  repeat
    Count := ReadFile(Handle, @Buffer[0], ReadBufferSize);
    if Count < 0 then
    begin
      ReportError(ErrorCodeOf(Count), Path);
      Result := False;
      Break;
    end;
    UpdateDigest(Context, @Buffer[0], QWord(Count));
  until Count = 0;
  FinishDigest(Context, Output);
  if Handle <> StandardInputHandle then
    CloseFile(Handle);
end;

function DigestHex(Algorithm: TDigestAlgorithm; const Output: TDigestOutput): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 0 to DigestSize(Algorithm) - 1 do
    Result := Result + LowerCase(IntToHex(Output[Index], 2));
end;

function PluralSuffix(Count: Integer): string;
begin
  if Count = 1 then
    Result := ''
  else
    Result := 's';
end;

constructor TDigestChecker.Create(Algorithm: TDigestAlgorithm);
begin
  inherited Create;
  FAlgorithm := Algorithm;
end;

function TDigestChecker.DigestMatches(const Output: TDigestOutput; const Digest: string): Boolean;
begin
  Result := LowerCase(Digest) = DigestHex(FAlgorithm, Output);
end;

{ Splits a check line into digest and file name; False if malformed. }
function TDigestChecker.ParseCheckLine(const Line: string; out Digest, Name: string): Boolean;
var
  TagPrefix: string;
  Close: Integer;
begin
  Digest := '';
  Name := '';
  TagPrefix := string(DigestTagName(FAlgorithm)) + ' (';
  if StartsStr(TagPrefix, Line) then
  begin
    { ALGORITHM (NAME) = DIGEST }
    Close := PosEx(') = ', Line, Length(TagPrefix) + 1);
    if Close = 0 then
      Exit(False);
    Name := Copy(Line, Length(TagPrefix) + 1, Close - Length(TagPrefix) - 1);
    Digest := Copy(Line, Close + 4, MaxInt);
    Exit(True);
  end;
  { DIGEST  NAME or DIGEST *NAME }
  Close := Pos(' ', Line);
  if (Close <= 1) or (Close = Length(Line)) or not (Line[Close + 1] in [' ', '*']) then
    Exit(False);
  Digest := Copy(Line, 1, Close - 1);
  Name := Copy(Line, Close + 2, MaxInt);
  Result := Name <> '';
end;

function TDigestChecker.CheckList(const ListPath: string): Boolean;
var
  Stream: PInputStream;
  Line: string;
  HadLineEnd: Boolean;
  Digest: string;
  Name: string;
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
  while ReadTextLine(Stream, Line, HadLineEnd) do
  begin
    Inc(LineNumber);
    if not ParseCheckLine(Line, Digest, Name) then
    begin
      Inc(Malformed);
      if Warn then
        Report(Format('%s: %d: improperly formatted %s checksum line',
          [ListPath, LineNumber, string(DigestTagName(FAlgorithm))]));
      Continue;
    end;
    if IgnoreMissing and not PathExists(PChar(Name)) then
      Continue;
    Inc(Checked);
    if not DigestFile(FAlgorithm, Name, Output) then
    begin
      Inc(Unreadable);
      if not StatusOnly then
        PrintStringLine(Name + ': FAILED open or read');
    end
    else if DigestMatches(Output, Digest) then
    begin
      if not Quiet and not StatusOnly then
        PrintStringLine(Name + ': OK');
    end
    else
    begin
      Inc(Mismatched);
      if not StatusOnly then
        PrintStringLine(Name + ': FAILED');
    end;
  end;
  CloseInput(Stream);

  if not StatusOnly then
  begin
    if Malformed > 0 then
      Report(Format('WARNING: %d line%s improperly formatted', [Malformed, PluralSuffix(Malformed)]));
    if Unreadable > 0 then
      Report(Format('WARNING: %d listed file%s could not be read', [Unreadable, PluralSuffix(Unreadable)]));
    if Mismatched > 0 then
      Report(Format('WARNING: %d computed checksum%s did NOT match', [Mismatched, PluralSuffix(Mismatched)]));
  end;
  if (Checked = 0) and (Malformed > 0) then
  begin
    Report(ListPath + ': no properly formatted checksum lines found');
    Exit(False);
  end;
  Result := (Mismatched = 0) and (Unreadable = 0) and not (Strict and (Malformed > 0));
end;

function UsageText(Algorithm: TDigestAlgorithm): string;
begin
  Result := Format('Usage: %s [OPTION]... [FILE]...'#10 +
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
    [ProgramName, string(DigestTagName(Algorithm))]);
end;

procedure RunDigestTool(Algorithm: TDigestAlgorithm);
var
  CommandLine: TCommandLine;
  Checker: TDigestChecker;
  Code: Integer;
  Value: string;
  Binary: Boolean;
  Tagged: Boolean;
  LineEnd: Char;
  Check: Boolean;
  Path: string;
  Output: TDigestOutput;
  ExitStatus: LongInt;
begin
  Binary := False;
  Tagged := False;
  LineEnd := #10;
  Check := False;
  Checker := TDigestChecker.Create(Algorithm);
  CommandLine := TCommandLine.Create([
    CommandOption('b', 'binary', False, OptionBinary),
    CommandOption('t', 'text', False, OptionText),
    CommandOption(#0, 'tag', False, OptionTag),
    CommandOption('z', 'zero', False, OptionZero),
    CommandOption('c', 'check', False, OptionCheck),
    CommandOption(#0, 'quiet', False, OptionQuiet),
    CommandOption(#0, 'status', False, OptionStatus),
    CommandOption('w', 'warn', False, OptionWarn),
    CommandOption(#0, 'strict', False, OptionStrict),
    CommandOption(#0, 'ignore-missing', False, OptionIgnoreMissing)], UsageText(Algorithm));
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionBinary: Binary := True;
      OptionText: Binary := False;
      OptionTag: Tagged := True;
      OptionZero: LineEnd := #0;
      OptionCheck: Check := True;
      OptionQuiet: Checker.Quiet := True;
      OptionStatus: Checker.StatusOnly := True;
      OptionWarn: Checker.Warn := True;
      OptionStrict: Checker.Strict := True;
      OptionIgnoreMissing: Checker.IgnoreMissing := True;
    end;
  if CommandLine.OperandCount = 0 then
    CommandLine.Operands := ['-'];

  ExitStatus := 0;
  for Path in CommandLine.Operands do
  begin
    if Check then
    begin
      if not Checker.CheckList(Path) then
        ExitStatus := 1;
      Continue;
    end;
    if not DigestFile(Algorithm, Path, Output) then
    begin
      ExitStatus := 1;
      Continue;
    end;
    if Tagged then
      PrintString(Format('%s (%s) = ', [string(DigestTagName(Algorithm)), Path]) +
        DigestHex(Algorithm, Output))
    else if Binary then
      PrintString(DigestHex(Algorithm, Output) + ' *' + Path)
    else
      PrintString(DigestHex(Algorithm, Output) + '  ' + Path);
    PrintString(LineEnd);
  end;
  Halt(ExitStatus);
end;

end.
