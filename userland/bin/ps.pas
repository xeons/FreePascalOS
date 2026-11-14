{
  ps - report a snapshot of the current processes

  ps [-eAf] [-o FORMAT] [-p PID[,PID...]] [-u USER[,USER...]]
  ps aux

  Lists the processes of the effective user by default; -e or -A lists
  all of them, -p and -u choose by process or user. -f is the full
  format, -o FORMAT a list of columns (comma or space separated, with
  NAME=HEADER to rename one), and "aux" the BSD style listing.

  Columns: pid ppid pgid uid user ruid ruser ni (nice) pri stat (s)
  nlwp (thcount) vsz rss (both KiB) %cpu %mem time etime stime (start)
  tty comm (cmd, args, command).

  Programs keep no command line in the kernel, so cmd and args show the
  program name, as comm does.
}
program ps;

{$mode objfpc}
{$pointermath on}

uses
  Abi.SystemCalls,
  Runtime.Memory,
  Runtime.Text,
  Sys.Environment,
  Sys.Format,
  Sys.Kernel,
  Sys.Memory,
  Sys.Streams,
  Sys.Text,
  Sys.Time,
  Util.Accounts,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: ps [OPTION]...'#10 +
    'Report a snapshot of the current processes.'#10#10 +
    '  -A, -e             select all processes'#10 +
    '  -f                 full format listing'#10 +
    '  -o, --format=LIST  user defined format: pid,ppid,pgid,uid,user,ruid,ruser,'#10 +
    '                     ni,pri,stat,nlwp,vsz,rss,%cpu,%mem,time,etime,stime,tty,comm'#10 +
    '  -p, --pid=LIST     select by process ID'#10 +
    '  -u, --user=LIST    select by effective user ID or name'#10 +
    '      --no-headers   do not print a header line'#10 +
    '  aux                BSD style: all processes, user oriented format'#10;

  OptionAll = 1;
  OptionFull = 2;
  OptionFormat = 3;
  OptionPid = 4;
  OptionUser = 5;
  OptionNoHeaders = 6;

  MaximumProcesses = 256;
  MaximumColumns = 24;
  MaximumSelected = 32;
  PageKiB = 4;

type
  TColumnKind = (ColumnPid, ColumnParent, ColumnGroup, ColumnUid, ColumnUser, ColumnRealUid,
    ColumnRealUser, ColumnNice, ColumnPriority, ColumnState, ColumnThreads, ColumnVirtual,
    ColumnResident, ColumnCpuPercent, ColumnMemoryPercent, ColumnTime, ColumnElapsed,
    ColumnStart, ColumnTerminal, ColumnCommand, ColumnCpu);

  TColumn = record
    Kind: TColumnKind;
    Header: PChar;
    Width: Integer;
    LeftAligned: Boolean;
  end;

  TColumnName = record
    Name: PChar;
    Kind: TColumnKind;
    Header: PChar;
    Width: Integer;
    LeftAligned: Boolean;
  end;

