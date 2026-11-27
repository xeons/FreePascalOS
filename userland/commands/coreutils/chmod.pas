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
  chmod - change file mode bits

  chmod [-cfvR] MODE[,MODE]... FILE...
  chmod [-cfvR] --reference=RFILE FILE...

  MODE is octal (644) or symbolic (u+x,go-w); see Util.Modes. Symbolic
  links are not changed themselves; their targets are, except during a
  recursive walk, where links are skipped. FAT and exFAT keep only
  "writable or not".
}
program chmod;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Util.CommandLine,
  Util.FileTree,
  Util.Messages,
  Util.Modes,
  Sys.Streams,
  Util.Numbers;

const
  Usage = 'Usage: chmod [OPTION]... MODE[,MODE]... FILE...'#10 +
    '  or:  chmod [OPTION]... OCTAL-MODE FILE...'#10 +
    '  or:  chmod [OPTION]... --reference=RFILE FILE...'#10 +
    'Change the mode of each FILE to MODE.'#10#10 +
    '  -c, --changes          like verbose but report only when a change is made'#10 +
    '  -f, --silent, --quiet  suppress most error messages'#10 +
    '  -v, --verbose          output a diagnostic for every file processed'#10 +
    '      --reference=RFILE  use RFILE''s mode instead of specifying MODE values'#10 +
    '  -R, --recursive        change files and directories recursively'#10#10 +
    'Each MODE is of the form ''[ugoa]*([-+=]([rwxXst]*|[ugo]))+|[-+=][0-7]+''.'#10;

  OptionChanges = 1;
  OptionSilent = 2;
  OptionVerbose = 3;
  OptionReference = 4;
  OptionRecursive = 5;

type
  { Applies one mode change to files, reporting as the options ask. }
  TModeChanger = class
  public
    Change: TModeChange;
    ReportChanges: Boolean;
    Silent: Boolean;
    Verbose: Boolean;
    function ChangeOne(const Path: string): Boolean;
    { During a recursive walk symbolic links are skipped. }
    function VisitInWalk(const Path: string; IsDirectory: Boolean): Boolean;
  end;

function TModeChanger.ChangeOne(const Path: string): Boolean;
var
  Information: TFileInformation;
  OldMode: LongWord;
  NewMode: LongWord;
  Error: LongInt;
begin
  Result := True;
  Error := GetFileInformation(PChar(Path), Information);
  if Error <> ErrorNone then
  begin
    if not Silent then
      ReportError(Error, Format('cannot access ''%s''', [Path]));
    Exit(False);
  end;
  OldMode := Information.Mode and $FFF;
  NewMode := ApplyModeChange(Change, Information.Mode, Information.Kind = KindDirectory);
  if NewMode <> OldMode then
  begin
    Error := ChangeMode(PChar(Path), NewMode);
    if Error <> ErrorNone then
    begin
      if not Silent then
        ReportError(Error, Format('changing permissions of ''%s''', [Path]));
      Exit(False);
    end;
  end;
  if Verbose or (ReportChanges and (NewMode <> OldMode)) then
  begin
    if NewMode = OldMode then
      PrintString(Format('mode of ''%s'' retained as %s (%s)'#10, [Path, OctalText(NewMode, 4),
        FormatModeText(NewMode)]))
    else
      PrintString(Format('mode of ''%s'' changed from %s (%s) to %s (%s)'#10, [Path,
        OctalText(OldMode, 4), FormatModeText(Information.Mode), OctalText(NewMode, 4),
        FormatModeText(NewMode)]));
  end;
end;

function TModeChanger.VisitInWalk(const Path: string; IsDirectory: Boolean): Boolean;
var
  Information: TFileInformation;
begin
  if (GetLinkInformation(PChar(Path), Information) = ErrorNone) and
     (Information.Kind = KindSymbolicLink) then
    Exit(True);
  Result := ChangeOne(Path);
end;

var
  CommandLine: TCommandLine;
  Changer: TModeChanger;
  Code: Integer;
  Value: string;
  Recursive: Boolean;
  HasReference: Boolean;
  Reference: string;
  FirstFile: Integer;
  Index: Integer;
  ExitStatus: LongInt;
  Information: TFileInformation;
  ModeText: string;
begin
  Changer := TModeChanger.Create;
  Recursive := False;
  HasReference := False;
  CommandLine := TCommandLine.Create([
    CommandOption('c', 'changes', False, OptionChanges),
    CommandOption('f', 'silent', False, OptionSilent),
    CommandOption(#0, 'quiet', False, OptionSilent),
    CommandOption('v', 'verbose', False, OptionVerbose),
    CommandOption(#0, 'reference', True, OptionReference),
    CommandOption('R', 'recursive', False, OptionRecursive)], Usage);
  { "-w" or "-x" are modes, not options. }
  CommandLine.NegativeNumbersAreOperands := True;
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionChanges: Changer.ReportChanges := True;
      OptionSilent: Changer.Silent := True;
      OptionVerbose: Changer.Verbose := True;
      OptionReference:
        begin
          HasReference := True;
          Reference := Value;
        end;
      OptionRecursive: Recursive := True;
    end;

  FirstFile := 0;
  if HasReference then
  begin
    if GetFileInformation(PChar(Reference), Information) <> ErrorNone then
      Fail(1, Format('failed to get attributes of ''%s''', [Reference]));
    Changer.Change.Symbolic := '';
    Changer.Change.IsOctal := True;
    Changer.Change.OctalValue := Information.Mode and $FFF;
  end
  else
  begin
    if CommandLine.OperandCount = 0 then
      FailWithUsageHint('missing operand');
    ModeText := CommandLine.Operands[0];
    if not ParseModeChange(ModeText, Changer.Change) then
      Fail(1, Format('invalid mode: ''%s''', [ModeText]));
    FirstFile := 1;
  end;
  if FirstFile >= CommandLine.OperandCount then
  begin
    { With --reference and no files there is no operand to name. }
    if CommandLine.OperandCount = 0 then
      FailWithUsageHint('missing operand after ''(null)''');
    FailWithUsageHint(Format('missing operand after ''%s''', [CommandLine.Operands[0]]));
  end;

  ExitStatus := 0;
  for Index := FirstFile to CommandLine.OperandCount - 1 do
  begin
    if Recursive then
    begin
      if not WalkTree(CommandLine.Operands[Index], @Changer.VisitInWalk) then
        ExitStatus := 1;
    end
    else if not Changer.ChangeOne(CommandLine.Operands[Index]) then
      ExitStatus := 1;
  end;
  Halt(ExitStatus);
end.
