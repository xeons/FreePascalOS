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
  sync - write cached data to permanent storage
}
program sync;

{$mode objfpc}

uses
  Sys.Files,
  Util.Messages,
  Util.Options;

const
  Usage: PChar = 'Usage: sync'#10 +
    'Synchronize cached writes to persistent storage.'#10;

var
  Parser: TOptionParser;
  Error: LongInt;
begin
  ParseOperandsOnly(Parser, Usage);
  Error := SyncFileSystems;
  if Error <> 0 then
    FailWithError(1, Error, 'error syncing', []);
end.
