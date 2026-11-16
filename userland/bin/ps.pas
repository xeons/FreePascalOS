{
  FreePascalOS
  Copyright (C) 2026 Brandon Scott

  This program is free software: you can redistribute it and/or modify
  it under the terms of the GNU General Public License as published by
  the Free Software Foundation, either version 3 of the License, or
  (at your option) any later version.

  This program is distributed in the hope that it will be useful,
  but WITHOUT ANY WARRANTY; without even the implied warranty of
  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
  GNU General Public License for more details.

  You should have received a copy of the GNU General Public License
  along with this program.  If not, see <https://www.gnu.org/licenses/>.
}

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
  tty comm (ucomm), cmd (args, command).

  %cpu is the processor time over the time since the process started
  (100 is one processor kept busy all along), time the processor time
  so far, rss the memory it has, vsz the size of what it may touch.
  comm is the program's name, args its command line; another user's
  command line is root's to see only, so others get the name in
  brackets for it.
}
program ps;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Kernel,
  Sys.ProcessList,
  Sys.Streams,
  Sys.Time,
  Util.Accounts,
  Util.CommandLine,
  Util.Messages,
  Util.Output;

const
  Usage = 'Usage: ps [OPTION]...'#10 +
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

type
  TColumnKind = (ColumnPid, ColumnParent, ColumnGroup, ColumnUid, ColumnUser, ColumnRealUid,
    ColumnRealUser, ColumnNice, ColumnPriority, ColumnState, ColumnThreads, ColumnVirtual,
    ColumnResident, ColumnCpuPercent, ColumnMemoryPercent, ColumnTime, ColumnElapsed,
    ColumnStart, ColumnTerminal, ColumnCommand, ColumnArguments, ColumnCpu);

  TColumn = record
    Kind: TColumnKind;
    Header: string;
    Width: Integer;
    LeftAligned: Boolean;
  end;

  TColumnName = record
    Name: string;
    Kind: TColumnKind;
    Header: string;
    Width: Integer;
    LeftAligned: Boolean;
  end;

const
  ColumnNames: array[0..35] of TColumnName = (
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
    (Name: 'ucomm'; Kind: ColumnCommand; Header: 'COMMAND'; Width: 0; LeftAligned: True),
    (Name: 'cmd'; Kind: ColumnArguments; Header: 'CMD'; Width: 0; LeftAligned: True),
    (Name: 'args'; Kind: ColumnArguments; Header: 'COMMAND'; Width: 0; LeftAligned: True),
    (Name: 'command'; Kind: ColumnArguments; Header: 'COMMAND'; Width: 0; LeftAligned: True),
    (Name: 'c'; Kind: ColumnCpu; Header: 'C'; Width: 2; LeftAligned: False));

var
  Columns: array of TColumn;
  SelectAll: Boolean;
  SelectedPids: array of Int64;
  SelectedUsers: array of LongWord;
  ShowHeaders: Boolean;
  { Milliseconds since the system started. }
  Uptime: QWord;
  TotalMemory: QWord;

{ Adds the column called Name; Header replaces its usual header when
  HasHeader. }
function AddNamedColumn(const Name: string; HasHeader: Boolean; const Header: string): Boolean;
var
  Index: Integer;
  Column: TColumn;
begin
  for Index := Low(ColumnNames) to High(ColumnNames) do
    if ColumnNames[Index].Name = Name then
    begin
      Column.Kind := ColumnNames[Index].Kind;
      if HasHeader then
        Column.Header := Header
      else
        Column.Header := ColumnNames[Index].Header;
      Column.Width := ColumnNames[Index].Width;
      Column.LeftAligned := ColumnNames[Index].LeftAligned;
      Insert(Column, Columns, Length(Columns));
      Exit(True);
    end;
  Result := False;
end;

{ "pid,user=WHO comm" }
procedure ParseFormat(const List: string);
var
  Position: Integer;
  Start: Integer;
  Name: string;
  Header: string;
  HasHeader: Boolean;
begin
  Position := 1;
  while Position <= Length(List) do
  begin
    while (Position <= Length(List)) and (List[Position] in [',', ' ']) do
      Inc(Position);
    if Position > Length(List) then
      Break;
    Start := Position;
    HasHeader := False;
    Header := '';
    while (Position <= Length(List)) and not (List[Position] in [',', ' ']) do
    begin
      if List[Position] = '=' then
      begin
        { A header runs to the end of the list. }
        HasHeader := True;
        Header := Copy(List, Position + 1, MaxInt);
        Break;
      end;
      Inc(Position);
    end;
    Name := Copy(List, Start, Position - Start);
    if HasHeader then
      Position := Length(List) + 1;
    if not AddNamedColumn(Name, HasHeader, Header) then
      FailWithUsageHint(Format('unknown user-defined format specifier "%s"', [Name]));
    Inc(Position);
  end;
end;

procedure ParseNumberList(const List: string);
var
  Position: Integer;
  Value: Int64;
