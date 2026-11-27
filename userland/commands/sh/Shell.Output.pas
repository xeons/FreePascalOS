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
  The shell's output: strings on the buffered standard streams
  (Sys.Streams), and its error messages.

  An error message usually first flushes standard output, so that what a
  command printed before the error comes out before it; the messages of
  expansions and of the prompt loop do not.
}
unit Shell.Output;

{$mode objfpc}
{$H+}

interface

uses
  Sys.Streams;

procedure WriteString(Stream: POutputStream; const Text: string);
procedure WriteStringLine(Stream: POutputStream; const Text: string);

{ "sh: MESSAGE" on standard error. }
procedure ShellError(const Message: string);
{ The same without flushing standard output first. }
procedure ShellErrorWithoutFlush(const Message: string);
{ "sh: NAME: MESSAGE" on standard error (builtins). }
procedure CommandError(const Name, Message: string);

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

procedure ShellError(const Message: string);
begin
  FlushStream(StandardOutput);
  ShellErrorWithoutFlush(Message);
end;

procedure ShellErrorWithoutFlush(const Message: string);
begin
  WriteStringLine(StandardError, 'sh: ' + Message);
end;

procedure CommandError(const Name, Message: string);
begin
  ShellError(Name + ': ' + Message);
end;

end.
