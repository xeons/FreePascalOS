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
  The units of dimensions (CSS Values and Units Level 4): their names,
  what they measure, and the conversions between absolute ones.
}
unit Css.Units;

{$mode objfpc}
{$H+}

interface

type
  TCssUnit = (cuNone,
    { absolute lengths }
    cuPx, cuCm, cuMm, cuQ, cuIn, cuPt, cuPc,
    { font-relative lengths }
    cuEm, cuRem, cuEx, cuRex, cuCap, cuRcap, cuCh, cuRch, cuIc, cuRic, cuLh, cuRlh,
    { viewport-percentage lengths (default, small, large, dynamic) }
    cuVw, cuVh, cuVi, cuVb, cuVmin, cuVmax,
    cuSvw, cuSvh, cuSvi, cuSvb, cuSvmin, cuSvmax,
    cuLvw, cuLvh, cuLvi, cuLvb, cuLvmin, cuLvmax,
    cuDvw, cuDvh, cuDvi, cuDvb, cuDvmin, cuDvmax,
    { container query lengths }
    cuCqw, cuCqh, cuCqi, cuCqb, cuCqmin, cuCqmax,
    { angles, times, frequencies, resolutions, flexible lengths }
    cuDeg, cuGrad, cuRad, cuTurn, cuS, cuMs, cuHz, cuKhz, cuDpi, cuDpcm, cuDppx, cuX, cuFr,
    cuPercent);

  TCssUnitCategory = (ucNumber, ucLength, ucAngle, ucTime, ucFrequency, ucResolution, ucFlex,
    ucPercent);

const
  FirstRelativeLength = cuEm;
  LastRelativeLength = cuCqmax;

function UnitByName(const Name: string): TCssUnit;
function CssUnitName(UnitValue: TCssUnit): string;
function UnitCategory(UnitValue: TCssUnit): TCssUnitCategory;
{ An absolute length unit (px, cm, ...). }
function IsAbsoluteLength(UnitValue: TCssUnit): Boolean; inline;
{ The canonical unit of a category: px, deg, s, Hz, dppx. }
function CanonicalUnit(Category: TCssUnitCategory): TCssUnit;
{ How many canonical units one of UnitValue is (absolute units only;
  0 for relative lengths). }
function CanonicalFactor(UnitValue: TCssUnit): Double;

implementation

uses
  Css.Atoms;

const
  UnitNames: array[TCssUnit] of string = ('',
    'px', 'cm', 'mm', 'q', 'in', 'pt', 'pc',
    'em', 'rem', 'ex', 'rex', 'cap', 'rcap', 'ch', 'rch', 'ic', 'ric', 'lh', 'rlh',
    'vw', 'vh', 'vi', 'vb', 'vmin', 'vmax',
    'svw', 'svh', 'svi', 'svb', 'svmin', 'svmax',
    'lvw', 'lvh', 'lvi', 'lvb', 'lvmin', 'lvmax',
    'dvw', 'dvh', 'dvi', 'dvb', 'dvmin', 'dvmax',
    'cqw', 'cqh', 'cqi', 'cqb', 'cqmin', 'cqmax',
    'deg', 'grad', 'rad', 'turn', 's', 'ms', 'hz', 'khz', 'dpi', 'dpcm', 'dppx', 'x', 'fr',
    '%');

function UnitByName(const Name: string): TCssUnit;
var
  Lower: string;
  Candidate: TCssUnit;
begin
  Lower := AsciiLowercase(Name);
  for Candidate := Succ(cuNone) to Pred(cuPercent) do
    if UnitNames[Candidate] = Lower then
      Exit(Candidate);
  Result := cuNone;
end;

function CssUnitName(UnitValue: TCssUnit): string;
begin
  Result := UnitNames[UnitValue];
  if UnitValue = cuQ then
    Result := 'Q'
  else if UnitValue = cuHz then
    Result := 'Hz'
  else if UnitValue = cuKhz then
    Result := 'kHz';
end;

function UnitCategory(UnitValue: TCssUnit): TCssUnitCategory;
begin
  case UnitValue of
    cuPx..cuCqmax: Result := ucLength;
    cuDeg..cuTurn: Result := ucAngle;
    cuS, cuMs: Result := ucTime;
    cuHz, cuKhz: Result := ucFrequency;
    cuDpi..cuX: Result := ucResolution;
    cuFr: Result := ucFlex;
    cuPercent: Result := ucPercent;
  else
    Result := ucNumber;
  end;
end;

function IsAbsoluteLength(UnitValue: TCssUnit): Boolean;
begin
  Result := UnitValue in [cuPx..cuPc];
end;

function CanonicalUnit(Category: TCssUnitCategory): TCssUnit;
begin
  case Category of
    ucLength: Result := cuPx;
    ucAngle: Result := cuDeg;
    ucTime: Result := cuS;
    ucFrequency: Result := cuHz;
    ucResolution: Result := cuDppx;
    ucFlex: Result := cuFr;
    ucPercent: Result := cuPercent;
  else
    Result := cuNone;
  end;
end;

function CanonicalFactor(UnitValue: TCssUnit): Double;
begin
  case UnitValue of
    cuNone, cuPx, cuDeg, cuS, cuHz, cuDppx, cuX, cuFr, cuPercent: Result := 1;
    cuCm: Result := 96 / 2.54;
    cuMm: Result := 96 / 25.4;
    cuQ: Result := 96 / 101.6;
    cuIn: Result := 96;
    cuPt: Result := 96 / 72;
    cuPc: Result := 16;
    cuGrad: Result := 0.9;
    cuRad: Result := 180 / Pi;
    cuTurn: Result := 360;
    cuMs: Result := 0.001;
    cuKhz: Result := 1000;
    cuDpi: Result := 1 / 96;
    cuDpcm: Result := 2.54 / 96;
  else
    Result := 0;
  end;
end;

end.
