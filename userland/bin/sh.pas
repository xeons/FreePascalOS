{
  sh - the command shell

  sh                      read commands from standard input (with a
                          prompt when it is the console)
  sh -c COMMAND [NAME [ARG]...]
                          run COMMAND; NAME becomes $0, ARGs $1...
  sh FILE [ARG]...        run the script FILE

  See Shell.Syntax for the supported grammar and Shell.Expansion for
  quoting and expansions.
}
program sh;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Environment,
  Sys.Errors,
  Sys.Files,
  Sys.Kernel,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
  Shell.Syntax,
  Shell.Variables,
  Shell.Execution;

function ReadWholeFile(Path: PChar; out Text: PChar): LongInt;
var
  Handle: Int64;
  Builder: TTextBuilder;
  Buffer: array[0..4095] of Char;
  BytesRead: Int64;
begin
  Text := nil;
  Handle := OpenFile(Path, OpenRead);
  if Handle < 0 then
    Exit(ErrorCodeOf(Handle));
  BeginText(Builder);
  repeat
    BytesRead := ReadFile(Handle, @Buffer[0], SizeOf(Buffer));
    if BytesRead > 0 then
      AppendBytes(Builder, @Buffer[0], BytesRead);
  until BytesRead <= 0;
  CloseFile(Handle);
  Text := FinishText(Builder);
  Result := ErrorNone;
end;

procedure WritePrompt(Continuation: Boolean);
var
  Directory: array[0..PathCapacity - 1] of Char;
begin
  if Continuation then
    WriteText(StandardError, '> ')
  else
  begin
    if GetCurrentDirectory(@Directory[0], PathCapacity) <> ErrorNone then
      CopyText(@Directory[0], '?', PathCapacity);
    WriteText(StandardError, 'fpos:');
    WriteText(StandardError, @Directory[0]);
    WriteText(StandardError, '$ ');
  end;
  FlushStream(StandardError);
end;

{ Reads and runs commands line by line until end of input or exit. A
  command spanning several lines (an open quote or an unfinished if,
  while, ...) is collected before it runs. }
procedure RunInteractive(ShowPrompt: Boolean);
var
  Pending: TTextBuilder;
  Line: PChar;
  HadLineEnd: Boolean;
  Tree: PNode;
  Message: PChar;
begin
  BeginText(Pending);
  while not ExitRequested do
  begin
    if ShowPrompt then
      WritePrompt(Pending.Length > 0);
    if not ReadLine(StandardInput, Line, HadLineEnd) then
      Break;
    AppendText(Pending, Line);
    AppendCharacter(Pending, #10);
    FreeMemory(Line);

    case ParseInput(Pending.Text, Tree, Message) of
      ParseIncomplete:
        Continue;
      ParseSuccess:
        begin
          ExecuteNode(Tree);
          FreeNode(Tree);
        end;
    else
      begin
        WriteText(StandardError, 'sh: ');
        WriteLine(StandardError, Message);
        LastStatus := 2;
      end;
    end;
    DiscardText(Pending);
    BeginText(Pending);
  end;
  if (Pending.Length > 0) and not ExitRequested then
  begin
    WriteLine(StandardError, 'sh: syntax error: unexpected end of input');
    LastStatus := 2;
  end;
  DiscardText(Pending);
  if ShowPrompt and not ExitRequested then
    WriteCharacter(StandardError, #10);
end;

procedure SetDefaultVariables;
var
  Directory: array[0..PathCapacity - 1] of Char;
begin
  if GetCurrentDirectory(@Directory[0], PathCapacity) = ErrorNone then
    AssignVariable('PWD', @Directory[0]);
  if GetVariable('PATH') = nil then
    SetVariable('PATH', '/bin');
end;

var
  Text: PChar;
  Error: LongInt;
begin
  SetDefaultVariables;
  ScriptName := Argument(0);

  if (ArgumentTotal >= 3) and TextIsEqual(Argument(1), '-c') then
  begin
    if ArgumentTotal >= 4 then
    begin
      ScriptName := Argument(3);
      SetPositionalParameters(ArgumentValues + 4, ArgumentTotal - 4);
    end
    else
      SetPositionalParameters(nil, 0);
    ExecuteText(Argument(2));
  end
  else if (ArgumentTotal = 2) and TextIsEqual(Argument(1), '-c') then
  begin
    WriteLine(StandardError, 'sh: -c: option requires an argument');
    Halt(2);
  end
  else if ArgumentTotal >= 2 then
  begin
    ScriptName := Argument(1);
    SetPositionalParameters(ArgumentValues + 2, ArgumentTotal - 2);
    Error := ReadWholeFile(Argument(1), Text);
    if Error <> ErrorNone then
    begin
      WriteText(StandardError, 'sh: ');
      WriteText(StandardError, Argument(1));
      WriteText(StandardError, ': ');
      WriteLine(StandardError, ErrorMessage(Error));
      Halt(127);
    end;
    ExecuteText(Text);
    FreeMemory(Text);
  end
  else
  begin
    SetPositionalParameters(nil, 0);
    RunInteractive(KernelGetHandleKind(StandardInputHandle) = HandleKindConsole);
  end;

  if ExitRequested then
    Halt(RequestedExitCode);
  Halt(LastStatus);
end.