begin
  Position := 1;
  while Position <= Length(List) do
  begin
    Value := 0;
    if not (List[Position] in ['0'..'9']) then
      FailWithUsageHint('process ID list syntax error');
    while (Position <= Length(List)) and (List[Position] in ['0'..'9']) do
    begin
      Value := Value * 10 + Ord(List[Position]) - Ord('0');
      Inc(Position);
    end;
    Insert(Value, SelectedPids, Length(SelectedPids));
    while (Position <= Length(List)) and (List[Position] in [',', ' ']) do
      Inc(Position);
  end;
end;

procedure ParseUserList(const List: string);
var
  Names: TStringArray;
  Index: Integer;
  UserId: LongWord;
begin
  Names := List.Split([',']);
  for Index := 0 to High(Names) do
    if Names[Index] <> '' then
    begin
      if not FindUserId(Names[Index], UserId) then
        Fail(1, 'user name does not exist: ' + Names[Index]);
      Insert(UserId, SelectedUsers, Length(SelectedUsers));
    end;
end;

function IsSelected(const Information: TProcessDetails): Boolean;
var
  Index: Integer;
begin
  if SelectAll then
    Exit(True);
  if (Length(SelectedPids) = 0) and (Length(SelectedUsers) = 0) then
    Exit(Information.EffectiveUserId = CurrentUserId);
  for Index := 0 to High(SelectedPids) do
    if Int64(Information.ProcessId) = SelectedPids[Index] then
      Exit(True);
  for Index := 0 to High(SelectedUsers) do
    if Information.EffectiveUserId = SelectedUsers[Index] then
      Exit(True);
  Result := False;
end;

function StateLetter(const Information: TProcessDetails): Char;
begin
  case Information.State of
    ProcessStateRunning: Result := 'R';
    ProcessStateExiting: Result := 'Z';
    ProcessStateStopped: Result := 'T';
  else
    Result := 'S';
  end;
end;

function DurationText(Seconds: QWord; WithDays: Boolean): string;
var
  Days: QWord;
begin
  Days := Seconds div 86400;
  Seconds := Seconds mod 86400;
  if WithDays and (Days > 0) then
    Result := Format('%d-%.2d:%.2d:%.2d', [Days, Seconds div 3600, (Seconds div 60) mod 60, Seconds mod 60])
  else
    Result := Format('%.2d:%.2d:%.2d', [Days * 24 + Seconds div 3600, (Seconds div 60) mod 60, Seconds mod 60]);
end;

{ Milliseconds the process has run for. }
function ElapsedMilliseconds(const Information: TProcessDetails): QWord;
begin
  if Uptime > Information.StartUptimeMilliseconds then
    Result := Uptime - Information.StartUptimeMilliseconds
  else
    Result := 0;
end;

function ArgumentsText(const Information: TProcessDetails): string;
begin
  Result := PChar(@Information.CommandLine[0]);
  if Result = '' then
    Result := '[' + PChar(@Information.Name[0]) + ']';
end;

function TenthsText(Tenths: QWord): string;
begin
  Result := IntToStr(Tenths div 10) + '.' + IntToStr(Tenths mod 10);
end;

function CellText(Kind: TColumnKind; const Information: TProcessDetails): string;
var
  Elapsed: QWord;
  Tenths: QWord;
  Start: TDateTime;
begin
  Result := '';
  case Kind of
    ColumnPid: Result := IntToStr(Information.ProcessId);
    ColumnParent: Result := IntToStr(Information.ParentProcessId);
    ColumnGroup: Result := IntToStr(Information.GroupId);
    ColumnUid: Result := IntToStr(Information.EffectiveUserId);
    ColumnRealUid: Result := IntToStr(Information.RealUserId);
    ColumnUser: Result := UserNameOrNumber(Information.EffectiveUserId);
    ColumnRealUser: Result := UserNameOrNumber(Information.RealUserId);
    ColumnNice: Result := IntToStr(Information.Nice);
    ColumnPriority: Result := IntToStr(20 + Information.Nice);
    ColumnState:
      begin
        Result := StateLetter(Information);
        if Information.Nice < 0 then
          Result := Result + '<'
        else if Information.Nice > 0 then
          Result := Result + 'N';
      end;
    ColumnThreads: Result := IntToStr(Information.ThreadCount);
    ColumnVirtual: Result := IntToStr(Information.VirtualBytes div 1024);
    ColumnResident: Result := IntToStr(Information.ResidentBytes div 1024);
    ColumnCpuPercent, ColumnCpu:
      begin
        Tenths := ProcessorShareTenths(0, Information.ProcessorNanoseconds, ElapsedMilliseconds(Information), 1);
        if Kind = ColumnCpu then
          Result := IntToStr(Tenths div 10)
        else
          Result := TenthsText(Tenths);
      end;
    ColumnMemoryPercent:
      begin
        Tenths := 0;
        if TotalMemory > 0 then
          Tenths := Information.ResidentBytes * 1000 div TotalMemory;
        Result := TenthsText(Tenths);
      end;
    ColumnTime: Result := DurationText(Information.ProcessorNanoseconds div 1000000000, True);
    ColumnElapsed:
      begin
        Elapsed := ElapsedMilliseconds(Information) div 1000;
        if Elapsed < 3600 then
          Result := Format('%.2d:%.2d', [Elapsed div 60, Elapsed mod 60])
        else
          Result := DurationText(Elapsed, True);
      end;
    ColumnStart:
      begin
        DecodeTime(Information.StartTime, Start);
        Result := Format('%.2d:%.2d', [Start.Hour, Start.Minute]);
      end;
    ColumnTerminal:
      begin
        Result := PChar(@Information.Terminal[0]);
        if Result = '' then
          Result := '?';
      end;
    ColumnCommand: Result := PChar(@Information.Name[0]);
    ColumnArguments: Result := ArgumentsText(Information);
  end;
