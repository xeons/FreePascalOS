{
  Builtins about running commands and functions:

    eval ARG...          runs the arguments, joined by spaces, as shell input
    exec [PROGRAM ARG...] (the program case is handled by Shell.Execution;
                         alone, with redirections, they become permanent)
    command [-v] NAME... runs NAME skipping functions; -v tells what it is
    type NAME...         tells whether NAME is a keyword, function, builtin
                         or program
    wait                 accepted; background programs are not tracked
    return [N]           leaves the current function with status N
    local NAME[=VALUE]... makes variables local to the current function
}
unit Shell.CommandBuiltins;

{$mode objfpc}
{$pointermath on}

interface

uses
  Shell.Builtins;

{ Returns nil if Name is not one of these builtins. }
function FindCommandBuiltin(Name: PChar): TBuiltinRoutine;

implementation

uses
  Runtime.Text,
  Sys.Format,
  Sys.Processes,
  Sys.Streams,
  Sys.Text,
  Shell.Variables,
  Shell.Functions,
  Shell.Execution;

const
  ProgramPathCapacity = 1024;

procedure CommandError(Name: PChar; Format: PChar; const Arguments: array of TFormatArgument);
begin
  FlushStream(StandardOutput);
  WriteText(StandardError, 'sh: ');
  WriteText(StandardError, Name);
  WriteText(StandardError, ': ');
  WriteFormatted(StandardError, Format, Arguments);
  WriteCharacter(StandardError, #10);
end;

function IsKeyword(Name: PChar): Boolean;
const
  Keywords: array[0..15] of PChar = ('if', 'then', 'else', 'elif', 'fi', 'while', 'until', 'for',
    'do', 'done', 'case', 'esac', 'in', 'function', '{', '}');
var
  Index: Integer;
begin
  for Index := Low(Keywords) to High(Keywords) do
    if TextIsEqual(Name, Keywords[Index]) then
      Exit(True);
  Result := False;
end;

function IsBuiltinName(Name: PChar): Boolean;
begin
  Result := FindBuiltin(Name) <> nil;
end;

function BuiltinEval(Arguments: PPChar; Count: Integer): LongInt;
var
  Builder: TTextBuilder;
  Index: Integer;
begin
  if Count < 2 then
    Exit(0);
  BeginText(Builder);
  for Index := 1 to Count - 1 do
  begin
    if Index > 1 then
      AppendCharacter(Builder, ' ');
    AppendText(Builder, Arguments[Index]);
  end;
  Result := ExecuteText(Builder.Text);
  DiscardText(Builder);
end;

{ Reached only for "exec" without a program (see Shell.Execution). }
function BuiltinExec(Arguments: PPChar; Count: Integer): LongInt;
begin
  Result := 0;
end;

{ Describes Name for "type" (Verbose) or "command -v". Returns False if
  it is not found. }
function DescribeCommand(Name: PChar; Verbose: Boolean): Boolean;
var
  ProgramPath: array[0..ProgramPathCapacity - 1] of Char;
begin
  Result := True;
  if IsKeyword(Name) then
  begin
    WriteText(StandardOutput, Name);
    if Verbose then
      WriteText(StandardOutput, ' is a shell keyword');
    WriteCharacter(StandardOutput, #10);
  end
  else if FindFunction(Name) <> nil then
  begin
    WriteText(StandardOutput, Name);
    if Verbose then
      WriteText(StandardOutput, ' is a shell function');
    WriteCharacter(StandardOutput, #10);
  end
  else if IsBuiltinName(Name) then
  begin
    WriteText(StandardOutput, Name);
    if Verbose then
      WriteText(StandardOutput, ' is a shell builtin');
    WriteCharacter(StandardOutput, #10);
  end
  else if FindProgram(Name, @ProgramPath[0], ProgramPathCapacity) then
  begin
    if Verbose then
    begin
      WriteText(StandardOutput, Name);
      WriteText(StandardOutput, ' is ');
    end;
    WriteLine(StandardOutput, @ProgramPath[0]);
  end
  else
  begin
    if Verbose then
      CommandError('type', '%s: not found', [ArgumentText(Name)]);
    Result := False;
  end;
end;

function BuiltinType(Arguments: PPChar; Count: Integer): LongInt;
var
  Index: Integer;
begin
  Result := 0;
  for Index := 1 to Count - 1 do
    if not DescribeCommand(Arguments[Index], True) then
      Result := 1;
end;

{ "command NAME ..." is turned into a plain run of NAME by
  Shell.Execution; what reaches here is "command" alone or "command -v". }
function BuiltinCommand(Arguments: PPChar; Count: Integer): LongInt;
var
  Index: Integer;
begin
  Result := 0;
  if Count < 2 then
    Exit;
  if not TextIsEqual(Arguments[1], '-v') and not TextIsEqual(Arguments[1], '-V') then
  begin
    CommandError('command', '%s: unknown option', [ArgumentText(Arguments[1])]);
    Exit(2);
  end;
  for Index := 2 to Count - 1 do
    if not DescribeCommand(Arguments[Index], TextIsEqual(Arguments[1], '-V')) then
      Result := 1;
end;

function BuiltinWait(Arguments: PPChar; Count: Integer): LongInt;
begin
  Result := 0;
end;

function BuiltinReturn(Arguments: PPChar; Count: Integer): LongInt;
var
  Status: Int64;
begin
  Status := LastStatus;
  if (Count >= 2) and not ParseInteger(Arguments[1], Status) then
  begin
    CommandError('return', '%s: numeric argument required', [ArgumentText(Arguments[1])]);
    Status := 2;
  end;
  if FunctionDepth = 0 then
  begin
    CommandError('return', 'can only be used in a function', []);
    Exit(1);
  end;
  ReturnRequested := True;
  ReturnStatus := LongInt(Status and $FF);
  Result := ReturnStatus;
end;

function BuiltinLocal(Arguments: PPChar; Count: Integer): LongInt;
var
  Index: Integer;
  EqualsPosition: PtrInt;
  Name: array[0..255] of Char;
begin
  Result := 0;
  if FunctionDepth = 0 then
  begin
    CommandError('local', 'can only be used in a function', []);
    Exit(1);
  end;
  for Index := 1 to Count - 1 do
  begin
    EqualsPosition := FindCharacter(Arguments[Index], '=');
    if EqualsPosition >= 0 then
    begin
      if EqualsPosition >= SizeOf(Name) then
      begin
        Result := 1;
        Continue;
      end;
      CopyText(@Name[0], Arguments[Index], PtrUInt(EqualsPosition) + 1);
    end
    else
      CopyText(@Name[0], Arguments[Index], SizeOf(Name));
    if not DeclareLocal(@Name[0]) then
    begin
      CommandError('local', '%s: not a valid name', [ArgumentText(@Name[0])]);
      Result := 1;
      Continue;
    end;
    if EqualsPosition >= 0 then
      AssignVariable(@Name[0], Arguments[Index] + EqualsPosition + 1);
  end;
end;

function FindCommandBuiltin(Name: PChar): TBuiltinRoutine;
begin
  if TextIsEqual(Name, 'eval') then
    Result := @BuiltinEval
  else if TextIsEqual(Name, 'exec') then
    Result := @BuiltinExec
  else if TextIsEqual(Name, 'command') then
    Result := @BuiltinCommand
  else if TextIsEqual(Name, 'type') then
    Result := @BuiltinType
  else if TextIsEqual(Name, 'wait') then
    Result := @BuiltinWait
  else if TextIsEqual(Name, 'return') then
    Result := @BuiltinReturn
  else if TextIsEqual(Name, 'local') then
    Result := @BuiltinLocal
  else
    Result := nil;
end;

end.
