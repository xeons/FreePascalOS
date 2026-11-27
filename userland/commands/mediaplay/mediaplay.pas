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
  mediaplay - play and check media files

  mediaplay [OPTION]... FILE...

  Plays the first audio track of each file (WAV, FLAC, Ogg Vorbis, Opus
  and FLAC, WebM and Matroska, MP4, MP3) on the audio device, one after
  the other.

    -i, --info          print the container, length and tracks instead
    -k, --checksum      decode every track and print checksums instead:
                        an MD5 per video frame, per packet of tracks
                        without a decoder, and per audio track
                        (MediaPlay.Checksums)
    -s, --start=SECONDS start playing there
    -r, --rate=HZ       play at this rate (resampled)
    -c, --channels=N    play this many channels (mixed)
    -d, --device=PATH   the audio output (default: the system's)
    -q, --quiet         no line per file
}
program mediaplay;

{$mode objfpc}
{$H+}

uses
  SysUtils,
  Util.CommandLine,
  Util.Messages,
  Media.Errors,
  Media.Demuxers,
  Media.Containers,
  Video.MediaDecoders,
  MediaPlay.Info,
  MediaPlay.Checksums,
  MediaPlay.Playback,
  { The video decoders: registered when their units are used. }
  Av1.MediaDecoder;

const
  Usage = 'Usage: mediaplay [OPTION]... FILE...'#10 +
    'Play media files (WAV, FLAC, Ogg, WebM/Matroska, MP4, MP3) on the audio device.'#10 +
    #10 +
    '  -i, --info           print the container, length and tracks'#10 +
    '  -k, --checksum       decode every track and print checksums'#10 +
    '  -s, --start=SECONDS  start playing there'#10 +
    '  -r, --rate=HZ        play at this rate (resampled, 8000 to 192000)'#10 +
    '  -c, --channels=N     play this many channels (mixed, 1 to 8)'#10 +
    '  -d, --device=PATH    the audio output'#10 +
    '  -q, --quiet          no line per file'#10;

  OptionInfo = 1;
  OptionChecksum = 2;
  OptionStart = 3;
  OptionRate = 4;
  OptionChannels = 5;
  OptionDevice = 6;
  OptionQuiet = 7;

type
  TAction = (actionPlay, actionInfo, actionChecksum);

var
  CommandLine: TCommandLine;
  Code: Integer;
  Value: string;
  Action: TAction;
  Options: TPlaybackOptions;
  Operand: string;
  Demuxer: TMediaDemuxer;
  Failed: Boolean;
  Seconds: Double;
  Number: Integer;

function ParseSeconds(const Text: string; out Parsed: Double): Boolean;
var
  Settings: TFormatSettings;
begin
  Settings := DefaultFormatSettings;
  Settings.DecimalSeparator := '.';
  Result := TryStrToFloat(Text, Parsed, Settings) and (Parsed >= 0);
end;

begin
  Action := actionPlay;
  Options := Default(TPlaybackOptions);
  Options.DevicePath := '';
  CommandLine := TCommandLine.Create([CommandOption('i', 'info', False, OptionInfo),
    CommandOption('k', 'checksum', False, OptionChecksum),
    CommandOption('s', 'start', True, OptionStart),
    CommandOption('r', 'rate', True, OptionRate),
    CommandOption('c', 'channels', True, OptionChannels),
    CommandOption('d', 'device', True, OptionDevice),
    CommandOption('q', 'quiet', False, OptionQuiet)], Usage);
  while CommandLine.NextOption(Code, Value) do
    case Code of
      OptionInfo: Action := actionInfo;
      OptionChecksum: Action := actionChecksum;
      OptionStart:
        begin
          if not ParseSeconds(Value, Seconds) then
            FailWithUsageHint('the start must be a number of seconds');
          Options.StartMicroseconds := Round(Seconds * 1000000);
        end;
      OptionRate:
        begin
          if not TryStrToInt(Value, Number) or (Number < 8000) or (Number > 192000) then
            FailWithUsageHint('the rate must be 8000 to 192000');
          Options.Rate := Number;
        end;
      OptionChannels:
        begin
          if not TryStrToInt(Value, Number) or (Number < 1) or (Number > 8) then
            FailWithUsageHint('there can be 1 to 8 channels');
          Options.Channels := Number;
        end;
      OptionDevice: Options.DevicePath := Value;
      OptionQuiet: Options.Quiet := True;
    end;
  if CommandLine.OperandCount = 0 then
    FailWithUsageHint('no file');
  Failed := False;
  for Operand in CommandLine.Operands do
  begin
    try
      Demuxer := OpenMediaFile(Operand);
    except
      on Error: Exception do
      begin
        Report(Operand + ': ' + Error.Message);
        Failed := True;
        Continue;
      end;
    end;
    try
      try
        case Action of
          actionInfo: PrintMediaInfo(Operand, Demuxer);
          actionChecksum:
            if not PrintChecksums(Demuxer) then
              Failed := True;
          actionPlay:
            if not PlayAudio(Operand, Demuxer, Options) then
              Failed := True;
        end;
      except
        on Error: EMediaError do
        begin
          Report(Operand + ': ' + Error.Message);
          Failed := True;
        end;
      end;
    finally
      Demuxer.Free;
    end;
  end;
  CommandLine.Free;
  if Failed then
    Halt(1);
end.
