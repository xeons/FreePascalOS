{
  chroot - run command with special root directory

  chroot NEWROOT [COMMAND [ARG]...]

  Without COMMAND runs "$SHELL -i" (or /bin/sh -i). The command is looked
  up inside NEWROOT; shared libraries still come from the system's /lib.
}
program chroot;

{$mode objfpc}
{$pointermath on}

uses
  Runtime.Text,
  Sys.Environment,
  Sys.Format,
  Sys.Processes,
  Sys.Streams,
  Util.Commands,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: chroot [OPTION] NEWROOT [COMMAND [ARG]...]'#10 +
    'Run COMMAND with root directory set to NEWROOT.'#10#10 +
    'If no command is given, run ''"$SHELL" -i'' (default: ''/bin/sh -i'').'#10;

  StatusChrootFailed = 125;

var
  Error: LongInt;
  Shell: array[0..2] of PChar;
  Options: TProcessOptions;
  First: Integer;
begin
  First := 1;
  if (ArgumentTotal > 1) and TextIsEqual(Argument(1), '--help') then
  begin
    Print(Usage);
    Halt(0);
  end;
  if (ArgumentTotal > 1) and TextIsEqual(Argument(1), '--') then
    Inc(First);
  if First >= ArgumentTotal then
  begin
    Report('missing operand', []);
    Halt(StatusChrootFailed);
  end;

  Error := ChangeRootDirectory(Argument(First));
  if Error <> 0 then
    FailWithError(StatusChrootFailed, Error, 'cannot change root directory to ''%s''',
      [ArgumentText(Argument(First))]);

  DefaultProcessOptions(Options);
  if First + 1 < ArgumentTotal then
    RunCommandAndExit(ArgumentValues + First + 1, Options);
  Shell[0] := GetVariable('SHELL');
  if Shell[0] = nil then
    Shell[0] := '/bin/sh';
  Shell[1] := '-i';
  Shell[2] := nil;
  RunCommandAndExit(@Shell[0], Options);
end.
