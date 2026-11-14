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
  A small library that the tests load at run time with LoadLibrary and
  call through FindSymbol. Its entry points have plain C-style names.
}
unit Plugin;

{$mode objfpc}

interface

function PluginAdd(First, Second: Int64): Int64;
function PluginGreeting: PChar;

implementation

function PluginAdd(First, Second: Int64): Int64; [public, alias: 'plugin_add'];
begin
  Result := First + Second;
end;

function PluginGreeting: PChar; [public, alias: 'plugin_greeting'];
begin
  Result := 'hello from libplugin';
end;

end.
