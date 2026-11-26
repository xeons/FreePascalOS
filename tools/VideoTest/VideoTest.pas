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
  libvideo's host test: the VP8 and VP9 decoders against the reference
  decoder's MD5s, picture by picture, on one thread and on several, the
  same through libmedia's WebM and MP4 demuxers, damaged streams, and
  the interface.

  VideoTest VECTORS [CONFORMANCE]
    VECTORS      what make-vectors.py made
    CONFORMANCE  more streams with a manifest.txt (the libvpx test
                 vectors, prepared by prepare-conformance.py), if given
}
program VideoTest;

{$mode objfpc}
{$H+}

uses
  cthreads, SysUtils, TestChecks, VideoTest.Streams, VideoTest.Conformance, VideoTest.Containers,
  VideoTest.Robustness, VideoTest.Interfaces;

begin
  if ParamCount < 1 then
  begin
    WriteLn('usage: VideoTest VECTORS [CONFORMANCE]');
    Halt(2);
  end;
  CheckInterfaces(ParamStr(1));
  CheckManifest(ParamStr(1));
  CheckContainers(ParamStr(1));
  CheckDamagedStreams(ParamStr(1));
  if (ParamCount >= 2) and FileExists(IncludeTrailingPathDelimiter(ParamStr(2)) + 'manifest.txt') then
    CheckManifest(ParamStr(2));
  FinishChecks('VIDEO');
end.
