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
  Diagnostics in the usual command line form:

    ls: cannot access 'missing': No such file or directory

  Every message starts with the program name (taken from argument 0
  without its directory). Messages are finished strings, made with
  SysUtils' Format where they need one:

    ReportError(Error, Format('cannot access ''%s''', [Path]));
}
unit Util.Messages;

{$mode objfpc}{$H+}

interface

{ Argument 0 without its directory ("program" if that leaves nothing). }
function ProgramName: string;
{ The text of an Abi error code ("No such file or directory"). }
function ErrorText(ErrorCode: LongInt): string;

{ "<program>: <message>" on standard error. }
procedure Report(const Message: string);
{ "<program>: <message>: <error text>" on standard error. }
procedure ReportError(ErrorCode: LongInt; const Message: string);
{ Report, then end the program with ExitStatus. }
procedure Fail(ExitStatus: LongInt; const Message: string);
procedure FailWithError(ExitStatus: LongInt; ErrorCode: LongInt; const Message: string);
{ "Try '<program> --help' for more information." and exit status 1. }
procedure FailWithUsageHint(const Message: string);

implementation

uses
  SysUtils,
  Sys.Environment,
  Sys.Errors,
  Sys.Streams;

function ProgramName: string;
var
  LastSlash: Integer;
begin
  Result := Argument(0);
  LastSlash := LastDelimiter('/', Result);
  if LastSlash > 0 then
    Delete(Result, 1, LastSlash);
  if Result = '' then
    Result := 'program';
end;

function ErrorText(ErrorCode: LongInt): string;
begin
  Result := ErrorMessage(ErrorCode);
end;

procedure WriteMessageText(const Message: string);
begin
  if Message <> '' then
    WriteBytes(StandardError, PChar(Message), Length(Message));
end;

procedure WriteMessageStart;
begin
  FlushStream(StandardOutput);
  WriteMessageText(ProgramName);
  WriteText(StandardError, ': ');
end;

procedure Report(const Message: string);
begin
  WriteMessageStart;
  WriteMessageText(Message);
  WriteCharacter(StandardError, #10);
end;

procedure ReportError(ErrorCode: LongInt; const Message: string);
begin
  WriteMessageStart;
  WriteMessageText(Message);
  WriteText(StandardError, ': ');
  WriteText(StandardError, ErrorMessage(ErrorCode));
  WriteCharacter(StandardError, #10);
end;

procedure Fail(ExitStatus: LongInt; const Message: string);
begin
  Report(Message);
  Halt(ExitStatus);
end;

procedure FailWithError(ExitStatus: LongInt; ErrorCode: LongInt; const Message: string);
begin
  ReportError(ErrorCode, Message);
  Halt(ExitStatus);
end;

procedure FailWithUsageHint(const Message: string);
begin
  Report(Message);
  WriteText(StandardError, 'Try ''');
  WriteMessageText(ProgramName);
  WriteText(StandardError, ''' --help'' for more information.'#10);
  Halt(1);
end;

end.