end;

procedure WritePadded(const Text: string; const Column: TColumn; IsLast: Boolean);
var
  Padding: string;
begin
  Padding := StringOfChar(' ', Column.Width - Length(Text));
  if not Column.LeftAligned then
    PrintString(Padding);
  PrintString(Text);
  if Column.LeftAligned and not IsLast then
    PrintString(Padding);
end;

procedure ReadOptions;
var
  CommandLine: TCommandLine;
  Arguments: TStringArray;
  Code: Integer;
  Value: string;
  FirstArgument: string;
  FullFormat: Boolean;
  BsdStyle: Boolean;
begin
  ShowHeaders := True;
  FullFormat := False;
  BsdStyle := False;
  FirstArgument := '';
  Arguments := ProgramArguments;
  if Length(Arguments) > 0 then
    FirstArgument := Arguments[0];
  { BSD style options come without a dash: "ps aux", "ps ax". }
  if (FirstArgument <> '') and (FirstArgument[1] in ['a', 'x', 'u']) then
  begin
    BsdStyle := True;
    SelectAll := True;
  end
  else
  begin
    CommandLine := TCommandLine.Create([
      CommandOption('A', '', False, OptionAll),
      CommandOption('e', '', False, OptionAll),
      CommandOption('f', '', False, OptionFull),
      CommandOption('o', 'format', True, OptionFormat),
      CommandOption('p', 'pid', True, OptionPid),
      CommandOption('u', 'user', True, OptionUser),
      CommandOption(#0, 'no-headers', False, OptionNoHeaders)], Usage, Arguments);
    while CommandLine.NextOption(Code, Value) do
      case Code of
        OptionAll: SelectAll := True;
        OptionFull: FullFormat := True;
        OptionFormat: ParseFormat(Value);
        OptionPid: ParseNumberList(Value);
        OptionUser: ParseUserList(Value);
        OptionNoHeaders: ShowHeaders := False;
      end;
    if CommandLine.OperandCount > 0 then
      FailWithUsageHint(Format('garbage option ''%s''', [CommandLine.Operands[0]]));
    CommandLine.Free;
  end;

  if Length(Columns) = 0 then
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
end;

procedure WriteHeaderLine;
var
  Column: Integer;
  HeaderText: Boolean;
begin
  { "-o comm=" and the like: no header line at all. }
  HeaderText := False;
  for Column := 0 to High(Columns) do
    if Columns[Column].Header <> '' then
      HeaderText := True;
  if not (ShowHeaders and HeaderText) then
    Exit;
  for Column := 0 to High(Columns) do
  begin
    if Column > 0 then
      WriteCharacter(StandardOutput, ' ');
    WritePadded(Columns[Column].Header, Columns[Column], Column = High(Columns));
  end;
  WriteCharacter(StandardOutput, #10);
end;

procedure WriteProcessLine(const Information: TProcessDetails);
var
  Column: Integer;
begin
  for Column := 0 to High(Columns) do
  begin
    if Column > 0 then
      WriteCharacter(StandardOutput, ' ');
    WritePadded(CellText(Columns[Column].Kind, Information), Columns[Column], Column = High(Columns));
  end;
  WriteCharacter(StandardOutput, #10);
end;

var
  ListIndex: LongInt;
  Snapshot: TProcessSnapshot;
  SystemInformation: TAbiSystemInformation;
begin
  ReadOptions;

  InitializeProcessSnapshot(Snapshot);
  if TakeProcessSnapshot(Snapshot) <> ErrorNone then
    Fail(1, 'cannot list the processes');
  Uptime := Snapshot.TakenAtMilliseconds;
  if KernelGetSystemInformation(SystemInformation) >= 0 then
    TotalMemory := SystemInformation.TotalMemory;

  WriteHeaderLine;
  for ListIndex := 0 to Snapshot.Count - 1 do
    if IsSelected(Snapshot.Entries[ListIndex]) then
      WriteProcessLine(Snapshot.Entries[ListIndex]);
end.
