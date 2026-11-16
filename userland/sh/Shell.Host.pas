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
  What the shell asks of the system, in strings: the current directory,
  finding programs in PATH, reading files and pipes whole, and the
  argument and environment vectors a new program receives.

  The PChar calls of libsystem (Sys.Files, Sys.Processes) are made here
  and in the few places that start programs or read directories.
}
unit Shell.Host;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Classes;

type
  { A nil terminated vector of PChar over strings that the caller keeps
    alive while it is in use (arguments, environment). }
  TTextVector = array of PChar;

{ Reads the whole file; returns an Abi error code (ErrorNone on success). }
function ReadTextFile(const Path: string; out Text: string): LongInt;
{ Reads Handle to its end. }
function ReadToEnd(Handle: Int64): string;

function MakeTextVector(List: TStrings): TTextVector;

implementation

uses
  Abi.SystemCalls,
  Sys.Errors,
  Sys.Files,
  Sys.Processes;

const
  ReadChunkSize = 4096;

function ReadToEnd(Handle: Int64): string;
var
  Chunk: array[0..ReadChunkSize - 1] of Byte;
  BytesRead: Int64;
  Filled: SizeInt;
begin
  Result := '';
  Filled := 0;
  repeat
    BytesRead := ReadFile(Handle, @Chunk[0], SizeOf(Chunk));
    if BytesRead > 0 then
    begin
      SetLength(Result, Filled + BytesRead);
      Move(Chunk[0], Result[Filled + 1], BytesRead);
      Inc(Filled, BytesRead);
    end;
  until BytesRead <= 0;
end;

function ReadTextFile(const Path: string; out Text: string): LongInt;
var
  Handle: Int64;
begin
  Text := '';
  Handle := OpenFile(PChar(Path), OpenRead);
  if Handle < 0 then
    Exit(ErrorCodeOf(Handle));
  try
    Text := ReadToEnd(Handle);
  finally
    CloseFile(Handle);
  end;
  Result := ErrorNone;
end;

function MakeTextVector(List: TStrings): TTextVector;
var
  Index: Integer;
begin
  Result := nil;
  SetLength(Result, List.Count + 1);
  for Index := 0 to List.Count - 1 do
    Result[Index] := PChar(List[Index]);
  Result[List.Count] := nil;
end;

end.
