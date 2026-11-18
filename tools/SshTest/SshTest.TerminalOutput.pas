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
  A pseudo-terminal's output for the client's terminal
  (Ssh.TerminalOutput): bare line feeds get a carriage return, ones
  after a carriage return (in the same chunk or the one before) do not.
}
unit SshTest.TerminalOutput;

{$mode objfpc}{$H+}

interface

procedure TestTerminalOutput;

implementation

uses
  TestChecks,
  Ssh.TerminalOutput;

procedure TestTerminalOutput;
var
  Translator: TTerminalOutputTranslator;
begin
  ResetTerminalOutput(Translator);
  Check(TranslateTerminalOutput(Translator, 'a'#10'b'#10) = 'a'#13#10'b'#13#10,
    'terminal output: bare line feeds get a carriage return');
  Check(TranslateTerminalOutput(Translator, 'c'#13#10) = 'c'#13#10,
    'terminal output: a carriage return and line feed stay as they are');
  Check(TranslateTerminalOutput(Translator, 'd'#13) = 'd'#13,
    'terminal output: a chunk ending in a carriage return');
  Check(TranslateTerminalOutput(Translator, #10'e') = #10'e',
    'terminal output: its line feed in the next chunk gets none');
  Check(TranslateTerminalOutput(Translator, #10#10) = #13#10#13#10,
    'terminal output: line feeds in a row');
  Check(TranslateTerminalOutput(Translator, '') = '', 'terminal output: an empty chunk');
end;

end.
