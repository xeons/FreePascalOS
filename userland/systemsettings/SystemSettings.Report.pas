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
  What the system settings service says on its standard output (its
  service's log, /var/log/systemsettings.log): a line for each thing it
  does and each request it refuses, never a password.
}
unit SystemSettings.Report;

{$mode objfpc}
{$H+}

interface

procedure Say(const Text: string);

implementation

uses
  Sys.Format,
  Sys.Streams;

procedure Say(const Text: string);
begin
  WriteFormatted(StandardOutput, 'systemsettings: %s'#10, [ArgumentText(PChar(Text))]);
  FlushStream(StandardOutput);
end;

end.
