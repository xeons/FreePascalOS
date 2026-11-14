{
  groups - print the groups a user is in

  groups [USER]...
}
program groups;

{$mode objfpc}
{$pointermath on}

uses
  Sys.Format,
  Sys.Streams,
  Util.Accounts,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: groups [USER]...'#10 +
    'Print group memberships for each USERNAME or, if no USERNAME is specified,'#10 +
    'for the current process.'#10;
  MaximumGroups = 64;

procedure PrintGroupList(Count: Integer; Groups: PLongWord);
var
  Index: Integer;
begin
  for Index := 0 to Count - 1 do
  begin
    if Index > 0 then
      WriteCharacter(StandardOutput, ' ');
    if GroupNameOf(Groups[Index]) <> nil then
      WriteText(StandardOutput, GroupNameOf(Groups[Index]))
    else
      WriteUnsigned(StandardOutput, Groups[Index]);
  end;
  WriteCharacter(StandardOutput, #10);
end;

procedure PrintGroups(UserId: LongWord);
var
  Groups: array[0..MaximumGroups - 1] of LongWord;
begin
  PrintGroupList(GroupsOfUser(UserId, @Groups[0], MaximumGroups), @Groups[0]);
end;

var
  Parser: TOptionParser;
  Index: Integer;
  UserId: LongWord;
  ExitStatus: LongInt;
  CurrentList: array[0..MaximumGroups - 1] of LongWord;
begin
  ParseOperandsOnly(Parser, Usage);
  if Parser.OperandCount = 0 then
  begin
    PrintGroupList(CurrentGroups(@CurrentList[0], MaximumGroups), @CurrentList[0]);
    Halt(0);
  end;
  ExitStatus := 0;
  for Index := 0 to Parser.OperandCount - 1 do
  begin
    if not FindUserId(Parser.Operands[Index], UserId) or (UserNameOf(UserId) = nil) then
    begin
      Report('''%s'': no such user', [ArgumentText(Parser.Operands[Index])]);
      ExitStatus := 1;
      Continue;
    end;
    WriteFormatted(StandardOutput, '%s : ', [ArgumentText(Parser.Operands[Index])]);
    PrintGroups(UserId);
  end;
  Halt(ExitStatus);
end.
