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
  Redirections and the shell's standard handles.

  A command's redirections are applied to the three standard handles it
  is to get (TStandardHandles); a program is started with them, and for
  builtins and compound commands the shell temporarily points its own
  handles 0-2 at them (SwitchStandardHandles).

  Here-documents reach the command through a pipe, or through a
  temporary file when they are larger than a pipe holds; the files are
  removed when the pipeline that used them has ended.
}
unit Shell.Redirections;

{$mode objfpc}
{$H+}

interface

uses
  Shell.Nodes;

type
  TStandardHandles = array[0..2] of Int64;
  { Files opened for the redirections of one command. }
  TOpenedHandles = array of Int64;

{ Points the shell's handles 0-2 at Handles, remembering the old ones. }
procedure SwitchStandardHandles(const Handles: TStandardHandles; out Saved: TStandardHandles);
procedure RestoreStandardHandles(const Saved: TStandardHandles);

{ Applies Redirections on top of Handles. Files opened here are added
  to Opened so they can be closed later. Returns False (after
  reporting) when a file cannot be opened. }
function ApplyRedirections(const Redirections: TRedirectionArray; var Handles: TStandardHandles;
  var Opened: TOpenedHandles): Boolean;
procedure CloseOpenedHandles(var Opened: TOpenedHandles);

{ Removes the here-document files of the pipeline that has ended. }
procedure RemoveTemporaryFiles;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Files,
  Sys.Processes,
  Sys.Streams,
  Shell.Lexer,
  Shell.Text,
  Shell.Output,
  Shell.Variables,
  Shell.Expansion;

const
  { A here-document up to this size goes through a pipe (which holds
    4 KiB), a larger one through a temporary file. }
  HereDocumentPipeLimit = 4000;

var
  TemporaryFiles: array of string;
  TemporaryFileNumber: Integer = 0;

{ --- Standard handle switching ----------------------------------------- }

procedure SwitchStandardHandles(const Handles: TStandardHandles; out Saved: TStandardHandles);
var
  Index: Integer;
begin
  FlushStandardStreams;
  for Index := 0 to 2 do
  begin
    Saved[Index] := NoHandle;
    if Handles[Index] <> Index then
    begin
      Saved[Index] := DuplicateHandle(Index, NoHandle);
      DuplicateHandle(Handles[Index], Index);
    end;
  end;
end;

procedure RestoreStandardHandles(const Saved: TStandardHandles);
var
  Index: Integer;
begin
  FlushStandardStreams;
  for Index := 0 to 2 do
    if Saved[Index] >= 0 then
    begin
      DuplicateHandle(Saved[Index], Index);
      CloseFile(Saved[Index]);
    end;
end;

{ --- Here-documents ---------------------------------------------------- }

procedure AddOpenedHandle(var Opened: TOpenedHandles; Handle: Int64);
var
  Count: Integer;
begin
  Count := Length(Opened);
  SetLength(Opened, Count + 1);
  Opened[Count] := Handle;
end;

procedure CloseOpenedHandles(var Opened: TOpenedHandles);
var
  Index: Integer;
begin
  for Index := 0 to High(Opened) do
    CloseFile(Opened[Index]);
  Opened := nil;
end;

procedure RemoveTemporaryFiles;
var
  Index: Integer;
begin
  for Index := 0 to High(TemporaryFiles) do
    RemovePath(PChar(TemporaryFiles[Index]));
  TemporaryFiles := nil;
end;

function OpenHereDocumentPipe(const Body: string): Int64;
var
  ReadHandle: Int64;
  WriteHandle: Int64;
begin
  if CreatePipe(ReadHandle, WriteHandle) <> ErrorNone then
  begin
    ShellError('cannot create a pipe for a here-document');
    Exit(-1);
  end;
  WriteAll(WriteHandle, PChar(Body), Length(Body));
  CloseFile(WriteHandle);
  Result := ReadHandle;
end;

function OpenHereDocumentFile(const Body: string): Int64;
var
  Directory: string;
  Path: string;
  WriteHandle: Int64;
  Count: Integer;
begin
  Directory := VariableValue('TMPDIR');
  if Directory = '' then
    Directory := '/tmp';
  Inc(TemporaryFileNumber);
  Path := Directory + '/sh-here-' + IntToStr(CurrentProcessId) + '-' + IntToStr(TemporaryFileNumber);
  WriteHandle := OpenFile(PChar(Path), OpenWrite or OpenCreate or OpenTruncate);
  if WriteHandle < 0 then
  begin
    ShellError('cannot create a file for a here-document: ' + ErrorMessage(ErrorCodeOf(WriteHandle)));
    Exit(-1);
  end;
  WriteAll(WriteHandle, PChar(Body), Length(Body));
  CloseFile(WriteHandle);
  Result := OpenFile(PChar(Path), OpenRead);
  Count := Length(TemporaryFiles);
  SetLength(TemporaryFiles, Count + 1);
  TemporaryFiles[Count] := Path;
end;

{ A handle from which the command reads the here-document's text. }
function OpenHereDocument(const Redirection: TRedirection): Int64;
var
  Body: string;
begin
  if Redirection.HereIsQuoted then
    Body := Redirection.HereBody
  else
    Body := ExpandHereDocument(Redirection.HereBody);
  if Length(Body) <= HereDocumentPipeLimit then
    Result := OpenHereDocumentPipe(Body)
  else
    Result := OpenHereDocumentFile(Body);
end;

{ --- Redirections ------------------------------------------------------ }

function OpenFlagsFor(Kind: TRedirectKind): LongWord;
begin
  case Kind of
    RedirectInput: Result := OpenRead;
    RedirectOutput: Result := OpenWrite or OpenCreate or OpenTruncate;
  else
    Result := OpenWrite or OpenCreate or OpenAppend;
  end;
end;

function ApplyRedirections(const Redirections: TRedirectionArray; var Handles: TStandardHandles;
  var Opened: TOpenedHandles): Boolean;
var
  Index: Integer;
  Redirection: TRedirection;
  Target: string;
  Handle: Int64;
  SourceNumber: Int64;
begin
  Result := True;
  for Index := 0 to High(Redirections) do
  begin
    Redirection := Redirections[Index];
    if (Redirection.Handle < 0) or (Redirection.Handle > 2) then
    begin
      ShellError('only handles 0, 1 and 2 can be redirected');
      Exit(False);
    end;
    if Redirection.Kind = RedirectHereDocument then
    begin
      Handle := OpenHereDocument(Redirection);
      if Handle < 0 then
        Exit(False);
      Handles[Redirection.Handle] := Handle;
      AddOpenedHandle(Opened, Handle);
      Continue;
    end;
    Target := ExpandToText(Redirection.Target);

    if Redirection.Kind = RedirectDuplicate then
    begin
      if not TryParseInteger(Target, SourceNumber) or (SourceNumber < 0) or (SourceNumber > 2) then
      begin
        ShellError(Target + ': bad redirection');
        Exit(False);
      end;
      Handles[Redirection.Handle] := Handles[SourceNumber];
      Continue;
    end;

    Handle := OpenFile(PChar(Target), OpenFlagsFor(Redirection.Kind));
    if Handle < 0 then
    begin
      ShellError(Target + ': ' + ErrorMessage(ErrorCodeOf(Handle)));
      Exit(False);
    end;
    Handles[Redirection.Handle] := Handle;
    AddOpenedHandle(Opened, Handle);
  end;
end;

end.