const
  ColumnNames: array[0..33] of TColumnName = (
    (Name: 'pid'; Kind: ColumnPid; Header: 'PID'; Width: 7; LeftAligned: False),
    (Name: 'ppid'; Kind: ColumnParent; Header: 'PPID'; Width: 7; LeftAligned: False),
    (Name: 'pgid'; Kind: ColumnGroup; Header: 'PGID'; Width: 7; LeftAligned: False),
    (Name: 'pgrp'; Kind: ColumnGroup; Header: 'PGRP'; Width: 7; LeftAligned: False),
    (Name: 'uid'; Kind: ColumnUid; Header: 'UID'; Width: 5; LeftAligned: False),
    (Name: 'euid'; Kind: ColumnUid; Header: 'EUID'; Width: 5; LeftAligned: False),
    (Name: 'user'; Kind: ColumnUser; Header: 'USER'; Width: 8; LeftAligned: True),
    (Name: 'euser'; Kind: ColumnUser; Header: 'EUSER'; Width: 8; LeftAligned: True),
    (Name: 'uname'; Kind: ColumnUser; Header: 'USER'; Width: 8; LeftAligned: True),
    (Name: 'ruid'; Kind: ColumnRealUid; Header: 'RUID'; Width: 5; LeftAligned: False),
    (Name: 'ruser'; Kind: ColumnRealUser; Header: 'RUSER'; Width: 8; LeftAligned: True),
    (Name: 'ni'; Kind: ColumnNice; Header: 'NI'; Width: 3; LeftAligned: False),
    (Name: 'nice'; Kind: ColumnNice; Header: 'NI'; Width: 3; LeftAligned: False),
    (Name: 'pri'; Kind: ColumnPriority; Header: 'PRI'; Width: 3; LeftAligned: False),
    (Name: 'stat'; Kind: ColumnState; Header: 'STAT'; Width: 4; LeftAligned: True),
    (Name: 's'; Kind: ColumnState; Header: 'S'; Width: 1; LeftAligned: True),
    (Name: 'state'; Kind: ColumnState; Header: 'S'; Width: 1; LeftAligned: True),
    (Name: 'nlwp'; Kind: ColumnThreads; Header: 'NLWP'; Width: 4; LeftAligned: False),
    (Name: 'thcount'; Kind: ColumnThreads; Header: 'THCNT'; Width: 5; LeftAligned: False),
    (Name: 'vsz'; Kind: ColumnVirtual; Header: 'VSZ'; Width: 6; LeftAligned: False),
    (Name: 'rss'; Kind: ColumnResident; Header: 'RSS'; Width: 5; LeftAligned: False),
    (Name: '%cpu'; Kind: ColumnCpuPercent; Header: '%CPU'; Width: 4; LeftAligned: False),
    (Name: 'pcpu'; Kind: ColumnCpuPercent; Header: '%CPU'; Width: 4; LeftAligned: False),
    (Name: '%mem'; Kind: ColumnMemoryPercent; Header: '%MEM'; Width: 4; LeftAligned: False),
    (Name: 'pmem'; Kind: ColumnMemoryPercent; Header: '%MEM'; Width: 4; LeftAligned: False),
    (Name: 'time'; Kind: ColumnTime; Header: 'TIME'; Width: 8; LeftAligned: False),
    (Name: 'etime'; Kind: ColumnElapsed; Header: 'ELAPSED'; Width: 11; LeftAligned: False),
    (Name: 'stime'; Kind: ColumnStart; Header: 'STIME'; Width: 5; LeftAligned: True),
    (Name: 'start'; Kind: ColumnStart; Header: 'START'; Width: 5; LeftAligned: True),
    (Name: 'tty'; Kind: ColumnTerminal; Header: 'TTY'; Width: 8; LeftAligned: True),
    (Name: 'comm'; Kind: ColumnCommand; Header: 'COMMAND'; Width: 0; LeftAligned: True),
    (Name: 'cmd'; Kind: ColumnCommand; Header: 'CMD'; Width: 0; LeftAligned: True),
    (Name: 'args'; Kind: ColumnCommand; Header: 'COMMAND'; Width: 0; LeftAligned: True),
    (Name: 'c'; Kind: ColumnCpu; Header: 'C'; Width: 2; LeftAligned: False));

var
  Columns: array[0..MaximumColumns - 1] of TColumn;
  ColumnCount: Integer;
  SelectAll: Boolean;
  SelectedPids: array[0..MaximumSelected - 1] of Int64;
  SelectedPidCount: Integer;
  SelectedUsers: array[0..MaximumSelected - 1] of LongWord;
  SelectedUserCount: Integer;
  ShowHeaders: Boolean;
  Now: Int64;
  TotalMemory: QWord;

procedure AddColumn(Kind: TColumnKind; Header: PChar; Width: Integer; LeftAligned: Boolean);
begin
  if ColumnCount >= MaximumColumns then
    Exit;
  Columns[ColumnCount].Kind := Kind;
  Columns[ColumnCount].Header := Header;
  Columns[ColumnCount].Width := Width;
  Columns[ColumnCount].LeftAligned := LeftAligned;
  Inc(ColumnCount);
end;

function AddNamedColumn(Name: PChar; Header: PChar): Boolean;
var
  Index: Integer;
begin
  for Index := Low(ColumnNames) to High(ColumnNames) do
    if TextIsEqual(ColumnNames[Index].Name, Name) or
       ((Name[0] = 'c') and TextIsEqual(Name, 'command') and TextIsEqual(ColumnNames[Index].Name, 'args')) then
    begin
      if Header = nil then
        Header := ColumnNames[Index].Header;
      AddColumn(ColumnNames[Index].Kind, Header, ColumnNames[Index].Width, ColumnNames[Index].LeftAligned);
      Exit(True);
    end;
  Result := False;
