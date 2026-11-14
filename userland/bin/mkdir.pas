{
  mkdir - make directories

  mkdir [-pv] DIRECTORY...

  -p creates missing parent directories and does not complain about
  directories that already exist.
}
program mkdir;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Files,
  Sys.Format,
  Sys.Memory,
  Sys.Streams,
  Util.Messages,
  Util.Modes,
  Util.Options;

const
  Usage: PChar = 'Usage: mkdir [OPTION]... DIRECTORY...'#10 +
    'Create the DIRECTORY(ies), if they do not already exist.'#10 +
    #10 +
    '  -m, --mode=MODE   set file mode (as in chmod), not a=rwx - umask'#10 +
    '  -p, --parents     no error if existing, make parent directories as needed'#10 +
    '  -v, --verbose     print a message for each created directory'#10;

  OptionMode = 1;
  OptionParents = 2;
  OptionVerbose = 3;

var
  Verbose: Boolean;
  HasMode: Boolean;
  ModeChange: TModeChange;

function MakeOne(Path: PChar): LongInt;
begin
  Result := CreateDirectory(Path);
  if (Result = ErrorNone) and Verbose then
    WriteFormatted(StandardOutput, '%s: created directory ''%s'''#10, [ArgumentText(ProgramName), ArgumentText(Path)]);
end;

{ Creates every missing directory along Path. }
function MakeWithParents(Path: PChar): LongInt;
var
  Copy: PChar;
  Position: PtrUInt;
begin
  Copy := DuplicateText(Path);
  Position := 1;
  Result := ErrorNone;
  while True do
  begin
    while (Copy[Position] <> '/') and (Copy[Position] <> #0) do
      Inc(Position);
    if Copy[Position] = '/' then
    begin
      Copy[Position] := #0;
      if not IsDirectory(Copy) then
      begin
        Result := MakeOne(Copy);
        if Result <> ErrorNone then
          Break;
      end;
      Copy[Position] := '/';
      Inc(Position);
      Continue;
    end;
    if not IsDirectory(Copy) then
      Result := MakeOne(Copy);
    Break;
  end;
  FreeMemory(Copy);
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Parents: Boolean;
  Index: Integer;
  Error: LongInt;
  ExitStatus: LongInt;
begin
  Parents := False;
  Verbose := False;
  BeginOptions(Parser, [
    OptionDefinition('m', 'mode', True, OptionMode),
    OptionDefinition('p', 'parents', False, OptionParents),
    OptionDefinition('v', 'verbose', False, OptionVerbose)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionMode:
        begin
          if not ParseModeChange(Value, ModeChange) then
            Fail(1, 'invalid mode ''%s''', [ArgumentText(Value)]);
          HasMode := True;
        end;
      OptionParents: Parents := True;
      OptionVerbose: Verbose := True;
    end;
  if Parser.OperandCount = 0 then
    FailWithUsageHint('missing operand', []);

  ExitStatus := 0;
  for Index := 0 to Parser.OperandCount - 1 do
  begin
    if Parents then
      Error := MakeWithParents(Parser.Operands[Index])
    else
      Error := MakeOne(Parser.Operands[Index]);
    if Error <> ErrorNone then
    begin
      ReportError(Error, 'cannot create directory ''%s''', [ArgumentText(Parser.Operands[Index])]);
      ExitStatus := 1;
    end
    else if HasMode then
    begin
      { The mode applies to the named directory, as in GNU mkdir. }
      Error := ChangeMode(Parser.Operands[Index], ApplyModeChange(ModeChange, $1ED, True));
      if Error <> ErrorNone then
      begin
        ReportError(Error, 'cannot set permissions of ''%s''', [ArgumentText(Parser.Operands[Index])]);
        ExitStatus := 1;
      end;
    end;
  end;
  Halt(ExitStatus);
end.
