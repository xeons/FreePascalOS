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
  Sys.Processes,
  Util.LineEditor,
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

{ "fpos:/current/directory$ ", or "> " while a command continues. }
function MakePrompt(Continuation: Boolean): PChar;
var
  Directory: array[0..PathCapacity - 1] of Char;
  Builder: TTextBuilder;
begin
  if Continuation then
    Exit(DuplicateText('> '));
  if GetCurrentDirectory(@Directory[0], PathCapacity) <> ErrorNone then
    CopyText(@Directory[0], '?', PathCapacity);
  BeginText(Builder);
  AppendText(Builder, 'fpos:');
  AppendText(Builder, @Directory[0]);
  AppendText(Builder, '$ ');
  Result := FinishText(Builder);
end;

function HistoryFilePath: PChar;
var
  Home: PChar;
  Builder: TTextBuilder;
begin
  Home := LookupVariable('HOME');
  if (Home = nil) or (Home^ = #0) then
    Home := '/';
  BeginText(Builder);
  AppendText(Builder, Home);
  if Builder.Text[Builder.Length - 1] <> '/' then
    AppendCharacter(Builder, '/');
  AppendText(Builder, '.sh_history');
  Result := FinishText(Builder);
end;

{ Reads and runs commands line by line until end of input or exit. A
  command spanning several lines (an open quote or an unfinished if,
  while, ...) is collected before it runs. On the console, lines are read
  with editing and history, and Ctrl-C does not end the shell. }
procedure RunInteractive(OnConsole: Boolean);
var
  Pending: TTextBuilder;
  Line: PChar;
  HadLineEnd: Boolean;
  Tree: PNode;
  Message: PChar;
  Editor: TLineEditor;
  Prompt: PChar;
  HistoryPath: PChar;
  GotLine: Boolean;
begin
  if OnConsole then
  begin
    ShellIsInteractive := True;
    IgnoreInterrupts(True);
    HistoryPath := HistoryFilePath;
    BeginLineEditor(Editor, HistoryPath, StandardErrorHandle);
    FreeMemory(HistoryPath);
  end;

  BeginText(Pending);
  while not ExitRequested do
  begin
    if OnConsole then
    begin
      Prompt := MakePrompt(Pending.Length > 0);
      GotLine := EditLine(Editor, Prompt, Line) = EditLineReady;
      FreeMemory(Prompt);
      if GotLine then
        AddHistoryLine(Editor, Line);
    end
    else
      GotLine := ReadLine(StandardInput, Line, HadLineEnd);
    if not GotLine then
      Break;
    AppendText(Pending, Line);
    AppendCharacter(Pending, #10);
    FreeMemory(Line);

    case ParseInput(Pending.Text, Tree, Message) of
      ParseIncomplete:
        Continue;
      ParseSuccess:
        begin
          InterruptRequested := False;
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
  if OnConsole then
    SaveHistory(Editor);
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
