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
  Reading and writing the account files (/etc/passwd, /etc/group,
  /etc/shadow) as lines of colon separated fields.

  A file is changed by writing all of it anew to PATH.new, whose mode is
  set before any text goes in (so /etc/shadow's hashes are never
  readable by others), and renaming that over the file: anyone reading
  sees the old file or the new one, never half of one, and a crash
  leaves one or the other (see "Writing safely" under Settings in the
  architecture notes). The files belong to root, who alone may write
  them. Two programs editing accounts at once (useradd and the system
  settings service) take turns: whoever edits holds an exclusive lock
  on /etc (LockAccountFiles), which only root can open for that.

  Lines that are not accounts (comments, blank lines) are kept as they
  are.
}
unit Util.AccountFiles;

{$mode objfpc}
{$H+}

interface

const
  ShadowFilePath = '/etc/shadow';
  AccountFolder = '/etc';
  { The modes the files keep: the passwords' file is root's alone. }
  PublicAccountFileMode = $1A4;  { rw-r--r-- }
  ShadowFileMode = $180;         { rw------- }

type
  TAccountLines = array of string;
  TAccountFields = array of string;

{ Every line of Path (without the line ends); an error code. }
function ReadAccountFile(const Path: string; out Lines: TAccountLines): LongInt;
{ Replaces Path with Lines, each ended by a line feed, the new file
  given Mode; an error code. }
function WriteAccountFile(const Path: string; const Lines: TAccountLines; Mode: LongWord): LongInt;

{ The fields of a line, split at every colon. }
function SplitAccountLine(const Line: string): TAccountFields;
function JoinAccountFields(const Fields: TAccountFields): string;
{ The index of the line whose first field is Name; -1 if none. }
function FindAccountLine(const Lines: TAccountLines; const Name: string): Integer;
procedure AppendAccountLine(var Lines: TAccountLines; const Line: string);
procedure DeleteAccountLine(var Lines: TAccountLines; Index: Integer);

{ The lock every editor of the account files holds while it reads and
  writes them; a handle to give back with UnlockAccountFiles, or minus
  an error. }
function LockAccountFiles: Int64;
procedure UnlockAccountFiles(Handle: Int64);

implementation

uses
  Abi.SystemCalls,
  Sys.Files,
  Util.Accounts;

const
  NewFileSuffix = '.new';
  ReadChunkBytes = 4096;

function ReadAccountFile(const Path: string; out Lines: TAccountLines): LongInt;
var
  Handle: Int64;
  Text: string;
  Piece: string;
  Chunk: array[0..ReadChunkBytes - 1] of Char;
  Count: Int64;
  Start: Integer;
  Position: Integer;
begin
  Lines := nil;
  Handle := OpenFile(PChar(Path), OpenRead);
  if Handle < 0 then
    Exit(LongInt(-Handle));
  Text := '';
  repeat
    Count := ReadFile(Handle, @Chunk[0], ReadChunkBytes);
    if Count > 0 then
    begin
      SetString(Piece, PChar(@Chunk[0]), Count);
      Text := Text + Piece;
    end;
  until Count <= 0;
  CloseFile(Handle);
  if Count < 0 then
    Exit(LongInt(-Count));
  Start := 1;
  for Position := 1 to Length(Text) do
    if Text[Position] = #10 then
    begin
      AppendAccountLine(Lines, Copy(Text, Start, Position - Start));
      Start := Position + 1;
    end;
  if Start <= Length(Text) then
    AppendAccountLine(Lines, Copy(Text, Start, Length(Text) - Start + 1));
  Result := ErrorNone;
end;

function WriteAccountFile(const Path: string; const Lines: TAccountLines; Mode: LongWord): LongInt;
var
  NewPath: string;
  Text: string;
  Index: Integer;
  Handle: Int64;
begin
  NewPath := Path + NewFileSuffix;
  Text := '';
  for Index := 0 to High(Lines) do
    Text := Text + Lines[Index] + #10;
  Handle := OpenFile(PChar(NewPath), OpenWrite or OpenCreate or OpenTruncate);
  if Handle < 0 then
    Exit(LongInt(-Handle));
  Result := ChangeMode(PChar(NewPath), Mode);
  if (Result = ErrorNone) and (Text <> '') then
    Result := WriteAll(Handle, @Text[1], Length(Text));
  CloseFile(Handle);
  if Result = ErrorNone then
    Result := RenamePath(PChar(NewPath), PChar(Path));
  if Result <> ErrorNone then
    RemovePath(PChar(NewPath));
  { Util.Accounts reads the new files at its next question. }
  RecheckAccountFiles;
end;

function SplitAccountLine(const Line: string): TAccountFields;
var
  Start: Integer;
  Position: Integer;
begin
  Result := nil;
  Start := 1;
  for Position := 1 to Length(Line) do
    if Line[Position] = ':' then
    begin
      SetLength(Result, Length(Result) + 1);
      Result[High(Result)] := Copy(Line, Start, Position - Start);
      Start := Position + 1;
    end;
  SetLength(Result, Length(Result) + 1);
  Result[High(Result)] := Copy(Line, Start, Length(Line) - Start + 1);
end;

function JoinAccountFields(const Fields: TAccountFields): string;
var
  Index: Integer;
begin
  Result := '';
  for Index := 0 to High(Fields) do
  begin
    if Index > 0 then
      Result := Result + ':';
    Result := Result + Fields[Index];
  end;
end;

function FindAccountLine(const Lines: TAccountLines; const Name: string): Integer;
var
  Index: Integer;
  Prefix: string;
begin
  Prefix := Name + ':';
  for Index := 0 to High(Lines) do
    if Copy(Lines[Index], 1, Length(Prefix)) = Prefix then
      Exit(Index);
  Result := -1;
end;

procedure AppendAccountLine(var Lines: TAccountLines; const Line: string);
begin
  SetLength(Lines, Length(Lines) + 1);
  Lines[High(Lines)] := Line;
end;

procedure DeleteAccountLine(var Lines: TAccountLines; Index: Integer);
var
  Position: Integer;
begin
  if (Index < 0) or (Index > High(Lines)) then
    Exit;
  for Position := Index to High(Lines) - 1 do
    Lines[Position] := Lines[Position + 1];
  SetLength(Lines, Length(Lines) - 1);
end;

function LockAccountFiles: Int64;
var
  Error: LongInt;
begin
  Result := OpenFile(AccountFolder, OpenRead);
  if Result < 0 then
    Exit;
  Error := LockFile(Result, FileLockExclusive);
  if Error <> ErrorNone then
  begin
    CloseFile(Result);
    Result := -Int64(Error);
  end;
end;

procedure UnlockAccountFiles(Handle: Int64);
begin
  if Handle >= 0 then
    CloseFile(Handle);
end;

end.
