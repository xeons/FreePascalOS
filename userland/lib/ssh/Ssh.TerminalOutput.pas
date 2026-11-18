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
  A pseudo-terminal's output as a remote terminal expects it.

  Programs here end lines with a line feed alone, and a pseudo-terminal
  passes it on as written: the program showing the terminal moves to
  the start of the next line (the terminal window does). A client's
  terminal (xterm, PuTTY, Windows Terminal) only moves down on a line
  feed, as a Unix terminal's output processing (ONLCR) would have put a
  carriage return before it. So the server does that: each line feed
  not already after a carriage return gets one, across chunks.
}
unit Ssh.TerminalOutput;

{$mode objfpc}{$H+}

interface

type
  TTerminalOutputTranslator = record
    { The last character of the chunk before was a carriage return. }
    AfterCarriageReturn: Boolean;
  end;

procedure ResetTerminalOutput(out Translator: TTerminalOutputTranslator);
{ Chunk with a carriage return before each bare line feed. }
function TranslateTerminalOutput(var Translator: TTerminalOutputTranslator; const Chunk: string): string;

implementation

procedure ResetTerminalOutput(out Translator: TTerminalOutputTranslator);
begin
  Translator.AfterCarriageReturn := False;
end;

function TranslateTerminalOutput(var Translator: TTerminalOutputTranslator; const Chunk: string): string;
var
  Index: Integer;
  Count: Integer;
  Character: Char;
begin
  Result := '';
  SetLength(Result, Length(Chunk) * 2);
  Count := 0;
  for Index := 1 to Length(Chunk) do
  begin
    Character := Chunk[Index];
    if (Character = #10) and not Translator.AfterCarriageReturn then
    begin
      Inc(Count);
      Result[Count] := #13;
    end;
    Inc(Count);
    Result[Count] := Character;
    Translator.AfterCarriageReturn := Character = #13;
  end;
  SetLength(Result, Count);
end;

end.
