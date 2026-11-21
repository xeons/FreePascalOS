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
  What the engine says it is (HTTP's User-Agent and navigator.userAgent):
  the platform (FreePascalOS on its processor), the usual compatibility
  tokens every engine sends so sites serve their standard pages, and the
  engine itself. The web view and webbrowse both send it.
}
unit Web.UserAgent;

{$mode objfpc}
{$H+}

interface

const
{$ifdef CPUAARCH64}
  EngineUserAgent = 'Mozilla/5.0 (X11; FreePascalOS aarch64) AppleWebKit/537.36 (KHTML, like Gecko) libweb/1.0 ' +
    'Safari/537.36';
{$else}
  EngineUserAgent = 'Mozilla/5.0 (X11; FreePascalOS x86_64) AppleWebKit/537.36 (KHTML, like Gecko) libweb/1.0 ' +
    'Safari/537.36';
{$endif}

implementation

end.
