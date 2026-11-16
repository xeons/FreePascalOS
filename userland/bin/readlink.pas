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
  readlink - print resolved symbolic links or canonical file names

  readlink [-fnqsvz] FILE...

  Without -f prints the target of each symbolic link. With -f prints the
  canonical absolute name, following every link.
}
program readlink;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Util.Messages,
  Util.Options,
  Util.Paths;

const
  Usage: PChar = 'Usage: readlink [OPTION]... FILE...'#10 +
    'Print value of a symbolic link or canonical file name.'#10 +
    #10 +
    '  -f, --canonicalize     canonicalize by following every symlink in every'#10 +
    '                         component of the given name recursively'#10 +
    '  -n, --no-newline       do not output the trailing delimiter'#10 +
    '  -q, --quiet, -s, --silent  suppress most error messages'#10 +
    '  -v, --verbose          report error messages'#10 +
    '  -z, --zero             end each output line with NUL, not newline'#10;

  OptionCanonicalize = 1;
  OptionNoNewline = 2;
  OptionQuiet = 3;
  OptionVerbose = 4;
  OptionZero = 5;
  OptionCanonicalizeExisting = 6;
  OptionCanonicalizeMissing = 7;

function ReadLinkTarget(Path: PChar; out Target: string): LongInt;
begin
  SetLength(Target, PathCapacity);
  Result := ReadSymbolicLink(Path, PChar(Target), PathCapacity);
  if Result = ErrorNone then
    SetLength(Target, StrLen(PChar(Target)))
  else
    Target := '';
end;

function CanonicalTarget(Path: PChar; Mode: TCanonicalMode; out Target: string): LongInt;
var
  Canonical: PChar;
begin
  Result := CanonicalizePath(Path, Mode, True, Canonical);
  Target := '';
  if Result = ErrorNone then
  begin
    Target := Canonical;
    FreeMemory(Canonical);
  end;
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Canonicalize: Boolean;
  CanonicalMode: TCanonicalMode;
  NoNewline: Boolean;
  Quiet: Boolean;
  LineEnd: Char;
  Index: Integer;
  Target: string;
  Error: LongInt;
  ExitStatus: LongInt;
begin
  Canonicalize := False;
  CanonicalMode := CanonicalAllButLast;
  NoNewline := False;
  Quiet := True;
  LineEnd := #10;
  BeginOptions(Parser, [
    OptionDefinition('f', 'canonicalize', False, OptionCanonicalize),
    OptionDefinition('e', 'canonicalize-existing', False, OptionCanonicalizeExisting),
    OptionDefinition('m', 'canonicalize-missing', False, OptionCanonicalizeMissing),
    OptionDefinition('n', 'no-newline', False, OptionNoNewline),
    OptionDefinition('q', 'quiet', False, OptionQuiet),
    OptionDefinition('s', 'silent', False, OptionQuiet),
    OptionDefinition('v', 'verbose', False, OptionVerbose),
    OptionDefinition('z', 'zero', False, OptionZero)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionCanonicalize:
        begin
          Canonicalize := True;
          CanonicalMode := CanonicalAllButLast;
        end;
      OptionCanonicalizeExisting:
        begin
          Canonicalize := True;
          CanonicalMode := CanonicalExisting;
        end;
      OptionCanonicalizeMissing:
        begin
          Canonicalize := True;
          CanonicalMode := CanonicalMissingAllowed;
        end;
      OptionNoNewline: NoNewline := True;
      OptionQuiet: Quiet := True;
      OptionVerbose: Quiet := False;
      OptionZero: LineEnd := #0;
    end;
  if Parser.OperandCount = 0 then
    FailWithUsageHint('missing operand', []);

  ExitStatus := 0;
  for Index := 0 to Parser.OperandCount - 1 do
  begin
    if Canonicalize then
      Error := CanonicalTarget(Parser.Operands[Index], CanonicalMode, Target)
    else
      Error := ReadLinkTarget(Parser.Operands[Index], Target);
    if Error <> ErrorNone then
    begin
      if not Quiet then
        ReportError(Error, '%s', [ArgumentText(Parser.Operands[Index])]);
      ExitStatus := 1;
      Continue;
    end;
    WriteText(StandardOutput, PChar(Target));
    if not NoNewline or (Parser.OperandCount > 1) then
      WriteCharacter(StandardOutput, LineEnd);
  end;
  Halt(ExitStatus);
end.
