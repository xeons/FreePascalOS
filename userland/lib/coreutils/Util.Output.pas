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
  Strings on the standard streams of Sys.Streams.

  The tools write through Sys.Streams, which honours the buffering that
  stdbuf asks for and remembers write errors; these put whole strings
  (embedded NUL bytes included) on those streams.

    PrintString(Format('%6d'#9, [LineNumber]));
    PrintStringLine(Name);
}
unit Util.Output;

{$mode objfpc}{$H+}

interface

uses
  Sys.Streams;

procedure WriteString(Stream: POutputStream; const Text: string);
{ Text and a line feed. }
procedure WriteStringLine(Stream: POutputStream; const Text: string);

{ The same on standard output. }
procedure PrintString(const Text: string);
procedure PrintStringLine(const Text: string);
{ And on standard error. }
procedure PrintErrorString(const Text: string);
procedure PrintErrorStringLine(const Text: string);

implementation

procedure WriteString(Stream: POutputStream; const Text: string);
begin
  if Text <> '' then
    WriteBytes(Stream, PChar(Text), Length(Text));
end;

procedure WriteStringLine(Stream: POutputStream; const Text: string);
begin
  WriteString(Stream, Text);
  WriteCharacter(Stream, #10);
end;

procedure PrintString(const Text: string);
begin
  WriteString(StandardOutput, Text);
end;

procedure PrintStringLine(const Text: string);
begin
  WriteStringLine(StandardOutput, Text);
end;

procedure PrintErrorString(const Text: string);
begin
  WriteString(StandardError, Text);
end;

procedure PrintErrorStringLine(const Text: string);
begin
  WriteStringLine(StandardError, Text);
end;

end.
