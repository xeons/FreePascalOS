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
  What the network service says on its standard output (its service's
  log, /var/log/network.log): a line for each change it makes and each
  problem it meets.
}
unit NetworkService.Log;

{$mode objfpc}
{$H+}

interface

procedure Say(const Text: string);
{ An error code's message, for lines like "eth0: address: ...". }
function ErrorText(Error: LongInt): string;

implementation

uses
  Sys.Errors,
  Sys.Streams;

procedure Say(const Text: string);
begin
  PrintStringLine('network: ' + Text);
  FlushStream(StandardOutput);
end;

function ErrorText(Error: LongInt): string;
begin
  Result := string(ErrorMessage(Error));
end;

end.
