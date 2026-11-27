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
  Playing a media file's first audio track on an audio output.

  The decoded floats go to the device as they are when it takes their
  rate and channels (the kernel converts to what the hardware plays);
  otherwise, or when a rate or channel count is asked for, libmedia's
  converter mixes and resamples them first. Writing waits while the
  device's queue is full, so the file plays at its own pace.
}
unit MediaPlay.Playback;

{$mode objfpc}
{$H+}

interface

uses
  Media.Demuxers;

type
  TPlaybackOptions = record
    DevicePath: string;
    { 0: the decoder's own. }
    Rate: Integer;
    Channels: Integer;
    StartMicroseconds: Int64;
    Quiet: Boolean;
  end;

{ Plays Demuxer's first audio track; False (with a message) if it
  cannot. }
function PlayAudio(const Path: string; Demuxer: TMediaDemuxer; const Options: TPlaybackOptions): Boolean;

implementation

uses
  SysUtils,
  Util.Messages,
  Audio.Device,
  Audio.Formats,
  Media.Errors,
  Media.Frames,
  Media.Packets,
  Media.AudioDecoders,
  Media.AudioCodecs,
  Media.AudioConversion,
  MediaPlay.Info;

const
  MinimumDeviceRate = 8000;
  MaximumDeviceRate = 192000;
  MaximumDeviceChannels = 8;

type
  TPlayer = class
  private
    FDevice: Int64;
    FDecoder: TAudioDecoder;
    FConverter: TAudioConverter;
    FOptions: TPlaybackOptions;
    FConfiguredRate, FConfiguredChannels: Integer;
    FFramesPlayed: Int64;
    procedure Configure(Rate, Channels: Integer);
    procedure Write(const Bytes: TBytes);
  public
    constructor Create(Device: Int64; Decoder: TAudioDecoder; const Options: TPlaybackOptions);
    destructor Destroy; override;
    procedure Play(const Buffer: TAudioBuffer);
    procedure Finish;
    property FramesPlayed: Int64 read FFramesPlayed;
  end;

constructor TPlayer.Create(Device: Int64; Decoder: TAudioDecoder; const Options: TPlaybackOptions);
begin
  inherited Create;
  FDevice := Device;
  FDecoder := Decoder;
  FOptions := Options;
end;

destructor TPlayer.Destroy;
begin
  FConverter.Free;
  inherited Destroy;
end;

procedure TPlayer.Configure(Rate, Channels: Integer);
var
  OutputRate, OutputChannels: Integer;
  Format: TAudioFormat;
  Error: LongInt;
begin
  OutputRate := Rate;
  OutputChannels := Channels;
  if FOptions.Rate > 0 then
    OutputRate := FOptions.Rate;
  if FOptions.Channels > 0 then
    OutputChannels := FOptions.Channels;
  if (OutputRate < MinimumDeviceRate) or (OutputRate > MaximumDeviceRate) then
    OutputRate := 48000;
  if OutputChannels > MaximumDeviceChannels then
    OutputChannels := 2;
  FreeAndNil(FConverter);
  if (OutputRate <> Rate) or (OutputChannels <> Channels) then
    FConverter := TAudioConverter.Create(Rate, Channels, OutputRate, OutputChannels, OutputFloat32);
  Format.Rate := OutputRate;
  Format.Channels := OutputChannels;
  Format.Kind := SampleFloat32;
  Error := SetAudioFormat(FDevice, Format);
  if Error <> 0 then
    raise EMediaError.CreateFmt('the audio device does not take %d Hz, %d channels (error %d)',
      [OutputRate, OutputChannels, Error]);
  FConfiguredRate := Rate;
  FConfiguredChannels := Channels;
end;

procedure TPlayer.Write(const Bytes: TBytes);
var
  Error: LongInt;
begin
  if Length(Bytes) = 0 then
    Exit;
  Error := WriteAudio(FDevice, @Bytes[0], Length(Bytes));
  if Error <> 0 then
    raise EMediaError.CreateFmt('writing to the audio device failed (error %d)', [Error]);
end;

procedure TPlayer.Play(const Buffer: TAudioBuffer);
var
  Bytes: TBytes;
begin
  if Length(Buffer.Samples) = 0 then
    Exit;
  if (Buffer.SampleRate <> FConfiguredRate) or (Buffer.Channels <> FConfiguredChannels) then
  begin
    if FConverter <> nil then
      Write(FConverter.Flush);
    Configure(Buffer.SampleRate, Buffer.Channels);
  end;
  if FConverter <> nil then
    Bytes := FConverter.Convert(Buffer)
  else
  begin
    Bytes := nil;
    SetLength(Bytes, Length(Buffer.Samples) * SizeOf(Single));
    Move(Buffer.Samples[0], Bytes[0], Length(Bytes));
  end;
  Write(Bytes);
  Inc(FFramesPlayed, AudioFrameCount(Buffer));
end;

procedure TPlayer.Finish;
begin
  if FConverter <> nil then
    Write(FConverter.Flush);
  DrainAudio(FDevice);
end;

function PlayAudio(const Path: string; Demuxer: TMediaDemuxer; const Options: TPlaybackOptions): Boolean;
var
  Track: TMediaTrack;
  Decoder: TAudioDecoder;
  Device: Int64;
  Player: TPlayer;
  Packet: TMediaPacket;
  Buffer: TAudioBuffer;
  Errors: Integer;
begin
  Result := False;
  Track := Demuxer.FirstTrackOf(mkAudio);
  if Track = nil then
  begin
    Report(Path + ': no audio track');
    Exit;
  end;
  Decoder := nil;
  Player := nil;
  Device := -1;
  try
    try
      Decoder := CreateAudioDecoder(Track);
      if (Options.StartMicroseconds > 0) and not Demuxer.SeekTo(Options.StartMicroseconds) then
        Report(Path + ': cannot seek; playing from the start');
      Device := OpenAudioOutput(Options.DevicePath);
      if Device < 0 then
      begin
        ReportError(LongInt(-Device), 'opening the audio device');
        Exit;
      end;
      Player := TPlayer.Create(Device, Decoder, Options);
      if not Options.Quiet then
        WriteLn(Format('%s: %s %s, %d Hz, %d channel(s), %s', [Path, Demuxer.FormatName, CodecIdName(Track.Codec),
          Track.SampleRate, Track.Channels, DurationText(Demuxer.Duration)]));
      Errors := 0;
      Buffer := Default(TAudioBuffer);
      while Demuxer.ReadPacket(Packet) do
      begin
        if Packet.TrackIndex <> Track.Index then
          Continue;
        try
          if Decoder.Decode(Packet, Buffer) then
            Player.Play(Buffer);
        except
          on Error: EMediaError do
          begin
            { A damaged packet is skipped; too many and the file is given up. }
            Inc(Errors);
            if Errors > 100 then
              raise;
          end;
        end;
      end;
      Player.Finish;
      Result := True;
    except
      on Error: EMediaError do
        Report(Path + ': ' + Error.Message);
    end;
  finally
    Player.Free;
    Decoder.Free;
    if Device >= 0 then
      CloseAudioOutput(Device);
  end;
end;

end.
