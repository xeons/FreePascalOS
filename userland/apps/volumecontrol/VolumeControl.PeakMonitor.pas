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
  What an output is playing, for its peak meter: the output's monitor
  input (/dev/audiomonitor for /dev/audio, then audiomonitor1, ...),
  read as 16-bit stereo at 48 kHz. Reading never waits: only what the
  monitor has queued is taken (an output that plays nothing gives
  nothing, and the meter falls). The monitor costs the output nothing.
}
unit VolumeControl.PeakMonitor;

{$mode objfpc}
{$H+}

interface

uses
  VolumeControl.Levels;

type
  TPeakMonitor = class
  private
    FHandle: Int64;
    FSamples: array of SmallInt;
  public
    { Opens output Number's monitor (Available is False if it has none). }
    constructor Create(Number: LongInt);
    destructor Destroy; override;
    function Available: Boolean;
    { The peaks of what was played since the last call; False if
      nothing was. }
    function ReadPeak(out Peak: TStereoPeak): Boolean;
  end;

{ The monitor input's device file for output Number. }
function MonitorPath(Number: LongInt): string;

implementation

uses
  SysUtils,
  Audio.Formats,
  Audio.Device;

const
  MonitorRate = 48000;
  MonitorChannels = 2;
  BytesPerFrame = 4;
  { A quarter of a second at most a read. }
  LargestRead = MonitorRate div 4 * BytesPerFrame;

function MonitorPath(Number: LongInt): string;
begin
  if Number = 0 then
    Result := '/dev/audiomonitor'
  else
    Result := '/dev/audiomonitor' + IntToStr(Number);
end;

constructor TPeakMonitor.Create(Number: LongInt);
var
  Format: TAudioFormat;
begin
  inherited Create;
  FHandle := OpenAudioInput(MonitorPath(Number));
  if FHandle < 0 then
    Exit;
  Format.Rate := MonitorRate;
  Format.Channels := MonitorChannels;
  Format.Kind := SampleSigned16;
  if SetAudioFormat(FHandle, Format) <> 0 then
  begin
    CloseAudioOutput(FHandle);
    FHandle := -1;
    Exit;
  end;
  SetLength(FSamples, LargestRead div 2);
end;

destructor TPeakMonitor.Destroy;
begin
  if FHandle >= 0 then
    CloseAudioOutput(FHandle);
  inherited Destroy;
end;

function TPeakMonitor.Available: Boolean;
begin
  Result := FHandle >= 0;
end;

function TPeakMonitor.ReadPeak(out Peak: TStereoPeak): Boolean;
var
  Queued: Int64;
  Wanted: Int64;
  Taken: Int64;
  Combined: TStereoPeak;
begin
  Peak.Left := 0;
  Peak.Right := 0;
  Result := False;
  if FHandle < 0 then
    Exit;
  Queued := QueuedAudioBytes(FHandle);
  while Queued >= BytesPerFrame do
  begin
    Wanted := Queued;
    if Wanted > LargestRead then
      Wanted := LargestRead;
    Wanted := Wanted - Wanted mod BytesPerFrame;
    Taken := ReadAudio(FHandle, @FSamples[0], Wanted);
    if Taken <= 0 then
      Break;
    Combined := PeakOfSamples(FSamples, Taken div BytesPerFrame, MonitorChannels);
    if Combined.Left > Peak.Left then
      Peak.Left := Combined.Left;
    if Combined.Right > Peak.Right then
      Peak.Right := Combined.Right;
    Result := True;
    Queued := Queued - Taken;
  end;
end;

end.
