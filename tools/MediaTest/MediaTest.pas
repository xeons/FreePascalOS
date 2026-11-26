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
  The host tests of libmedia: its containers and audio decoders over
  fixtures the host's ffmpeg, flac and lame (or Python) made when the
  test was built (tools/MediaTest/make-*-fixtures.py), each compared
  with the host tools' own decoding; the Opus decoder over the RFC 6716 /
  RFC 8251 test vectors when they are there.

  MediaTest FIXTURES [OPUS-VECTORS]
}
program MediaTest;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  TestChecks,
  MediaTest.Basics,
  MediaTest.Flac,
  MediaTest.Containers,
  MediaTest.Vorbis,
  MediaTest.Opus,
  MediaTest.Mp3;

var
  FixtureRoot, OpusVectors: string;
begin
  if ParamCount < 1 then
  begin
    WriteLn('Usage: MediaTest FIXTURES [OPUS-VECTORS]');
    Halt(2);
  end;
  FixtureRoot := ParamStr(1);
  if ParamCount >= 2 then
    OpusVectors := ParamStr(2)
  else
    OpusVectors := '';
  RunBasicTests(FixtureRoot);
  RunFlacTests(FixtureRoot);
  RunContainerTests(FixtureRoot);
  RunVorbisTests(FixtureRoot);
  RunOpusTests(FixtureRoot, OpusVectors);
  RunMp3Tests(FixtureRoot);
  FinishChecks('MEDIA TEST');
end.
