{
  id - print real and effective user and group IDs

  id [-ugGnr] [USER]

  Without USER this describes the running process: its effective ids
  (real ones with -r), and euid=/egid= when they differ from the real.
}
program id;

{$mode objfpc}
{$pointermath on}

uses
  Runtime.Text,
  Sys.Format,
  Sys.Streams,
  Util.Accounts,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: id [OPTION]... [USER]'#10 +
    'Print user and group information for the specified USER,'#10 +
    'or (when USER omitted) for the current user.'#10#10 +
    '  -g, --group     print only the effective group ID'#10 +
    '  -G, --groups    print all group IDs'#10 +
    '  -n, --name      print a name instead of a number, for -ugG'#10 +
    '  -r, --real      print the real ID instead of the effective ID, with -ugG'#10 +
    '  -u, --user      print only the effective user ID'#10 +
    '  -z, --zero      delimit entries with NUL characters, not whitespace'#10;

  OptionGroup = 1;
  OptionGroups = 2;
  OptionName = 3;
  OptionReal = 4;
  OptionUser = 5;
  OptionZero = 6;
  MaximumGroups = 64;

procedure WriteIdentifier(Id: LongWord; Name: PChar; AsName: Boolean);
begin
  if AsName and (Name <> nil) then
    WriteText(StandardOutput, Name)
  else
    WriteUnsigned(StandardOutput, Id);
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Selection: Integer;
  AsName: Boolean;
  Separator: Char;
  UserId: LongWord;
  GroupId: LongWord;
  Groups: array[0..MaximumGroups - 1] of LongWord;
  GroupCount: Integer;
  Index: Integer;
  RealIds: Boolean;
  ForProcess: Boolean;
begin
  RealIds := False;
  ForProcess := False;
  Selection := 0;
  AsName := False;
  Separator := ' ';
  BeginOptions(Parser, [
    OptionDefinition('g', 'group', False, OptionGroup),
    OptionDefinition('G', 'groups', False, OptionGroups),
    OptionDefinition('n', 'name', False, OptionName),
    OptionDefinition('r', 'real', False, OptionReal),
    OptionDefinition('u', 'user', False, OptionUser),
    OptionDefinition('z', 'zero', False, OptionZero)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionGroup, OptionGroups, OptionUser:
        begin
          if (Selection <> 0) and (Selection <> Code) then
            FailWithUsageHint('cannot print "only" of more than one choice', []);
          Selection := Code;
        end;
      OptionName: AsName := True;
      OptionReal: RealIds := True;
      OptionZero: Separator := #0;
    end;
  if Parser.OperandCount > 1 then
    FailWithUsageHint('extra operand ''%s''', [ArgumentText(Parser.Operands[1])]);

  if Parser.OperandCount = 1 then
  begin
    if not FindUserId(Parser.Operands[0], UserId) or (UserNameOf(UserId) = nil) then
      Fail(1, '''%s'': no such user', [ArgumentText(Parser.Operands[0])]);
    if not PrimaryGroupOf(UserId, GroupId) then
      GroupId := 0;
  end
  else
  begin
    ForProcess := True;
    UserId := CurrentUserId;
    GroupId := CurrentGroupId;
    { The plain form shows the real ids first, as GNU id does. }
    if RealIds or (Selection = 0) then
    begin
      UserId := CurrentRealUserId;
      GroupId := CurrentRealGroupId;
    end;
  end;
  if ForProcess then
    GroupCount := CurrentGroups(@Groups[0], MaximumGroups)
  else
    GroupCount := GroupsOfUser(UserId, @Groups[0], MaximumGroups);
  if GroupCount = 0 then
  begin
    Groups[0] := GroupId;
    GroupCount := 1;
  end;

  case Selection of
    OptionUser: WriteIdentifier(UserId, UserNameOf(UserId), AsName);
    OptionGroup: WriteIdentifier(GroupId, GroupNameOf(GroupId), AsName);
    OptionGroups:
      for Index := 0 to GroupCount - 1 do
      begin
        if Index > 0 then
          WriteCharacter(StandardOutput, Separator);
        WriteIdentifier(Groups[Index], GroupNameOf(Groups[Index]), AsName);
      end;
  else
    begin
      WriteFormatted(StandardOutput, 'uid=%u', [ArgumentUnsigned(UserId)]);
      if UserNameOf(UserId) <> nil then
        WriteFormatted(StandardOutput, '(%s)', [ArgumentText(UserNameOf(UserId))]);
      WriteFormatted(StandardOutput, ' gid=%u', [ArgumentUnsigned(GroupId)]);
      if GroupNameOf(GroupId) <> nil then
        WriteFormatted(StandardOutput, '(%s)', [ArgumentText(GroupNameOf(GroupId))]);
      if ForProcess and (CurrentUserId <> UserId) then
      begin
        WriteFormatted(StandardOutput, ' euid=%u', [ArgumentUnsigned(CurrentUserId)]);
        if UserNameOf(CurrentUserId) <> nil then
          WriteFormatted(StandardOutput, '(%s)', [ArgumentText(UserNameOf(CurrentUserId))]);
      end;
      if ForProcess and (CurrentGroupId <> GroupId) then
      begin
        WriteFormatted(StandardOutput, ' egid=%u', [ArgumentUnsigned(CurrentGroupId)]);
        if GroupNameOf(CurrentGroupId) <> nil then
          WriteFormatted(StandardOutput, '(%s)', [ArgumentText(GroupNameOf(CurrentGroupId))]);
      end;
      WriteText(StandardOutput, ' groups=');
      for Index := 0 to GroupCount - 1 do
      begin
        if Index > 0 then
          WriteCharacter(StandardOutput, ',');
        WriteUnsigned(StandardOutput, Groups[Index]);
        if GroupNameOf(Groups[Index]) <> nil then
          WriteFormatted(StandardOutput, '(%s)', [ArgumentText(GroupNameOf(Groups[Index]))]);
      end;
    end;
  end;
  if Separator = #0 then
    WriteCharacter(StandardOutput, #0)
  else
    WriteCharacter(StandardOutput, #10);
end.
