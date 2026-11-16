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
  Lists of files as text: how files cut or copied wait on the clipboard
  (which holds text), and what a drag of files carries
  (DragFormatFileList), so any program can read them.

  The format, lines ending in line feeds (a carriage return before one
  is ignored when reading):

    file-list copy
    file:///home/user/notes.txt
    file:///home/user/My%20Pictures

  The first line says it is a file list and what pasting it should do:
  "copy", or "cut" (move the files, once pasted). Each line after it is
  one file as a file URI (RFC 8089): "file://", then the absolute path
  with every byte other than the letters, digits, "-", ".", "_", "~"
  and "/" written as "%" and two hexadecimal digits (a space is %20, a
  line feed in a name %0A, UTF-8 characters byte by byte). Reading also
  takes a plain absolute path on a line ("/home/user/notes.txt"), as a
  person might paste, and skips empty lines.

  Text that does not start with the header is not a file list, so
  pasting ordinary text into a folder does nothing.
}
unit Controls.FileLists;

{$mode objfpc}
{$H+}

interface

uses
  Classes;

const
  FileListHeader = 'file-list';

type
  TFileListAction = (FileListCopy, FileListCut);

{ The text of a file list. }
function EncodeFileList(Action: TFileListAction; Paths: TStrings): string;
{ Reads a file list: False (and no paths) if Text is not one. }
function DecodeFileList(const Text: string; out Action: TFileListAction; Paths: TStrings): Boolean;
{ An absolute path as a file URI, and back (False if Uri is not a file
  URI of an absolute path, or has a broken escape). }
function PathToFileUri(const Path: string): string;
function FileUriToPath(const Uri: string; out Path: string): Boolean;

{ Puts a file list on the clipboard, and reads one from it. }
procedure SetClipboardFileList(Action: TFileListAction; Paths: TStrings);
function ClipboardFileList(out Action: TFileListAction; Paths: TStrings): Boolean;
function ClipboardHoldsFileList: Boolean;

implementation

uses
  SysUtils,
  Controls.Clipboard;

const
  UriPrefix = 'file://';
  ActionWords: array[TFileListAction] of string = ('copy', 'cut');
  { Bytes written as they are in a file URI's path. }
  PlainCharacters = ['A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~', '/'];

function PathToFileUri(const Path: string): string;
var
  Index: LongInt;
begin
  Result := UriPrefix;
  for Index := 1 to Length(Path) do
    if Path[Index] in PlainCharacters then
      Result := Result + Path[Index]
    else
      Result := Result + '%' + IntToHex(Ord(Path[Index]), 2);
end;

{ The value of a hexadecimal digit, or -1. }
function DigitValue(Character: Char): LongInt;
begin
  case Character of
    '0'..'9': Result := Ord(Character) - Ord('0');
    'A'..'F': Result := Ord(Character) - Ord('A') + 10;
    'a'..'f': Result := Ord(Character) - Ord('a') + 10;
  else
    Result := -1;
  end;
end;

function FileUriToPath(const Uri: string; out Path: string): Boolean;
var
  Index: LongInt;
  HighDigit: LongInt;
  LowDigit: LongInt;
begin
  Path := '';
  if Copy(Uri, 1, Length(UriPrefix)) <> UriPrefix then
    Exit(False);
  Index := Length(UriPrefix) + 1;
  { "file:///path": an empty host, then the absolute path. }
  if (Index > Length(Uri)) or (Uri[Index] <> '/') then
    Exit(False);
  while Index <= Length(Uri) do
  begin
    if Uri[Index] = '%' then
    begin
      if Index + 2 > Length(Uri) then
        Exit(False);
      HighDigit := DigitValue(Uri[Index + 1]);
      LowDigit := DigitValue(Uri[Index + 2]);
      if (HighDigit < 0) or (LowDigit < 0) then
        Exit(False);
      Path := Path + Chr(HighDigit * 16 + LowDigit);
      Index := Index + 3;
    end
    else
    begin
      Path := Path + Uri[Index];
      Inc(Index);
    end;
  end;
  Result := True;
end;

function EncodeFileList(Action: TFileListAction; Paths: TStrings): string;
var
  Index: LongInt;
begin
  Result := FileListHeader + ' ' + ActionWords[Action] + #10;
  for Index := 0 to Paths.Count - 1 do
    Result := Result + PathToFileUri(Paths[Index]) + #10;
end;

{ Text split at its line feeds, a carriage return before one dropped. }
procedure SplitLines(const Text: string; Lines: TStrings);
var
  Start: LongInt;
  Index: LongInt;
  Line: string;
begin
  Start := 1;
  for Index := 1 to Length(Text) + 1 do
    if (Index > Length(Text)) or (Text[Index] = #10) then
    begin
      Line := Copy(Text, Start, Index - Start);
      if (Line <> '') and (Line[Length(Line)] = #13) then
        SetLength(Line, Length(Line) - 1);
      if (Index <= Length(Text)) or (Line <> '') then
        Lines.Add(Line);
      Start := Index + 1;
    end;
end;

function DecodeFileList(const Text: string; out Action: TFileListAction; Paths: TStrings): Boolean;
var
  Lines: TStringList;
  Index: LongInt;
  Path: string;
begin
  Action := FileListCopy;
  Paths.Clear;
  Lines := TStringList.Create;
  try
    SplitLines(Text, Lines);
    if Lines.Count = 0 then
      Exit(False);
    if Lines[0] = FileListHeader + ' ' + ActionWords[FileListCut] then
      Action := FileListCut
    else if Lines[0] <> FileListHeader + ' ' + ActionWords[FileListCopy] then
      Exit(False);
    for Index := 1 to Lines.Count - 1 do
    begin
      if Lines[Index] = '' then
        Continue;
      if Lines[Index][1] = '/' then
        Paths.Add(Lines[Index])
      else if FileUriToPath(Lines[Index], Path) then
        Paths.Add(Path)
      else
      begin
        Paths.Clear;
        Exit(False);
      end;
    end;
    Result := True;
  finally
    Lines.Free;
  end;
end;

procedure SetClipboardFileList(Action: TFileListAction; Paths: TStrings);
begin
  SetClipboardText(EncodeFileList(Action, Paths));
end;

function ClipboardFileList(out Action: TFileListAction; Paths: TStrings): Boolean;
begin
  Result := DecodeFileList(ClipboardText, Action, Paths) and (Paths.Count > 0);
end;

function ClipboardHoldsFileList: Boolean;
begin
  Result := Copy(ClipboardText, 1, Length(FileListHeader) + 1) = FileListHeader + ' ';
end;

end.
