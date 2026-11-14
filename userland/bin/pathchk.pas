{
  pathchk - check whether file names are valid or portable

  pathchk [-pP] [--portability] NAME...

  Without options, checks this system's limits (255 bytes per component,
  1023 per name) and that existing leading components are directories.
  -p checks POSIX portability (14 bytes per component, 256 per name,
  only A-Z a-z 0-9 . _ -); -P rejects empty names and components
  starting with '-'.
}
program pathchk;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Text,
  Sys.Files,
  Sys.Format,
  Sys.Memory,
  Sys.Text,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: pathchk [OPTION]... NAME...'#10 +
    'Diagnose invalid or non-portable file names.'#10#10 +
    '  -p                  check for most POSIX systems'#10 +
    '  -P                  check for empty names and leading "-"'#10 +
    '      --portability   check for all POSIX systems (equivalent to -p -P)'#10;

  OptionPosix = 1;
  OptionExtra = 2;
  OptionPortability = 3;

  SystemComponentLimit = 255;
  SystemPathLimit = 1023;
  PosixComponentLimit = 14;
  PosixPathLimit = 256;

var
  CheckPosix: Boolean;
  CheckExtra: Boolean;

function IsPortableCharacter(Character: Char): Boolean;
begin
  Result := IsAlphanumeric(Character) or (Character in ['.', '_', '-', '/']);
end;

function CheckName(Name: PChar): Boolean;
var
  Length: PtrUInt;
  Index: PtrUInt;
  ComponentStart: PtrUInt;
  ComponentLimit: PtrUInt;
  PathLimit: PtrUInt;
  Prefix: PChar;
  Information: TFileInformation;
begin
  Length := TextLength(Name);
  if CheckExtra and (Length = 0) then
  begin
    Report('empty file name', []);
    Exit(False);
  end;
  if CheckPosix then
  begin
    ComponentLimit := PosixComponentLimit;
    PathLimit := PosixPathLimit;
    for Index := 0 to Length - 1 do
      if not IsPortableCharacter(Name[Index]) then
      begin
        Report('nonportable character ''%c'' in file name ''%s''', [ArgumentCharacter(Name[Index]),
          ArgumentText(Name)]);
        Exit(False);
      end;
  end
  else
  begin
    ComponentLimit := SystemComponentLimit;
    PathLimit := SystemPathLimit;
  end;
  if Length > PathLimit then
  begin
    Report('limit %u exceeded by length %u of file name ''%s''', [ArgumentUnsigned(PathLimit),
      ArgumentUnsigned(Length), ArgumentText(Name)]);
    Exit(False);
  end;

  ComponentStart := 0;
  Index := 0;
  while Index <= Length do
  begin
    if (Index = Length) or (Name[Index] = '/') then
    begin
      if Index - ComponentStart > ComponentLimit then
      begin
        Report('limit %u exceeded by length %u of file name component ''%s''', [ArgumentUnsigned(ComponentLimit),
          ArgumentUnsigned(Index - ComponentStart), ArgumentText(Name + ComponentStart)]);
        Exit(False);
      end;
      if CheckExtra and (Index > ComponentStart) and (Name[ComponentStart] = '-') then
      begin
        Report('leading ''-'' in a component of file name ''%s''', [ArgumentText(Name)]);
        Exit(False);
      end;
      { Without -p, existing leading parts must be directories. }
      if not CheckPosix and (Index < Length) and (Index > 0) then
      begin
        Prefix := PChar(AllocateMemory(Index + 1));
        CopyText(Prefix, Name, Index + 1);
        if (GetFileInformation(Prefix, Information) = 0) and (Information.Kind <> KindDirectory) then
        begin
          Report('''%s'' is not a directory', [ArgumentText(Prefix)]);
          FreeMemory(Prefix);
          Exit(False);
        end;
        FreeMemory(Prefix);
      end;
      ComponentStart := Index + 1;
    end;
    Inc(Index);
  end;
  Result := True;
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Index: Integer;
  ExitStatus: LongInt;
begin
  BeginOptions(Parser, [
    OptionDefinition('p', nil, False, OptionPosix),
    OptionDefinition('P', nil, False, OptionExtra),
    OptionDefinition(#0, 'portability', False, OptionPortability)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionPosix: CheckPosix := True;
      OptionExtra: CheckExtra := True;
      OptionPortability:
        begin
          CheckPosix := True;
          CheckExtra := True;
        end;
    end;
  if Parser.OperandCount = 0 then
    FailWithUsageHint('missing operand', []);
  ExitStatus := 0;
  for Index := 0 to Parser.OperandCount - 1 do
    if not CheckName(Parser.Operands[Index]) then
      ExitStatus := 1;
  Halt(ExitStatus);
end.
