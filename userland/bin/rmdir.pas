{
  rmdir - remove empty directories

  rmdir [-pv] [--ignore-fail-on-non-empty] DIRECTORY...
}
program rmdir;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Files,
  Sys.Format,
  Sys.Streams,
  Sys.Text,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: rmdir [OPTION]... DIRECTORY...'#10 +
    'Remove the DIRECTORY(ies), if they are empty.'#10 +
    #10 +
    '      --ignore-fail-on-non-empty'#10 +
    '                    ignore each failure to remove a non-empty directory'#10 +
    '  -p, --parents     remove DIRECTORY and its ancestors'#10 +
    '  -v, --verbose     output a diagnostic for every directory processed'#10;

  OptionIgnoreNonEmpty = 1;
  OptionParents = 2;
  OptionVerbose = 3;

var
  IgnoreNonEmpty: Boolean;
  Verbose: Boolean;

{ Returns False if an error was reported. }
function RemoveOne(Path: PChar): Boolean;
var
  Information: TFileInformation;
  Error: LongInt;
begin
  if Verbose then
    WriteFormatted(StandardOutput, '%s: removing directory, ''%s'''#10, [ArgumentText(ProgramName), ArgumentText(Path)]);
  Error := GetLinkInformation(Path, Information);
  if (Error = ErrorNone) and (Information.Kind <> KindDirectory) then
    Error := ErrorNotDirectory;
  if Error = ErrorNone then
    Error := RemovePath(Path);
  if (Error = ErrorDirectoryNotEmpty) and IgnoreNonEmpty then
    Exit(True);
  if Error <> ErrorNone then
  begin
    ReportError(Error, 'failed to remove ''%s''', [ArgumentText(Path)]);
    Exit(False);
  end;
  Result := True;
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Parents: Boolean;
  Index: Integer;
  ExitStatus: LongInt;
  Path: array[0..PathCapacity - 1] of Char;
  LastSlash: PtrInt;
begin
  IgnoreNonEmpty := False;
  Parents := False;
  Verbose := False;
  BeginOptions(Parser, [
    OptionDefinition(#0, 'ignore-fail-on-non-empty', False, OptionIgnoreNonEmpty),
    OptionDefinition('p', 'parents', False, OptionParents),
    OptionDefinition('v', 'verbose', False, OptionVerbose)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionIgnoreNonEmpty: IgnoreNonEmpty := True;
      OptionParents: Parents := True;
      OptionVerbose: Verbose := True;
    end;
  if Parser.OperandCount = 0 then
    FailWithUsageHint('missing operand', []);

  ExitStatus := 0;
  for Index := 0 to Parser.OperandCount - 1 do
  begin
    CopyText(@Path[0], Parser.Operands[Index], PathCapacity);
    if not RemoveOne(@Path[0]) then
    begin
      ExitStatus := 1;
      Continue;
    end;
    if not Parents then
      Continue;
    { a/b/c: then a/b, then a. }
    repeat
      while (TextLength(@Path[0]) > 1) and (Path[TextLength(@Path[0]) - 1] = '/') do
        Path[TextLength(@Path[0]) - 1] := #0;
      LastSlash := FindLastCharacter(@Path[0], '/');
      if LastSlash <= 0 then
        Break;
      Path[LastSlash] := #0;
      if not RemoveOne(@Path[0]) then
      begin
        ExitStatus := 1;
        Break;
      end;
    until False;
  end;
  Halt(ExitStatus);
end.
