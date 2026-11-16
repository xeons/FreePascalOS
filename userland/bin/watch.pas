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
  watch - print the changes made to files and folders

  watch [-r] [-c] [-a] [-n COUNT] [-t MILLISECONDS] PATH...

  Watches each PATH (a folder or a file; /volumes for volumes arriving
  and going away) and prints every change as it comes, one line each:

    PATH: created: name (directory)
    PATH: renamed: old -> new
    PATH: written: name

  Names created, removed and renamed are always reported; -c adds files
  written, -a attribute changes, -r every folder below (names are then
  paths from PATH). Ends after COUNT changes (-n), after MILLISECONDS
  without a change (-t: status 2 if none came at all), or when every
  watch has ended (the item removed, its volume gone).
}
program watch;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Errors,
  Sys.FileWatches,
  Sys.Format,
  Sys.Objects,
  Sys.Streams,
  Sys.Text,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: watch [OPTION]... PATH...'#10 +
    'Print the changes made to each PATH (a folder or a file; /volumes for the volumes).'#10 +
    #10 +
    '  -r, --recursive        also watch every folder below'#10 +
    '  -c, --contents         also report files written'#10 +
    '  -a, --attributes       also report attribute changes'#10 +
    '  -n, --count=COUNT      end after COUNT changes'#10 +
    '  -t, --timeout=MS       end after MS milliseconds without a change'#10;

  OptionRecursive = 1;
  OptionContents = 2;
  OptionAttributes = 3;
  OptionCount = 4;
  OptionTimeout = 5;

  ExitNothingCame = 2;

var
  { One watch per path, at the same index. }
  Watches: array of Int64;
  Paths: array of string;
  ChangesWanted: QWord;
  ChangesSeen: QWord;
  Timeout: Int64;
  EndedCount: Integer;

procedure ParseNumberOption(Value: PChar; out Number: QWord);
begin
  if not ParseUnsigned(Value, Number) then
    FailWithUsageHint('invalid number: ''%s''', [ArgumentText(Value)]);
end;

procedure PrintChange(const Path: string; const Change: TFileChange);
var
  Line: string;
begin
  Line := Path + ': ' + string(FileChangeKindText(Change.Kind));
  if Change.Kind = FileChangeRenamed then
    Line := Line + ': ' + string(Change.OldName) + ' -> ' + string(Change.Name)
  else if (Change.Name <> nil) and (Change.Name^ <> #0) then
    Line := Line + ': ' + string(Change.Name);
  if Change.IsDirectory and (Change.Kind <> FileChangeOverflow) then
    Line := Line + ' (directory)';
  WriteLine(StandardOutput, PChar(Line));
  FlushStream(StandardOutput);
end;

{ Prints what waits in watch Index. }
procedure PrintChanges(Index: Integer);
var
  Reader: TFileChangeReader;
  Change: TFileChange;
begin
  if ReadFileChanges(Reader, Watches[Index]) <> ErrorNone then
    Exit;
  while NextFileChange(Reader, Change) do
  begin
    PrintChange(Paths[Index], Change);
    Inc(ChangesSeen);
    if (Change.Kind = FileChangeWatchedItemRemoved) or (Change.Kind = FileChangeVolumeGone) then
      Inc(EndedCount);
    if (ChangesWanted > 0) and (ChangesSeen >= ChangesWanted) then
      Exit;
  end;
end;

var
  Parser: TOptionParser;
  Code: Integer;
  Value: PChar;
  Flags: LongWord;
  Number: QWord;
  Index: Integer;
  Handle: Int64;
  Ready: Int64;
begin
  Flags := WatchNames;
  ChangesWanted := 0;
  Timeout := InfiniteWait;
  BeginOptions(Parser, [
    OptionDefinition('r', 'recursive', False, OptionRecursive),
    OptionDefinition('c', 'contents', False, OptionContents),
    OptionDefinition('a', 'attributes', False, OptionAttributes),
    OptionDefinition('n', 'count', True, OptionCount),
    OptionDefinition('t', 'timeout', True, OptionTimeout)], Usage);
  while NextOption(Parser, Code, Value) do
    case Code of
      OptionRecursive: Flags := Flags or WatchSubtree;
      OptionContents: Flags := Flags or WatchContents;
      OptionAttributes: Flags := Flags or WatchAttributes;
      OptionCount: ParseNumberOption(Value, ChangesWanted);
      OptionTimeout:
        begin
          ParseNumberOption(Value, Number);
          Timeout := Int64(Number);
        end;
    end;
  if Parser.OperandCount = 0 then
    FailWithUsageHint('missing operand', []);
  { The kernel waits on at most this many handles at once. }
  if Parser.OperandCount > MaximumWaitHandles then
    Fail(1, 'too many paths', []);

  SetLength(Watches, Parser.OperandCount);
  SetLength(Paths, Parser.OperandCount);
  for Index := 0 to Parser.OperandCount - 1 do
  begin
    Handle := WatchPath(Parser.Operands[Index], Flags);
    if Handle < 0 then
      FailWithError(1, ErrorCodeOf(Handle), '%s', [ArgumentText(Parser.Operands[Index])]);
    Watches[Index] := Handle;
    Paths[Index] := Parser.Operands[Index];
  end;

  ChangesSeen := 0;
  EndedCount := 0;
  while EndedCount < Length(Watches) do
  begin
    Ready := WaitForHandles(Watches, Timeout);
    if Ready = -ErrorTimedOut then
      Break;
    if Ready < 0 then
      Fail(1, 'waiting failed: %s', [ArgumentText(ErrorMessage(ErrorCodeOf(Ready)))]);
    PrintChanges(Integer(Ready));
    if (ChangesWanted > 0) and (ChangesSeen >= ChangesWanted) then
      Break;
  end;

  for Handle in Watches do
    CloseHandle(Handle);
  if ChangesSeen = 0 then
    Halt(ExitNothingCame);
end.
