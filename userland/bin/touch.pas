{
  touch - change file timestamps

  touch [-acmh] [-d DATE | -t STAMP | -r FILE] FILE...

  Sets the access and modification times of each FILE to now (or to the
  given time), creating it if it does not exist (unless -c). -a changes
  only the access time, -m only the modification time. DATE uses the
  forms of Util.Dates; STAMP is [[CC]YY]MMDDhhmm[.ss].
}
program touch;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Time,
  Sys.Errors,
  Sys.Files,
  Sys.Format,
  Sys.Time,
  Util.Dates,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: touch [OPTION]... FILE...'#10 +
    'Update the access and modification times of each FILE to the current time.'#10#10 +
    'A FILE argument that does not exist is created empty, unless -c or -h'#10 +
    'is supplied.'#10#10 +
    '  -a                     change only the access time'#10 +
    '  -c, --no-create        do not create any files'#10 +
    '  -d, --date=STRING      parse STRING and use it instead of current time'#10 +
    '  -h, --no-dereference   affect each symbolic link instead of any referenced'#10 +
    '                         file'#10 +
    '  -m                     change only the modification time'#10 +
    '  -r, --reference=FILE   use this file''s times instead of current time'#10 +
    '  -t STAMP               use [[CC]YY]MMDDhhmm[.ss] instead of current time'#10;

  OptionAccessOnly = 1;
  OptionNoCreate = 2;
  OptionDate = 3;
  OptionNoDereference = 4;
  OptionModificationOnly = 5;
  OptionReference = 6;
  OptionStamp = 7;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  NoCreate: Boolean;
  FollowLinks: Boolean;
  ChangeAccess: Boolean;
  ChangeModification: Boolean;
  AccessTime: TUnixTime;
  ModificationTime: TUnixTime;
  Information: TFileInformation;
  Index: Integer;
  Handle: Int64;
  Error: LongInt;
  ExitStatus: LongInt;
  Time: TUnixTime;
  UseNow: Boolean;
begin
  UseNow := True;
  NoCreate := False;
  FollowLinks := True;
  ChangeAccess := False;
  ChangeModification := False;
  Time := CurrentTime;
  AccessTime := Time;
  ModificationTime := Time;
  BeginOptions(Parser, [
    OptionDefinition('a', nil, False, OptionAccessOnly),
    OptionDefinition('c', 'no-create', False, OptionNoCreate),
    OptionDefinition('d', 'date', True, OptionDate),
    OptionDefinition('h', 'no-dereference', False, OptionNoDereference),
    OptionDefinition('m', nil, False, OptionModificationOnly),
    OptionDefinition('r', 'reference', True, OptionReference),
    OptionDefinition('t', nil, True, OptionStamp),
    OptionDefinition('f', nil, False, 0)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionAccessOnly: ChangeAccess := True;
      OptionNoCreate: NoCreate := True;
      OptionDate:
        begin
          UseNow := False;
          if not ParseDateText(Value, Time) then
            Fail(1, 'invalid date format ''%s''', [ArgumentText(Value)]);
          AccessTime := Time;
          ModificationTime := Time;
        end;
      OptionNoDereference:
        begin
          FollowLinks := False;
          NoCreate := True;
        end;
      OptionModificationOnly: ChangeModification := True;
      OptionReference:
        begin
          UseNow := False;
          Error := GetFileInformation(Value, Information);
          if Error <> ErrorNone then
            FailWithError(1, Error, 'failed to get attributes of ''%s''', [ArgumentText(Value)]);
          AccessTime := Information.AccessTime;
          ModificationTime := Information.ModificationTime;
        end;
      OptionStamp:
        begin
          UseNow := False;
          if not ParseTouchStamp(Value, Time) then
            Fail(1, 'invalid date format ''%s''', [ArgumentText(Value)]);
          AccessTime := Time;
          ModificationTime := Time;
        end;
    end;
  { Neither -a nor -m: change both. }
  if not ChangeAccess and not ChangeModification then
  begin
    ChangeAccess := True;
    ChangeModification := True;
  end;
  if not ChangeAccess then
    AccessTime := -1;
  if not ChangeModification then
    ModificationTime := -1;
  if Parser.OperandCount = 0 then
    FailWithUsageHint('missing file operand', []);

  ExitStatus := 0;
  for Index := 0 to Parser.OperandCount - 1 do
  begin
    if not PathExists(Parser.Operands[Index]) then
    begin
      if NoCreate then
        Continue;
      Handle := OpenFile(Parser.Operands[Index], OpenWrite or OpenCreate);
      if Handle < 0 then
      begin
        ReportError(ErrorCodeOf(Handle), 'cannot touch ''%s''', [ArgumentText(Parser.Operands[Index])]);
        ExitStatus := 1;
        Continue;
      end;
      CloseFile(Handle);
    end;
    if UseNow then
      Error := SetFileTimesToNow(Parser.Operands[Index], ChangeModification, ChangeAccess, FollowLinks)
    else
      Error := SetFileTimes(Parser.Operands[Index], ModificationTime, AccessTime, FollowLinks);
    if Error <> ErrorNone then
    begin
      ReportError(Error, 'setting times of ''%s''', [ArgumentText(Parser.Operands[Index])]);
      ExitStatus := 1;
    end;
  end;
  Halt(ExitStatus);
end.
