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
  Decoded audio to an output's format: channels mixed (TChannelMixer),
  the rate converted (TResampler) and the floats written as the device's
  samples (16 or 32-bit signed, or 32-bit float: the sample kinds 2, 4
  and 5 of the audio devices, Audio.Formats). Integer samples are
  rounded and clipped.
}
unit Media.AudioConversion;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Media.Frames,
  Media.Resampler,
  Media.ChannelMixer;

const
  OutputSigned16 = 2;
  OutputSigned32 = 4;
  OutputFloat32 = 5;

type
  TAudioConverter = class
  private
    FInputRate, FInputChannels: Integer;
    FOutputRate, FOutputChannels, FOutputKind: Integer;
    FMixer: TChannelMixer;
    FResampler: TResampler;
    function Encode(const Samples: TSampleArray): TBytes;
  public
    constructor Create(InputRate, InputChannels, OutputRate, OutputChannels, OutputKind: Integer);
    destructor Destroy; override;
    { Buffer (InputRate, InputChannels) as output samples. }
    function Convert(const Buffer: TAudioBuffer): TBytes;
    { What the resampler still holds, after the last buffer. }
    function Flush: TBytes;
    procedure Reset;
    property OutputRate: Integer read FOutputRate;
    property OutputChannels: Integer read FOutputChannels;
    property OutputKind: Integer read FOutputKind;
  end;

function OutputSampleBytes(Kind: Integer): Integer;
{ Writes Count floats as samples of Kind at Target. }
procedure EncodeOutputSamples(Source: PSingle; Count, Kind: Integer; Target: PByte);

implementation

function OutputSampleBytes(Kind: Integer): Integer;
begin
  case Kind of
    OutputSigned16: Result := 2;
  else
    Result := 4;
  end;
end;

procedure EncodeOutputSamples(Source: PSingle; Count, Kind: Integer; Target: PByte);
var
  Index: Integer;
  Value: Double;
  Whole: Int64;
begin
  for Index := 0 to Count - 1 do
  begin
    Value := Source[Index];
    case Kind of
      OutputSigned16:
        begin
          Whole := Round(Value * 32768);
          if Whole > 32767 then
            Whole := 32767
          else if Whole < -32768 then
            Whole := -32768;
          PSmallInt(Target)^ := SmallInt(Whole);
          Inc(Target, 2);
        end;
      OutputSigned32:
        begin
          Whole := Round(Value * 2147483648.0);
          if Whole > High(LongInt) then
            Whole := High(LongInt)
          else if Whole < Low(LongInt) then
            Whole := Low(LongInt);
          PLongInt(Target)^ := LongInt(Whole);
          Inc(Target, 4);
        end;
    else
      begin
        PSingle(Target)^ := Source[Index];
        Inc(Target, 4);
      end;
    end;
  end;
end;

constructor TAudioConverter.Create(InputRate, InputChannels, OutputRate, OutputChannels, OutputKind: Integer);
begin
  inherited Create;
  FInputRate := InputRate;
  FInputChannels := InputChannels;
  FOutputRate := OutputRate;
  FOutputChannels := OutputChannels;
  FOutputKind := OutputKind;
  if InputChannels <> OutputChannels then
    FMixer := TChannelMixer.Create(InputChannels, OutputChannels);
  if InputRate <> OutputRate then
    FResampler := TResampler.Create(InputRate, OutputRate, OutputChannels);
end;

destructor TAudioConverter.Destroy;
begin
  FMixer.Free;
  FResampler.Free;
  inherited Destroy;
end;

function TAudioConverter.Encode(const Samples: TSampleArray): TBytes;
begin
  Result := nil;
  SetLength(Result, Length(Samples) * OutputSampleBytes(FOutputKind));
  if Length(Samples) > 0 then
    EncodeOutputSamples(@Samples[0], Length(Samples), FOutputKind, @Result[0]);
end;

function TAudioConverter.Convert(const Buffer: TAudioBuffer): TBytes;
var
  Samples: TSampleArray;
  Frames: Integer;
begin
  Frames := AudioFrameCount(Buffer);
  Samples := TSampleArray(Buffer.Samples);
  if FMixer <> nil then
    Samples := FMixer.Mix(Samples, Frames);
  if FResampler <> nil then
    Samples := FResampler.Process(Samples, Frames);
  Result := Encode(Samples);
end;

function TAudioConverter.Flush: TBytes;
begin
  if FResampler = nil then
    Exit(nil);
  Result := Encode(FResampler.Flush);
end;

procedure TAudioConverter.Reset;
begin
  if FResampler <> nil then
    FResampler.Reset;
end;

end.
