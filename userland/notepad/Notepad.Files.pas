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
  Text files as Notepad reads and writes them.

  The text is UTF-8 and its lines end with a line feed, as the edit box
  keeps them. A file whose first line ends with a carriage return and a
  line feed (as files from other systems do) is read with every such
  pair made a line feed, and written back with them again, so saving
  keeps the file's style; a carriage return on its own stays in the
  text. A UTF-8 byte order mark at the start is taken off and put back
  the same way. New files get line feeds and no mark.
}
unit Notepad.Files;

{$mode objfpc}
{$H+}

interface

type
  TLineEnding = (LineEndingLineFeed, LineEndingCarriageReturnLineFeed);

  { How a file's text was stored, to store it the same way again. }
  TTextFileFormat = record
    LineEnding: TLineEnding;
    HasByteOrderMark: Boolean;
  end;

{ What a new file gets. }
function DefaultTextFileFormat: TTextFileFormat;
{ Reads Path into Text (lines ending with line feeds) and how it was
  stored into Format; '' on success, else what went wrong. }
function ReadTextFile(const Path: string; out Text: string; out Format: TTextFileFormat): string;
{ Writes Text (lines ending with line feeds) to Path stored as Format
  says, replacing what was there; '' on success, else what went wrong. }
function WriteTextFile(const Path, Text: string; const Format: TTextFileFormat): string;
{ The text as it is stored (line breaks and mark put back). }
function StoredText(const Text: string; const Format: TTextFileFormat): string;
{ Stored text as the edit box keeps it, and how it was stored. }
function TextFromStored(const Stored: string; out Format: TTextFileFormat): string;

implementation

uses
  SysUtils,
  Abi.SystemCalls,
  Sys.Files,
  Sys.Errors;

const
  ByteOrderMark = #$EF#$BB#$BF;
  ReadChunkSize = 65536;

function DefaultTextFileFormat: TTextFileFormat;
begin
  Result.LineEnding := LineEndingLineFeed;
  Result.HasByteOrderMark := False;
end;

function ErrorText(CallResult: Int64): string;
begin
  Result := StrPas(ErrorMessage(ErrorCodeOf(CallResult)));
end;

function TextFromStored(const Stored: string; out Format: TTextFileFormat): string;
var
  FirstLineFeed: LongInt;
begin
  Format := DefaultTextFileFormat;
  Result := Stored;
  if Copy(Result, 1, Length(ByteOrderMark)) = ByteOrderMark then
  begin
    Format.HasByteOrderMark := True;
    Delete(Result, 1, Length(ByteOrderMark));
  end;
  FirstLineFeed := Pos(#10, Result);
  if (FirstLineFeed > 1) and (Result[FirstLineFeed - 1] = #13) then
  begin
    Format.LineEnding := LineEndingCarriageReturnLineFeed;
    Result := StringReplace(Result, #13#10, #10, [rfReplaceAll]);
  end;
end;

function StoredText(const Text: string; const Format: TTextFileFormat): string;
begin
  Result := Text;
  if Format.LineEnding = LineEndingCarriageReturnLineFeed then
    Result := StringReplace(Result, #10, #13#10, [rfReplaceAll]);
  if Format.HasByteOrderMark then
    Result := ByteOrderMark + Result;
end;

function ReadTextFile(const Path: string; out Text: string; out Format: TTextFileFormat): string;
var
  Handle: Int64;
  Stored: string;
  Used: Int64;
  Got: Int64;
begin
  Text := '';
  Format := DefaultTextFileFormat;
  Handle := OpenFile(PChar(Path), OpenRead);
  if Handle < 0 then
    Exit(ErrorText(Handle));
  { Read in chunks until the end: the size is not asked first, as a
    file can be something that has none (a pipe). }
  Stored := '';
  Used := 0;
  repeat
    if Used + ReadChunkSize > Length(Stored) then
      SetLength(Stored, Length(Stored) * 2 + ReadChunkSize);
    Got := ReadFile(Handle, @Stored[Used + 1], ReadChunkSize);
    if Got > 0 then
      Used := Used + Got;
  until Got <= 0;
  CloseFile(Handle);
  if Got < 0 then
    Exit(ErrorText(Got));
  SetLength(Stored, Used);
  Text := TextFromStored(Stored, Format);
  Result := '';
end;

function WriteTextFile(const Path, Text: string; const Format: TTextFileFormat): string;
var
  Handle: Int64;
  Stored: string;
  Error: LongInt;
begin
  Handle := OpenFile(PChar(Path), OpenWrite or OpenCreate or OpenTruncate);
  if Handle < 0 then
    Exit(ErrorText(Handle));
  Stored := StoredText(Text, Format);
  Error := 0;
  if Stored <> '' then
    Error := WriteAll(Handle, @Stored[1], Length(Stored));
  CloseFile(Handle);
  if Error <> 0 then
    Exit(StrPas(ErrorMessage(Error)));
  Result := '';
end;

end.
