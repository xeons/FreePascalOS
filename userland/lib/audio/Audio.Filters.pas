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
  Voice filters, as XAudio2 has them.

  The state variable filter (Chamberlin's) gives low-pass, band-pass,
  high-pass and notch outputs from one structure; its Frequency is the
  "radian frequency" 2 sin(pi f / rate) (CutoffToFilterFrequency turns
  hertz into it) and OneOverQ sets the resonance (1.0 is none). The
  one-pole filters are gentler: Frequency there is the coefficient
  1 - exp(-2 pi f / rate) (CutoffToOnePoleFrequency).

  Each channel keeps its own state (TFilterState).
}
unit Audio.Filters;

{$mode objfpc}
{$pointermath on}

interface

type
  TFilterKind = (FilterLowPass, FilterBandPass, FilterHighPass, FilterNotch, FilterLowPassOnePole,
    FilterHighPassOnePole);

  TFilterParameters = record
    Kind: TFilterKind;
    Frequency: Single;
    OneOverQ: Single;
  end;

  TFilterState = record
    LowPass: Single;
    BandPass: Single;
  end;

const
  { Frequency 1.0 with no resonance: the filter lets everything through. }
  FilterMaximumFrequency = 1.0;
  DefaultFilterOneOverQ = 1.0;

function DefaultFilterParameters: TFilterParameters;
{ The state variable filter's Frequency for a cutoff of Hertz. }
function CutoffToFilterFrequency(Hertz, Rate: Single): Single;
function CutoffToOnePoleFrequency(Hertz, Rate: Single): Single;
{ True if Parameters leave the sound as it is (the filter is skipped). }
function FilterIsTransparent(const Parameters: TFilterParameters): Boolean;
{ Filters Frames samples of one channel, Stride apart, in place. }
procedure ApplyFilter(const Parameters: TFilterParameters; var State: TFilterState; Samples: PSingle;
  Frames, Stride: LongWord);

implementation

function DefaultFilterParameters: TFilterParameters;
begin
  Result.Kind := FilterLowPass;
  Result.Frequency := FilterMaximumFrequency;
  Result.OneOverQ := DefaultFilterOneOverQ;
end;

function CutoffToFilterFrequency(Hertz, Rate: Single): Single;
begin
  Result := 2 * Sin(Pi * Hertz / Rate);
  if Result > FilterMaximumFrequency then
    Result := FilterMaximumFrequency;
end;

function CutoffToOnePoleFrequency(Hertz, Rate: Single): Single;
begin
  Result := 1 - Exp(-2 * Pi * Hertz / Rate);
end;

function FilterIsTransparent(const Parameters: TFilterParameters): Boolean;
begin
  Result := (Parameters.Kind in [FilterLowPass, FilterLowPassOnePole]) and
    (Parameters.Frequency >= FilterMaximumFrequency) and (Parameters.OneOverQ >= DefaultFilterOneOverQ);
end;

procedure ApplyFilter(const Parameters: TFilterParameters; var State: TFilterState; Samples: PSingle;
  Frames, Stride: LongWord);
var
  Frame: LongWord;
  Input: Single;
  HighPass: Single;
  F: Single;
  Q: Single;
begin
  F := Parameters.Frequency;
  Q := Parameters.OneOverQ;
  for Frame := 0 to Frames - 1 do
  begin
    Input := Samples[Frame * Stride];
    case Parameters.Kind of
      FilterLowPassOnePole:
        begin
          State.LowPass := State.LowPass + F * (Input - State.LowPass);
          Samples[Frame * Stride] := State.LowPass;
        end;
      FilterHighPassOnePole:
        begin
          State.LowPass := State.LowPass + F * (Input - State.LowPass);
          Samples[Frame * Stride] := Input - State.LowPass;
        end;
    else
      State.LowPass := State.LowPass + F * State.BandPass;
      HighPass := Input - State.LowPass - Q * State.BandPass;
      State.BandPass := F * HighPass + State.BandPass;
      case Parameters.Kind of
        FilterLowPass: Samples[Frame * Stride] := State.LowPass;
        FilterBandPass: Samples[Frame * Stride] := State.BandPass;
        FilterHighPass: Samples[Frame * Stride] := HighPass;
      else
        Samples[Frame * Stride] := HighPass + State.LowPass;
      end;
    end;
  end;
end;

end.