end;

{ "pid,user=WHO comm" }
procedure ParseFormat(List: PChar);
var
  Copy: PChar;
  Start: PChar;
  Position: PChar;
  Header: PChar;
  Equals: PChar;
  Ending: Char;
begin
  Copy := DuplicateText(List);
  Position := Copy;
  while Position^ <> #0 do
  begin
    while Position^ in [',', ' '] do
      Inc(Position);
    if Position^ = #0 then
      Break;
    Start := Position;
    Header := nil;
    Equals := nil;
    while not (Position^ in [#0, ',', ' ']) do
    begin
      if Position^ = '=' then
      begin
        { A header runs to the end of the list. }
        Equals := Position;
        while Position^ <> #0 do
          Inc(Position);
        Break;
      end;
      Inc(Position);
    end;
    Ending := Position^;
    Position^ := #0;
    if Equals <> nil then
    begin
      Equals^ := #0;
      Header := DuplicateText(Equals + 1);
    end;
    if not AddNamedColumn(Start, Header) then
      FailWithUsageHint('unknown user-defined format specifier "%s"', [ArgumentText(Start)]);
    if Ending <> #0 then
      Inc(Position);
  end;
end;

procedure ParseNumberList(List: PChar);
var
  Position: PChar;
  Value: Int64;
begin
  Position := List;
  while Position^ <> #0 do
  begin
    Value := 0;
    if not (Position^ in ['0'..'9']) then
      FailWithUsageHint('process ID list syntax error', []);
    while Position^ in ['0'..'9'] do
    begin
      Value := Value * 10 + Ord(Position^) - Ord('0');
      Inc(Position);
    end;
    if SelectedPidCount < MaximumSelected then
    begin
      SelectedPids[SelectedPidCount] := Value;
      Inc(SelectedPidCount);
    end;
    while Position^ in [',', ' '] do
      Inc(Position);
  end;
end;

procedure ParseUserList(List: PChar);
var
  Copy: PChar;
  Start: PChar;
  Position: PChar;
  Last: Boolean;
  UserId: LongWord;
begin
  Copy := DuplicateText(List);
  Position := Copy;
  repeat
    Start := Position;
    while not (Position^ in [#0, ',']) do
      Inc(Position);
    Last := Position^ = #0;
    Position^ := #0;
    if Start^ <> #0 then
    begin
      if not FindUserId(Start, UserId) then
        Fail(1, 'user name does not exist: %s', [ArgumentText(Start)]);
      if SelectedUserCount < MaximumSelected then
      begin
        SelectedUsers[SelectedUserCount] := UserId;
        Inc(SelectedUserCount);
      end;
    end;
    if not Last then
      Inc(Position);
  until Last;
end;

function IsSelected(const Information: TAbiProcessInformation): Boolean;
var
  Index: Integer;
begin
  if SelectAll then
    Exit(True);
  if (SelectedPidCount = 0) and (SelectedUserCount = 0) then
    Exit(Information.EffectiveUserId = CurrentUserId);
  for Index := 0 to SelectedPidCount - 1 do
    if Int64(Information.ProcessId) = SelectedPids[Index] then
      Exit(True);
  for Index := 0 to SelectedUserCount - 1 do
    if Information.EffectiveUserId = SelectedUsers[Index] then
      Exit(True);
  Result := False;
end;

function StateLetter(const Information: TAbiProcessInformation): Char;
begin
  case Information.State of
    ProcessStateRunning: Result := 'R';
    ProcessStateExiting: Result := 'Z';
  else
    Result := 'S';
  end;
end;

procedure FormatDuration(Seconds: QWord; WithDays: Boolean; var Builder: TTextBuilder);
var
  Days: QWord;
begin
  Days := Seconds div 86400;
  Seconds := Seconds mod 86400;
  if WithDays and (Days > 0) then
    AppendFormatted(Builder, '%d-%02d:%02d:%02d', [ArgumentUnsigned(Days),
      ArgumentUnsigned(Seconds div 3600), ArgumentUnsigned((Seconds div 60) mod 60), ArgumentUnsigned(Seconds mod 60)])
  else
    AppendFormatted(Builder, '%02d:%02d:%02d', [ArgumentUnsigned(Days * 24 + Seconds div 3600),
      ArgumentUnsigned((Seconds div 60) mod 60), ArgumentUnsigned(Seconds mod 60)]);
end;

procedure AppendUser(var Builder: TTextBuilder; Id: LongWord);
begin
  if UserNameOf(Id) <> nil then
    AppendText(Builder, UserNameOf(Id))
  else
    AppendFormatted(Builder, '%u', [ArgumentUnsigned(Id)]);
end;

procedure FormatCell(Kind: TColumnKind; const Information: TAbiProcessInformation; var Builder: TTextBuilder);
var
  Elapsed: Int64;
  Tenths: QWord;
  Start: TDateTime;
begin
  case Kind of
    ColumnPid: AppendFormatted(Builder, '%u', [ArgumentUnsigned(Information.ProcessId)]);
    ColumnParent: AppendFormatted(Builder, '%u', [ArgumentUnsigned(Information.ParentProcessId)]);
    ColumnGroup: AppendFormatted(Builder, '%u', [ArgumentUnsigned(Information.GroupId)]);
    ColumnUid: AppendFormatted(Builder, '%u', [ArgumentUnsigned(Information.EffectiveUserId)]);
    ColumnRealUid: AppendFormatted(Builder, '%u', [ArgumentUnsigned(Information.RealUserId)]);
    ColumnUser: AppendUser(Builder, Information.EffectiveUserId);
    ColumnRealUser: AppendUser(Builder, Information.RealUserId);
    ColumnNice: AppendFormatted(Builder, '%d', [ArgumentNumber(Information.Nice)]);
    ColumnPriority: AppendFormatted(Builder, '%d', [ArgumentNumber(20 + Information.Nice)]);
    ColumnState:
      begin
        AppendFormatted(Builder, '%c', [ArgumentCharacter(StateLetter(Information))]);
        if Information.Nice < 0 then
          AppendText(Builder, '<')
        else if Information.Nice > 0 then
          AppendText(Builder, 'N');
      end;
    ColumnThreads: AppendFormatted(Builder, '%u', [ArgumentUnsigned(Information.ThreadCount)]);
    ColumnVirtual, ColumnResident:
      AppendFormatted(Builder, '%u', [ArgumentUnsigned(Information.MemoryPages * PageKiB)]);
    ColumnCpuPercent, ColumnCpu:
      begin
        Elapsed := (Now - Information.StartTime) * 1000;
        if Elapsed <= 0 then
          Elapsed := 1000;
        Tenths := Information.CpuMilliseconds * 1000 div QWord(Elapsed);
        if Kind = ColumnCpu then
          AppendFormatted(Builder, '%u', [ArgumentUnsigned(Tenths div 10)])
        else
          AppendFormatted(Builder, '%u.%u', [ArgumentUnsigned(Tenths div 10), ArgumentUnsigned(Tenths mod 10)]);
      end;
    ColumnMemoryPercent:
      begin
        Tenths := 0;
        if TotalMemory > 0 then
          Tenths := Information.MemoryPages * 4096 * 1000 div TotalMemory;
        AppendFormatted(Builder, '%u.%u', [ArgumentUnsigned(Tenths div 10), ArgumentUnsigned(Tenths mod 10)]);
      end;
    ColumnTime: FormatDuration(Information.CpuMilliseconds div 1000, True, Builder);
    ColumnElapsed:
      begin
        Elapsed := Now - Information.StartTime;
        if Elapsed < 0 then
          Elapsed := 0;
        if Elapsed < 3600 then
          AppendFormatted(Builder, '%02d:%02d', [ArgumentNumber(Elapsed div 60), ArgumentNumber(Elapsed mod 60)])
        else
          FormatDuration(QWord(Elapsed), True, Builder);
      end;
    ColumnStart:
      begin
        DecodeTime(Information.StartTime, Start);
        AppendFormatted(Builder, '%02d:%02d', [ArgumentNumber(Start.Hour), ArgumentNumber(Start.Minute)]);
      end;
    ColumnTerminal: AppendText(Builder, 'console');
    ColumnCommand: AppendText(Builder, @Information.Name[0]);
  end;
end;

procedure WritePadded(Text: PChar; const Column: TColumn; IsLast: Boolean);
var
  Padding: Integer;
begin
  Padding := Column.Width - Integer(TextLength(Text));
  if not Column.LeftAligned then
    while Padding > 0 do
    begin
      WriteCharacter(StandardOutput, ' ');
      Dec(Padding);
    end;
  WriteText(StandardOutput, Text);
  if Column.LeftAligned and not IsLast then
    while Padding > 0 do
    begin
      WriteCharacter(StandardOutput, ' ');
      Dec(Padding);
    end;
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  FullFormat: Boolean;
  BsdStyle: Boolean;
  HeaderText: Boolean;
  Column: Integer;
  ListIndex: QWord;
  Information: TAbiProcessInformation;
  SystemInformation: TAbiSystemInformation;
  Builder: TTextBuilder;
begin
  ShowHeaders := True;
  FullFormat := False;
  BsdStyle := False;
  { BSD style options come without a dash: "ps aux", "ps ax". }
  if (ArgumentTotal > 1) and (Argument(1)[0] in ['a', 'x', 'u']) then
  begin
    BsdStyle := True;
    SelectAll := True;
  end
  else
  begin
    BeginOptions(Parser, [
      OptionDefinition('A', nil, False, OptionAll),
      OptionDefinition('e', nil, False, OptionAll),
      OptionDefinition('f', nil, False, OptionFull),
      OptionDefinition('o', 'format', True, OptionFormat),
      OptionDefinition('p', 'pid', True, OptionPid),
      OptionDefinition('u', 'user', True, OptionUser),
      OptionDefinition(#0, 'no-headers', False, OptionNoHeaders)], Usage);
    while NextOption(Parser, Code, Value) do
      case Code of
        OptionAll: SelectAll := True;
        OptionFull: FullFormat := True;
        OptionFormat: ParseFormat(Value);
        OptionPid: ParseNumberList(Value);
        OptionUser: ParseUserList(Value);
        OptionNoHeaders: ShowHeaders := False;
      end;
    if Parser.OperandCount > 0 then
      FailWithUsageHint('garbage option ''%s''', [ArgumentText(Parser.Operands[0])]);
  end;

  if ColumnCount = 0 then
  begin
    { A header after "=" runs to the end of its list, so renamed
      columns go in lists of their own. }
    if BsdStyle then
    begin
      ParseFormat('user,pid,%cpu,%mem,vsz,rss,tty,stat,start,time');
      ParseFormat('args=COMMAND');
    end
    else if FullFormat then
    begin
      ParseFormat('user=UID');
      ParseFormat('pid,ppid,c,stime,tty,time');
      ParseFormat('args=CMD');
    end
    else
      ParseFormat('pid,tty,time,cmd');
  end;

  Now := CurrentTime;
  if KernelGetSystemInformation(SystemInformation) >= 0 then
    TotalMemory := SystemInformation.TotalMemory;

  { "-o comm=" and the like: no header line at all. }
  HeaderText := False;
  for Column := 0 to ColumnCount - 1 do
    if Columns[Column].Header^ <> #0 then
      HeaderText := True;
  if ShowHeaders and HeaderText then
  begin
    for Column := 0 to ColumnCount - 1 do
    begin
      if Column > 0 then
        WriteCharacter(StandardOutput, ' ');
      WritePadded(Columns[Column].Header, Columns[Column], Column = ColumnCount - 1);
    end;
    WriteCharacter(StandardOutput, #10);
  end;

  ListIndex := 0;
  while KernelListProcesses(ListIndex, Information) >= 0 do
  begin
    Inc(ListIndex);
    if ListIndex > MaximumProcesses then
      Break;
    if not IsSelected(Information) then
      Continue;
    for Column := 0 to ColumnCount - 1 do
    begin
      if Column > 0 then
        WriteCharacter(StandardOutput, ' ');
      BeginText(Builder);
      FormatCell(Columns[Column].Kind, Information, Builder);
      WritePadded(Builder.Text, Columns[Column], Column = ColumnCount - 1);
      DiscardText(Builder);
    end;
    WriteCharacter(StandardOutput, #10);
  end;
end.
