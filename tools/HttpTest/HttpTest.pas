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
  HttpTest - checks libhttp on the host (make http-test): the URL
  Standard (HttpTest.Urls).
}
program HttpTest;

{$mode objfpc}
{$H+}

uses
  {$ifdef unix}
  cthreads,
  {$endif}
  TestChecks,
  HttpTest.Hpack,
  HttpTest.Http2Frames,
  HttpTest.Loopback,
  HttpTest.Urls;

begin
  TestUrls;
  TestHpack;
  TestHttp2Frames;
  TestLoopback;
  FinishChecks('http test');
end.
