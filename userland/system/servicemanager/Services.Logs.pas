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
  The logs.

  Every service that is not on the console writes its output (standard
  output and error) to LOGDIRECTORY/NAME.log (/var/log by default),
  added to the end, so earlier runs stay; the manager writes a line
  there before each start. The manager's own messages - a service
  started, ready, ended, started again, given up on, stopped - go to the
  console (the serial port and, while no display server has it, the
  screen) and to LOGDIRECTORY/servicemanager.log, each starting with the
  uptime in seconds.
}
unit Services.Logs;

{$mode objfpc}
{$H+}

interface

const
  DefaultLogDirectory = '/var/log';

var
  LogDirectory: string = DefaultLogDirectory;

{ Makes the log directory (and its parents) if it is missing. }
procedure PrepareLogDirectory;
{ The manager says what happened. }
procedure Say(const Text: string);
{ The log file of service Name, opened to add to (a handle), with a
  first line saying why; NoHandle if it cannot be opened. }
function OpenServiceLog(const Name, Heading: string): Int64;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Sys.Streams,
  Sys.Time;

const
  ManagerLogName = 'servicemanager';
  LogMode = OpenWrite or OpenCreate or OpenAppend;

var
  ManagerLog: Int64 = NoHandle;

procedure PrepareLogDirectory;
var
  Index: LongInt;
begin
  for Index := 2 to Length(LogDirectory) do
    if LogDirectory[Index] = '/' then
      CreateDirectory(PChar(Copy(LogDirectory, 1, Index - 1)));
  CreateDirectory(PChar(LogDirectory));
end;

function Stamp: string;
var
  Milliseconds: QWord;
begin
  Milliseconds := UptimeMilliseconds;
  Result := Format('[%5d.%.3d] ', [Milliseconds div 1000, Milliseconds mod 1000]);
end;

procedure WriteLineTo(Handle: Int64; const Text: string);
var
  Line: string;
begin
  Line := Text + #10;
  WriteAll(Handle, PChar(Line), Length(Line));
end;

procedure Say(const Text: string);
begin
  PrintStringLine('servicemanager: ' + Text);
  FlushStream(StandardOutput);
  if ManagerLog = NoHandle then
    ManagerLog := OpenFile(PChar(LogDirectory + '/' + ManagerLogName + '.log'), LogMode);
  if ManagerLog >= 0 then
    WriteLineTo(ManagerLog, Stamp + Text)
  else
    ManagerLog := NoHandle;
end;

function OpenServiceLog(const Name, Heading: string): Int64;
begin
  Result := OpenFile(PChar(LogDirectory + '/' + Name + '.log'), LogMode);
  if Result < 0 then
    Exit(NoHandle);
  WriteLineTo(Result, Stamp + '--- ' + Heading + ' ---');
end;

end.
