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
  Channel mixing: interleaved frames of one channel count to another, in
  the WAVE order (front left, front right, centre, LFE, back left, back
  right, side left, side right).

  The usual layouts for each count are assumed (1 mono, 2 stereo, 3
  L R C, 4 quadraphonic L R BL BR, 5 L R C BL BR, 6 5.1, 7 6.1 with a
  back centre, 8 7.1). Downmixing folds centre and surround channels into
  the front pair at -3 dB (ITU-R BS.775), the LFE is left out, and each
  output row is scaled so a full-scale input cannot clip. Upmixing puts
  mono in both fronts and stereo in the front pair; the other outputs are
  silent. The same count passes through.
}
unit Media.ChannelMixer;

{$mode objfpc}
{$H+}

interface

uses
  SysUtils,
  Media.Resampler;

type
  TChannelMixer = class
  private
    FInputChannels, FOutputChannels: Integer;
    FMatrix: array of Single;
    procedure BuildMatrix;
  public
    constructor Create(InputChannels, OutputChannels: Integer);
    function Mix(const Input: TSampleArray; Frames: Integer): TSampleArray;
    { The weight of input channel InputChannel in output OutputChannel. }
    function Weight(OutputChannel, InputChannel: Integer): Single;
    property InputChannels: Integer read FInputChannels;
    property OutputChannels: Integer read FOutputChannels;
  end;

implementation

type
  TSpeaker = (spLeft, spRight, spCentre, spLowFrequency, spBackLeft, spBackRight, spSideLeft, spSideRight,
    spBackCentre, spMono);

const
  MinusThreeDecibels = 0.70710678;

function SpeakerOf(Channels, Channel: Integer): TSpeaker;
begin
  case Channels of
    1: Result := spMono;
    2: if Channel = 0 then Result := spLeft else Result := spRight;
    3:
      case Channel of
        0: Result := spLeft;
        1: Result := spRight;
      else
        Result := spCentre;
      end;
    4:
      case Channel of
        0: Result := spLeft;
        1: Result := spRight;
        2: Result := spBackLeft;
      else
        Result := spBackRight;
      end;
    5:
      case Channel of
        0: Result := spLeft;
        1: Result := spRight;
        2: Result := spCentre;
        3: Result := spBackLeft;
      else
        Result := spBackRight;
      end;
    7:
      case Channel of
        0: Result := spLeft;
        1: Result := spRight;
        2: Result := spCentre;
        3: Result := spLowFrequency;
        4: Result := spBackCentre;
        5: Result := spSideLeft;
      else
        Result := spSideRight;
      end;
  else
    { 6 (5.1), 8 (7.1) and more: the WAVE order. }
    if Channel < 8 then
      Result := TSpeaker(Channel)
    else
      Result := spCentre;
  end;
end;

{ The weight of input speaker From in output speaker Into, both
  known to the output layout or not. }
function FoldWeight(From, Into: TSpeaker; IntoHas: array of Boolean): Single;
begin
  if From = Into then
    Exit(1);
  Result := 0;
  case Into of
    spMono:
      case From of
        spLeft, spRight: Result := MinusThreeDecibels;
        spCentre: Result := 1;
        spBackLeft, spBackRight, spSideLeft, spSideRight, spBackCentre: Result := 0.5;
      end;
    spLeft:
      case From of
        spMono: Result := 1;
        spCentre: if not IntoHas[Ord(spCentre)] then Result := MinusThreeDecibels;
        spBackLeft: if not IntoHas[Ord(spBackLeft)] then
            if IntoHas[Ord(spSideLeft)] then Result := 0 else Result := MinusThreeDecibels;
        spSideLeft: if not IntoHas[Ord(spSideLeft)] then
            if IntoHas[Ord(spBackLeft)] then Result := 0 else Result := MinusThreeDecibels;
        spBackCentre: if not IntoHas[Ord(spBackLeft)] and not IntoHas[Ord(spSideLeft)] then
            Result := 0.5;
      end;
    spRight:
      case From of
        spMono: Result := 1;
        spCentre: if not IntoHas[Ord(spCentre)] then Result := MinusThreeDecibels;
        spBackRight: if not IntoHas[Ord(spBackRight)] then
            if IntoHas[Ord(spSideRight)] then Result := 0 else Result := MinusThreeDecibels;
        spSideRight: if not IntoHas[Ord(spSideRight)] then
            if IntoHas[Ord(spBackRight)] then Result := 0 else Result := MinusThreeDecibels;
        spBackCentre: if not IntoHas[Ord(spBackRight)] and not IntoHas[Ord(spSideRight)] then
            Result := 0.5;
      end;
    spBackLeft:
      case From of
        spSideLeft: if not IntoHas[Ord(spSideLeft)] then Result := 1;
        spBackCentre: Result := MinusThreeDecibels;
      end;
    spBackRight:
      case From of
        spSideRight: if not IntoHas[Ord(spSideRight)] then Result := 1;
        spBackCentre: Result := MinusThreeDecibels;
      end;
    spSideLeft:
      case From of
        spBackLeft: if not IntoHas[Ord(spBackLeft)] then Result := 1;
        spBackCentre: if not IntoHas[Ord(spBackLeft)] then Result := MinusThreeDecibels;
      end;
    spSideRight:
      case From of
        spBackRight: if not IntoHas[Ord(spBackRight)] then Result := 1;
        spBackCentre: if not IntoHas[Ord(spBackRight)] then Result := MinusThreeDecibels;
      end;
  end;
