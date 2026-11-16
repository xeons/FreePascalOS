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
  What the file manager tells its standard output as things happen, a
  line each (the program's header lists them), so a test can follow it.
  Only the window's thread writes here: the output buffer is not shared
  between threads.
}
unit FileManager.Output;

{$mode objfpc}
{$H+}

interface

procedure Say(const Text: string);

implementation

uses
  Sys.Streams,
  Util.Output;

procedure Say(const Text: string);
begin
  PrintStringLine(Text);
  FlushStream(StandardOutput);
end;

end.
