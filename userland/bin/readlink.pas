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
  Abi.SystemCalls,
  Sys.Files,
  Sys.Streams,
  Util.CommandLine,
  Util.Messages,
  Util.Paths;

const
  Usage = 'Usage: readlink [OPTION]... FILE...'#10 +
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

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Canonicalize: Boolean;
  CanonicalMode: TCanonicalMode;
  NoNewline: Boolean;
  Quiet: Boolean;
  LineEnd: Char;
  Operand: string;
  Target: string;
  Error: LongInt;
  ExitStatus: LongInt;
begin
  Canonicalize := False;
  CanonicalMode := CanonicalAllButLast;
  NoNewline := False;
  Quiet := True;
  LineEnd := #10;
  CommandLine := TCommandLine.Create([
    CommandOption('f', 'canonicalize', False, OptionCanonicalize),
    CommandOption('e', 'canonicalize-existing', False, OptionCanonicalizeExisting),
    CommandOption('m', 'canonicalize-missing', False, OptionCanonicalizeMissing),
    CommandOption('n', 'no-newline', False, OptionNoNewline),
    CommandOption('q', 'quiet', False, OptionQuiet),
    CommandOption('s', 'silent', False, OptionQuiet),
    CommandOption('v', 'verbose', False, OptionVerbose),
    CommandOption('z', 'zero', False, OptionZero)], Usage);
  while CommandLine.NextOption(Code, Value) do
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
  if CommandLine.OperandCount = 0 then
    FailWithUsageHint('missing operand');

  ExitStatus := 0;
  for Operand in CommandLine.Operands do
  begin
    if Canonicalize then
      Error := CanonicalizePath(Operand, CanonicalMode, True, Target)
    else
      Error := ReadLinkTarget(Operand, Target);
    if Error <> ErrorNone then
    begin
      if not Quiet then
        ReportError(Error, Operand);
      ExitStatus := 1;
      Continue;
    end;
    PrintString(Target);
    if not NoNewline or (CommandLine.OperandCount > 1) then
      WriteCharacter(StandardOutput, LineEnd);
  end;
  Halt(ExitStatus);
end.
