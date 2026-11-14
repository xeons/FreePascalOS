{
  Commands built into the shell.

  Some commands have to run inside the shell because they change its
  state (cd, exit, export, unset, set, shift, read, ., break, continue,
  umask);
  a few more (:, true, false) are builtins only to save starting a
  process. Everything else is a program in /bin. The builtins about
  running commands and functions (eval, exec, command, type, return,
  local) are in Shell.CommandBuiltins, the job control ones (jobs, fg,
  bg, wait, kill) in Shell.JobBuiltins.
}
unit Shell.Builtins;

{$mode objfpc}
{$pointermath on}

interface

type
  TBuiltinRoutine = function(Arguments: PPChar; Count: Integer): LongInt;

{ Returns nil if Name is not a builtin. }
function FindBuiltin(Name: PChar): TBuiltinRoutine;

implementation

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Runtime.Text,
  Sys.Environment,
  Sys.Errors,
  Sys.Files,
  Sys.Format,
  Sys.Kernel,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
  Shell.Variables,
  Shell.Functions,
  Shell.CommandBuiltins,
  Shell.JobBuiltins,
  Shell.Execution;

procedure BuiltinError(Name: PChar; Format: PChar; const Arguments: array of TFormatArgument);
begin
  FlushStream(StandardOutput);
  WriteText(StandardError, 'sh: ');
  WriteText(StandardError, Name);
  WriteText(StandardError, ': ');
  WriteFormatted(StandardError, Format, Arguments);
  WriteCharacter(StandardError, #10);
end;

function BuiltinColon(Arguments: PPChar; Count: Integer): LongInt;
begin
  Result := 0;
end;

function BuiltinFalse(Arguments: PPChar; Count: Integer): LongInt;
begin
  Result := 1;
end;

function BuiltinChangeDirectory(Arguments: PPChar; Count: Integer): LongInt;
var
  Target: PChar;
  Directory: array[0..PathCapacity - 1] of Char;
  Error: LongInt;
begin
  if Count > 2 then
  begin
    BuiltinError('cd', 'too many arguments', []);
    Exit(1);
  end;
  if Count = 2 then
    Target := Arguments[1]
  else
  begin
    Target := LookupVariable('HOME');
    if Target = nil then
      Target := '/';
  end;
  if TextIsEqual(Target, '-') then
  begin
    Target := LookupVariable('OLDPWD');
    if Target = nil then
    begin
      BuiltinError('cd', 'OLDPWD not set', []);
      Exit(1);
    end;
  end;

  if GetCurrentDirectory(@Directory[0], PathCapacity) = ErrorNone then
    AssignVariable('OLDPWD', @Directory[0]);
  Error := ChangeDirectory(Target);
  if Error <> ErrorNone then
  begin
    BuiltinError('cd', '%s: %s', [ArgumentText(Target), ArgumentText(ErrorMessage(Error))]);
    Exit(1);
  end;
  if GetCurrentDirectory(@Directory[0], PathCapacity) = ErrorNone then
    AssignVariable('PWD', @Directory[0]);
  Result := 0;
end;

function BuiltinExit(Arguments: PPChar; Count: Integer): LongInt;
var
  Code: Int64;
begin
  Code := LastStatus;
  if (Count >= 2) and not ParseInteger(Arguments[1], Code) then
  begin
    BuiltinError('exit', '%s: numeric argument required', [ArgumentText(Arguments[1])]);
    Code := 2;
  end;
  ExitRequested := True;
  RequestedExitCode := LongInt(Code and $FF);
  Result := RequestedExitCode;
end;

function BuiltinExport(Arguments: PPChar; Count: Integer): LongInt;
var
  Index: Integer;
  Block: PPChar;
begin
  Result := 0;
  if Count = 1 then
  begin
    Block := EnvironmentBlock;
    Index := 0;
    while Block[Index] <> nil do
    begin
      WriteFormatted(StandardOutput, 'export %s'#10, [ArgumentText(Block[Index])]);
      Inc(Index);
    end;
    Exit;
  end;
  for Index := 1 to Count - 1 do
  begin
    if FindCharacter(Arguments[Index], '=') >= 0 then
    begin
      if not AssignFromText(Arguments[Index], True) then
      begin
        BuiltinError('export', '''%s'': not a valid identifier', [ArgumentText(Arguments[Index])]);
        Result := 1;
      end;
    end
    else if IsValidName(Arguments[Index]) then
      ExportVariable(Arguments[Index])
    else
    begin
      BuiltinError('export', '''%s'': not a valid identifier', [ArgumentText(Arguments[Index])]);
      Result := 1;
    end;
  end;
end;

{ unset [-v] NAME... removes variables; unset -f NAME... functions. }
function BuiltinUnset(Arguments: PPChar; Count: Integer): LongInt;
var
  Index: Integer;
  First: Integer;
  RemoveFunctions: Boolean;
begin
  First := 1;
  RemoveFunctions := False;
  if (Count > 1) and TextIsEqual(Arguments[1], '-f') then
  begin
    RemoveFunctions := True;
    First := 2;
  end
  else if (Count > 1) and TextIsEqual(Arguments[1], '-v') then
    First := 2;
  for Index := First to Count - 1 do
    if RemoveFunctions then
      UnsetFunction(Arguments[Index])
    else
      UnsetVariable(Arguments[Index]);
  Result := 0;
end;

{ set -- ARG... replaces the positional parameters. }
function BuiltinSet(Arguments: PPChar; Count: Integer): LongInt;
var
  First: Integer;
begin
  First := 1;
  if (Count > 1) and TextIsEqual(Arguments[1], '--') then
    First := 2;
  SetPositionalParameters(Arguments + First, Count - First);
  Result := 0;
end;

function BuiltinShift(Arguments: PPChar; Count: Integer): LongInt;
var
  Amount: Int64;
begin
  Amount := 1;
  if (Count >= 2) and (not ParseInteger(Arguments[1], Amount) or (Amount < 0)) then
  begin
    BuiltinError('shift', '%s: numeric argument required', [ArgumentText(Arguments[1])]);
    Exit(1);
  end;
  if Amount > PositionalCount then
    Exit(1);
  ShiftPositionalParameters(Integer(Amount));
  Result := 0;
end;

{ read NAME... reads one line from standard input and assigns its words
  to the names, the last name getting the rest of the line. It reads a
  byte at a time so it never consumes input beyond the line. }
function BuiltinRead(Arguments: PPChar; Count: Integer): LongInt;
var
  Line: TTextBuilder;
  Character: Char;
  BytesRead: Int64;
  SawLineEnd: Boolean;
  Position: PtrUInt;
  Start: PtrUInt;
  NameIndex: Integer;
  Word: PChar;
begin
  FlushStandardStreams;
  BeginText(Line);
  SawLineEnd := False;
  repeat
    BytesRead := ReadFile(StandardInputHandle, @Character, 1);
    if BytesRead <= 0 then
      Break;
    if Character = #10 then
    begin
      SawLineEnd := True;
      Break;
    end;
    AppendCharacter(Line, Character);
  until False;

  Position := 0;
  for NameIndex := 1 to Count - 1 do
  begin
    while IsSpace(Line.Text[Position]) do
      Inc(Position);
    Start := Position;
    if NameIndex = Count - 1 then
    begin
      Position := Line.Length;
      while (Position > Start) and IsSpace(Line.Text[Position - 1]) do
        Dec(Position);
    end
    else
      while (Line.Text[Position] <> #0) and not IsSpace(Line.Text[Position]) do
        Inc(Position);
    Word := PChar(AllocateMemory(Position - Start + 1));
    CopyMemory(Word, Line.Text + Start, Position - Start);
    Word[Position - Start] := #0;
    AssignVariable(Arguments[NameIndex], Word);
    FreeMemory(Word);
  end;

  if SawLineEnd or (Line.Length > 0) then
    Result := 0
  else
    Result := 1;
  DiscardText(Line);
end;

{ . FILE runs the commands in FILE in this shell. }
function BuiltinSource(Arguments: PPChar; Count: Integer): LongInt;
var
  Handle: Int64;
  Builder: TTextBuilder;
  Buffer: array[0..1023] of Char;
  BytesRead: Int64;
begin
  if Count < 2 then
  begin
    BuiltinError('.', 'file name argument required', []);
    Exit(2);
  end;
  Handle := OpenFile(Arguments[1], OpenRead);
  if Handle < 0 then
  begin
    BuiltinError('.', '%s: %s', [ArgumentText(Arguments[1]), ArgumentText(ErrorMessage(ErrorCodeOf(Handle)))]);
    Exit(1);
  end;
  BeginText(Builder);
  repeat
    BytesRead := ReadFile(Handle, @Buffer[0], SizeOf(Buffer));
    if BytesRead > 0 then
      AppendBytes(Builder, @Buffer[0], BytesRead);
  until BytesRead <= 0;
  CloseFile(Handle);
  Result := ExecuteText(Builder.Text);
  DiscardText(Builder);
end;

function LoopControlBuiltin(Name: PChar; Arguments: PPChar; Count: Integer;
  Control: TLoopControl): LongInt;
var
  Levels: Int64;
begin
  Levels := 1;
  if (Count >= 2) and (not ParseInteger(Arguments[1], Levels) or (Levels < 1)) then
  begin
    BuiltinError(Name, '%s: loop count out of range', [ArgumentText(Arguments[1])]);
    Exit(1);
  end;
  if LoopDepth = 0 then
    Exit(0);
  if Levels > LoopDepth then
    Levels := LoopDepth;
  LoopControl := Control;
  LoopLevels := Integer(Levels);
  Result := 0;
end;

function BuiltinBreak(Arguments: PPChar; Count: Integer): LongInt;
begin
  Result := LoopControlBuiltin('break', Arguments, Count, LoopControlBreak);
end;

function BuiltinContinue(Arguments: PPChar; Count: Integer): LongInt;
begin
  Result := LoopControlBuiltin('continue', Arguments, Count, LoopControlContinue);
end;

{ umask [-S] [MODE]: shows or sets the permission bits taken away from
  new files. MODE is octal. }
function BuiltinUmask(Arguments: PPChar; Count: Integer): LongInt;
const
  Classes: array[0..2] of Char = ('u', 'g', 'o');
var
  Mask: LongWord;
  Symbolic: Boolean;
  First: Integer;
  Position: Integer;
  ClassIndex: Integer;
  Allowed: LongWord;
begin
  Symbolic := (Count >= 2) and TextIsEqual(Arguments[1], '-S');
  First := 1;
  if Symbolic then
    First := 2;
  if First < Count then
  begin
    Mask := 0;
    Position := 0;
    while Arguments[First][Position] in ['0'..'7'] do
    begin
      Mask := Mask * 8 + LongWord(Ord(Arguments[First][Position]) - Ord('0'));
      Inc(Position);
    end;
    if (Position = 0) or (Arguments[First][Position] <> #0) or (Mask > $1FF) then
    begin
      BuiltinError('umask', '%s: octal number out of range', [ArgumentText(Arguments[First])]);
      Exit(1);
    end;
    KernelSetUmask(Mask);
    Exit(0);
  end;
  { Reading the mask means setting it and putting it back. }
  Mask := LongWord(KernelSetUmask(0));
  KernelSetUmask(Mask);
  if Symbolic then
  begin
    for ClassIndex := 0 to 2 do
    begin
      if ClassIndex > 0 then
        WriteCharacter(StandardOutput, ',');
      WriteCharacter(StandardOutput, Classes[ClassIndex]);
      WriteCharacter(StandardOutput, '=');
      Allowed := (not Mask shr (3 * (2 - ClassIndex))) and 7;
      if (Allowed and 4) <> 0 then WriteCharacter(StandardOutput, 'r');
      if (Allowed and 2) <> 0 then WriteCharacter(StandardOutput, 'w');
      if (Allowed and 1) <> 0 then WriteCharacter(StandardOutput, 'x');
    end;
  end
  else
  begin
    WriteCharacter(StandardOutput, '0');
    WriteCharacter(StandardOutput, Char(Ord('0') + (Mask shr 6) and 7));
    WriteCharacter(StandardOutput, Char(Ord('0') + (Mask shr 3) and 7));
    WriteCharacter(StandardOutput, Char(Ord('0') + Mask and 7));
  end;
  WriteCharacter(StandardOutput, #10);
  Result := 0;
end;

function FindBuiltin(Name: PChar): TBuiltinRoutine;
begin
  if TextIsEqual(Name, ':') or TextIsEqual(Name, 'true') then
    Result := @BuiltinColon
  else if TextIsEqual(Name, 'false') then
    Result := @BuiltinFalse
  else if TextIsEqual(Name, 'cd') then
    Result := @BuiltinChangeDirectory
  else if TextIsEqual(Name, 'exit') then
    Result := @BuiltinExit
  else if TextIsEqual(Name, 'export') then
    Result := @BuiltinExport
  else if TextIsEqual(Name, 'unset') then
    Result := @BuiltinUnset
  else if TextIsEqual(Name, 'set') then
    Result := @BuiltinSet
  else if TextIsEqual(Name, 'shift') then
    Result := @BuiltinShift
  else if TextIsEqual(Name, 'read') then
    Result := @BuiltinRead
  else if TextIsEqual(Name, '.') or TextIsEqual(Name, 'source') then
    Result := @BuiltinSource
  else if TextIsEqual(Name, 'break') then
    Result := @BuiltinBreak
  else if TextIsEqual(Name, 'continue') then
    Result := @BuiltinContinue
  else if TextIsEqual(Name, 'umask') then
    Result := @BuiltinUmask
  else
  begin
    Result := FindCommandBuiltin(Name);
    if Result = nil then
      Result := FindJobBuiltin(Name);
  end;
end;

end.