end;

constructor TChannelMixer.Create(InputChannels, OutputChannels: Integer);
begin
  inherited Create;
  if (InputChannels <= 0) or (OutputChannels <= 0) then
    raise EArgumentException.Create('channel counts must be positive');
  FInputChannels := InputChannels;
  FOutputChannels := OutputChannels;
  BuildMatrix;
end;

procedure TChannelMixer.BuildMatrix;
var
  OutputChannel, InputChannel: Integer;
  OutputHas: array[TSpeaker] of Boolean;
  RowSum, Value: Single;
  Speaker: TSpeaker;
begin
  SetLength(FMatrix, FOutputChannels * FInputChannels);
  for Speaker := Low(TSpeaker) to High(TSpeaker) do
    OutputHas[Speaker] := False;
  for OutputChannel := 0 to FOutputChannels - 1 do
    OutputHas[SpeakerOf(FOutputChannels, OutputChannel)] := True;
  for OutputChannel := 0 to FOutputChannels - 1 do
  begin
    RowSum := 0;
    for InputChannel := 0 to FInputChannels - 1 do
    begin
      if FInputChannels = FOutputChannels then
      begin
        if InputChannel = OutputChannel then
          Value := 1
        else
          Value := 0;
      end
      else
        Value := FoldWeight(SpeakerOf(FInputChannels, InputChannel), SpeakerOf(FOutputChannels, OutputChannel),
          OutputHas);
      FMatrix[OutputChannel * FInputChannels + InputChannel] := Value;
      RowSum := RowSum + Value;
    end;
    if RowSum > 1 then
      for InputChannel := 0 to FInputChannels - 1 do
        FMatrix[OutputChannel * FInputChannels + InputChannel] :=
          FMatrix[OutputChannel * FInputChannels + InputChannel] / RowSum;
  end;
end;

function TChannelMixer.Weight(OutputChannel, InputChannel: Integer): Single;
begin
  Result := FMatrix[OutputChannel * FInputChannels + InputChannel];
end;

function TChannelMixer.Mix(const Input: TSampleArray; Frames: Integer): TSampleArray;
var
  Frame, OutputChannel, InputChannel: Integer;
  Sum: Single;
  Row: PSingle;
  Source: PSingle;
begin
  Result := nil;
  SetLength(Result, Frames * FOutputChannels);
  if FInputChannels = FOutputChannels then
  begin
    if Frames > 0 then
      Move(Input[0], Result[0], Frames * FInputChannels * SizeOf(Single));
    Exit;
  end;
  for Frame := 0 to Frames - 1 do
  begin
    Source := @Input[Frame * FInputChannels];
    for OutputChannel := 0 to FOutputChannels - 1 do
    begin
      Row := @FMatrix[OutputChannel * FInputChannels];
      Sum := 0;
      for InputChannel := 0 to FInputChannels - 1 do
        Sum := Sum + Row[InputChannel] * Source[InputChannel];
      Result[Frame * FOutputChannels + OutputChannel] := Sum;
    end;
  end;
end;

end.
