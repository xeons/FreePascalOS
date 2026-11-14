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

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Errors,
  Sys.Files,
  Sys.Format,
  Sys.Streams,
  Sys.Text,
  Util.FileTree,
  Util.Messages,
  Util.Modes,
  Util.Options;

const
  Usage: PChar = 'Usage: chmod [OPTION]... MODE[,MODE]... FILE...'#10 +
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

var
  Change: TModeChange;
  ReportChanges: Boolean;
  Silent: Boolean;
  Verbose: Boolean;

function ChangeOne(Path: PChar; IsDirectory: Boolean; Context: Pointer): Boolean;
var
  Information: TFileInformation;
  NewMode: LongWord;
  Error: LongInt;
  OldText: array[0..9] of Char;
  NewText: array[0..9] of Char;
begin
  Result := True;
  Error := GetFileInformation(Path, Information);
  if Error <> ErrorNone then
  begin
    if not Silent then
      ReportError(Error, 'cannot access ''%s''', [ArgumentText(Path)]);
    Exit(False);
  end;
  NewMode := ApplyModeChange(Change, Information.Mode, Information.Kind = KindDirectory);
  if NewMode <> (Information.Mode and $FFF) then
  begin
    Error := ChangeMode(Path, NewMode);
    if Error <> ErrorNone then
    begin
      if not Silent then
        ReportError(Error, 'changing permissions of ''%s''', [ArgumentText(Path)]);
      Exit(False);
    end;
  end;
  if Verbose or (ReportChanges and (NewMode <> (Information.Mode and $FFF))) then
  begin
    if NewMode = (Information.Mode and $FFF) then
      WriteFormatted(StandardOutput, 'mode of ''%s'' retained as %04o (%s)'#10, [ArgumentText(Path),
        ArgumentUnsigned(NewMode), ArgumentText(FormatModeText(NewMode, @NewText[0]))])
    else
      WriteFormatted(StandardOutput, 'mode of ''%s'' changed from %04o (%s) to %04o (%s)'#10, [ArgumentText(Path),
        ArgumentUnsigned(Information.Mode and $FFF), ArgumentText(FormatModeText(Information.Mode, @OldText[0])),
        ArgumentUnsigned(NewMode), ArgumentText(FormatModeText(NewMode, @NewText[0]))]);
  end;
end;

{ During a recursive walk symbolic links are skipped. }
function VisitInWalk(Path: PChar; IsDirectory: Boolean; Context: Pointer): Boolean;
var
  Information: TFileInformation;
begin
  if (GetLinkInformation(Path, Information) = ErrorNone) and (Information.Kind = KindSymbolicLink) then
    Exit(True);
  Result := ChangeOne(Path, IsDirectory, Context);
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Recursive: Boolean;
  Reference: PChar;
  First: Integer;
  Index: Integer;
  ExitStatus: LongInt;
  Information: TFileInformation;
  OctalText: array[0..7] of Char;
  ModeText: PChar;
begin
  Recursive := False;
  Reference := nil;
  BeginOptions(Parser, [
    OptionDefinition('c', 'changes', False, OptionChanges),
    OptionDefinition('f', 'silent', False, OptionSilent),
    OptionDefinition(#0, 'quiet', False, OptionSilent),
    OptionDefinition('v', 'verbose', False, OptionVerbose),
    OptionDefinition(#0, 'reference', True, OptionReference),
    OptionDefinition('R', 'recursive', False, OptionRecursive)], Usage);
  { "-w" or "-x" are modes, not options. }
  Parser.NegativeNumbersAreOperands := True;
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionChanges: ReportChanges := True;
      OptionSilent: Silent := True;
      OptionVerbose: Verbose := True;
      OptionReference: Reference := Value;
      OptionRecursive: Recursive := True;
    end;

  First := 0;
  if Reference <> nil then
  begin
    if GetFileInformation(Reference, Information) <> ErrorNone then
      Fail(1, 'failed to get attributes of ''%s''', [ArgumentText(Reference)]);
    OctalText[0] := #0;
    Change.IsOctal := True;
    Change.OctalValue := Information.Mode and $FFF;
    Change.Text := @OctalText[0];
  end
  else
  begin
    if Parser.OperandCount = 0 then
      FailWithUsageHint('missing operand', []);
    ModeText := Parser.Operands[0];
    if not ParseModeChange(ModeText, Change) then
      Fail(1, 'invalid mode: ''%s''', [ArgumentText(ModeText)]);
    First := 1;
  end;
  if First >= Parser.OperandCount then
    FailWithUsageHint('missing operand after ''%s''', [ArgumentText(Parser.Operands[0])]);

  ExitStatus := 0;
  for Index := First to Parser.OperandCount - 1 do
  begin
    if Recursive then
    begin
      if not WalkTree(Parser.Operands[Index], @VisitInWalk, nil) then
        ExitStatus := 1;
    end
    else if not ChangeOne(Parser.Operands[Index], False, nil) then
      ExitStatus := 1;
  end;
  Halt(ExitStatus);
end.
