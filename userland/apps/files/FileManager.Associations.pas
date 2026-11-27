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
  What opening an item does: the one place that decides, so it can grow
  (more programs, a user's choices) without the rest changing.

    a folder (or a link to one)          shown in the window
    a text document by its extension     opened in Notepad
    a file with an execute bit that is
      an ELF program or starts with #!   run
    a picture libimage reads (told by
      its first bytes)                   opened in the image viewer
    any other file whose first 4 KiB
      look like text                     opened in Notepad
    anything else                        nothing (the user is told)

  Text-looking means no zero byte and valid UTF-8 (an empty file is
  text). The extension is looked at before the execute bit, so a script
  named .sh opens to be read rather than running by surprise.
}
unit FileManager.Associations;

{$mode objfpc}
{$H+}

interface

uses
  FileManager.Items;

type
  TOpenAction = (OpenActionFolder, OpenActionProgram, OpenActionNotepad, OpenActionImageViewer, OpenActionNone);

function OpenActionFor(const Path: string; const Item: TFolderItem): TOpenAction;
{ Whether the start of the file at Path looks like text. }
function LooksLikeText(const Path: string): Boolean;
{ Whether the file at Path starts as a picture libimage reads does. }
function LooksLikeImage(const Path: string): Boolean;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Image.Codecs,
  Image.Files,
  FileManager.FileTypes,
  FileManager.Paths;

const
  SniffSize = 4096;

{ True if Bytes[0..Count-1] is valid UTF-8 without zero bytes; a
  character cut off at the end of what was read counts as valid. }
function IsTextBytes(const Bytes: array of Byte; Count: LongInt): Boolean;
var
  Index: LongInt;
  Following: LongInt;
  Value: Byte;
begin
  Index := 0;
  while Index < Count do
  begin
    Value := Bytes[Index];
    if Value = 0 then
      Exit(False);
    if Value < $80 then
      Following := 0
    else if (Value and $E0) = $C0 then
      Following := 1
    else if (Value and $F0) = $E0 then
      Following := 2
    else if (Value and $F8) = $F0 then
      Following := 3
    else
      Exit(False);
    Inc(Index);
    while (Following > 0) and (Index < Count) do
    begin
      if (Bytes[Index] and $C0) <> $80 then
        Exit(False);
      Inc(Index);
      Dec(Following);
    end;
  end;
  Result := True;
end;

{ Reads up to SniffSize bytes from the start of Path; -1 if it cannot
  be read. }
function ReadStart(const Path: string; out Bytes: array of Byte): LongInt;
var
  Handle: Int64;
  Count: Int64;
begin
  Handle := OpenFile(PChar(Path), OpenRead);
  if Handle < 0 then
    Exit(-1);
  Count := ReadFile(Handle, @Bytes[0], Length(Bytes));
  CloseFile(Handle);
  if Count < 0 then
    Exit(-1);
  Result := Count;
end;

function LooksLikeText(const Path: string): Boolean;
var
  Bytes: array[0..SniffSize - 1] of Byte;
  Count: LongInt;
begin
  Count := ReadStart(Path, Bytes);
  Result := (Count >= 0) and IsTextBytes(Bytes, Count);
end;

function LooksLikeImage(const Path: string): Boolean;
var
  Bytes: array[0..SniffSize - 1] of Byte;
  Count: LongInt;
  Data: TBytes;
begin
  Count := ReadStart(Path, Bytes);
  if Count <= 0 then
    Exit(False);
  Data := nil;
  SetLength(Data, Count);
  Move(Bytes[0], Data[0], Count);
  Result := DetectFileFormat(Data) <> ImageFormatUnknown;
end;

{ An ELF program, or a script naming its interpreter. }
function LooksRunnable(const Path: string): Boolean;
var
  Bytes: array[0..SniffSize - 1] of Byte;
  Count: LongInt;
begin
  Count := ReadStart(Path, Bytes);
  if Count >= 4 then
    if (Bytes[0] = $7F) and (Bytes[1] = Ord('E')) and (Bytes[2] = Ord('L')) and (Bytes[3] = Ord('F')) then
      Exit(True);
  Result := (Count >= 2) and (Bytes[0] = Ord('#')) and (Bytes[1] = Ord('!'));
end;

function OpenActionFor(const Path: string; const Item: TFolderItem): TOpenAction;
begin
  case FileTypeOf(Item) of
    FileTypeFolder: Exit(OpenActionFolder);
    FileTypeText: Exit(OpenActionNotepad);
    FileTypePipe, FileTypeDevice, FileTypeBrokenLink: Exit(OpenActionNone);
  end;
  if ((Item.Mode and ExecutePermissionBits) <> 0) and LooksRunnable(Path) then
    Exit(OpenActionProgram);
  if LooksLikeImage(Path) then
    Exit(OpenActionImageViewer);
  if LooksLikeText(Path) then
    Result := OpenActionNotepad
  else
    Result := OpenActionNone;
end;

end.
